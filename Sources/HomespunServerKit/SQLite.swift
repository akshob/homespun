// SPDX-License-Identifier: AGPL-3.0-only
import CSQLite
import Foundation

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let value) = self { value } else { nil } }
    public var int: Int? { if case .integer(let value) = self { Int(value) } else { nil } }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    public init(nilLiteral: ()) { self = .null }
}

public protocol SQLValueConvertible { var sqlValue: SQLValue { get } }
extension String: SQLValueConvertible { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLValueConvertible { public var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Optional: SQLValueConvertible where Wrapped: SQLValueConvertible {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public typealias Row = [String: SQLValue]

/// One SQLite connection. Not thread-safe: own it from a single actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 10_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one statement and returns its rows.
    @discardableResult
    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw error(prepared) }
        defer { sqlite3_finalize(statement) }
        guard Int(sqlite3_bind_parameter_count(statement)) == parameters.count else {
            throw SQLiteError(code: SQLITE_RANGE, message: "expected \(sqlite3_bind_parameter_count(statement)) parameters")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data): data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
            }
            }
            guard status == SQLITE_OK else { throw error(status) }
        }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(step) }
            var row: Row = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB: .blob(Data(bytes: sqlite3_column_blob(statement, column),
                                             count: Int(sqlite3_column_bytes(statement, column))))
                default: .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        try query(sql, parameters)
    }

    /// Runs several statements (no parameters), as in a migration.
    func executeScript(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw error(status) }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs `body` in an IMMEDIATE transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
