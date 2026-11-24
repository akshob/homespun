// SPDX-License-Identifier: Apache-2.0
import Foundation
import os
import SQLite3
import Synchronization

/// App-owned SQLite access; this intentionally does not depend on the AGPL server adapter.
final class BackupDatabase: Sendable {
    enum Failure: Error, LocalizedError {
        case sqlite(Int32)
        case invalidValue
        case closed
        case durableStorageUnavailable

        var errorDescription: String? {
            switch self {
            case .sqlite(let code): "Backup progress could not be saved (storage error \(code))."
            case .invalidValue: "Stored backup progress is unreadable. No new changes will be made."
            case .closed: "Backup storage is closed."
            case .durableStorageUnavailable: "This storage cannot safely save resumable backup progress."
            }
        }
    }

    struct RollbackFailure: Error {
        let primary: any Error
        let rollback: any Error
    }

    enum Value: Equatable, Sendable {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }

    struct Row: Sendable {
        var values: [String: Value]

        func text(_ key: String) throws -> String {
            guard let raw = values[key], case .text(let value) = raw else { throw Failure.invalidValue }
            return value
        }

        func integer(_ key: String) throws -> Int64 {
            guard let raw = values[key], case .integer(let value) = raw else { throw Failure.invalidValue }
            return value
        }

        func blob(_ key: String) throws -> Data {
            guard let raw = values[key], case .blob(let value) = raw else { throw Failure.invalidValue }
            return value
        }
    }

    struct Connection {
        fileprivate let handle: OpaquePointer

        @discardableResult
        func execute(_ sql: String, _ values: [Value] = []) throws -> Int {
            try statement(sql, values) { statement in
                let result = sqlite3_step(statement)
                guard result == SQLITE_DONE else { throw Failure.sqlite(result) }
                return Int(sqlite3_changes(handle))
            }
        }

        func rows(_ sql: String, _ values: [Value] = []) throws -> [Row] {
            try statement(sql, values) { statement in
                var rows: [Row] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { return rows }
                    guard result == SQLITE_ROW else { throw Failure.sqlite(result) }
                    var values: [String: Value] = [:]
                    for column in 0..<sqlite3_column_count(statement) {
                        let name = String(cString: sqlite3_column_name(statement, column))
                        switch sqlite3_column_type(statement, column) {
                        case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                        case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                        case SQLITE_TEXT:
                            guard let pointer = sqlite3_column_text(statement, column) else { throw Failure.invalidValue }
                            let count = Int(sqlite3_column_bytes(statement, column))
                            let bytes = UnsafeBufferPointer(start: pointer, count: count)
                            guard let text = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidValue }
                            values[name] = .text(text)
                        case SQLITE_BLOB:
                            let count = Int(sqlite3_column_bytes(statement, column))
                            if count == 0 { values[name] = .blob(Data()) }
                            else {
                                guard let pointer = sqlite3_column_blob(statement, column) else { throw Failure.invalidValue }
                                values[name] = .blob(Data(bytes: pointer, count: count))
                            }
                        case SQLITE_NULL: values[name] = .null
                        default: throw Failure.invalidValue
                        }
                    }
                    rows.append(Row(values: values))
                }
            }
        }

        private func statement<Result>(_ sql: String, _ values: [Value],
                                       _ body: (OpaquePointer) throws -> Result) throws -> Result {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else { throw Failure.sqlite(prepared) }
            defer { sqlite3_finalize(statement) }
            guard Int(sqlite3_bind_parameter_count(statement)) == values.count else { throw Failure.invalidValue }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .null: result = sqlite3_bind_null(statement, index)
                case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
                case .real(let value): result = sqlite3_bind_double(statement, index, value)
                case .text(let value):
                    guard let count = Int32(exactly: value.utf8.count) else { throw Failure.invalidValue }
                    result = value.withCString { sqlite3_bind_text(statement, index, $0, count, Self.transient) }
                case .blob(let value):
                    guard let count = Int32(exactly: value.count) else { throw Failure.invalidValue }
                    if value.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                    else {
                        result = value.withUnsafeBytes {
                            sqlite3_bind_blob(statement, index, $0.baseAddress, count, Self.transient)
                        }
                    }
                }
                guard result == SQLITE_OK else { throw Failure.sqlite(result) }
            }
            return try body(statement)
        }

        private static var transient: sqlite3_destructor_type {
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        }
    }

    private let handle: Mutex<OpaquePointer?>

    init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw Failure.sqlite(result)
        }
        handle = Mutex(pointer)
        do {
            try read { connection in
                let result = sqlite3_busy_timeout(connection.handle, 5_000)
                guard result == SQLITE_OK else { throw Failure.sqlite(result) }
                guard try connection.rows("PRAGMA journal_mode = WAL").first?.text("journal_mode") == "wal" else {
                    throw Failure.durableStorageUnavailable
                }
                try connection.execute("PRAGMA synchronous = FULL")
                try connection.execute("PRAGMA foreign_keys = ON")
            }
        } catch {
            handle.withLock { pointer in
                if let pointer { sqlite3_close_v2(pointer) }
                pointer = nil
            }
            throw error
        }
    }

    deinit {
        handle.withLock { pointer in
            if let pointer, sqlite3_close_v2(pointer) != SQLITE_OK {
                Logger(subsystem: "photos.homespun.app", category: "backup-store").fault("backup database close failed")
            }
            pointer = nil
        }
    }

    func read<Result: Sendable>(_ body: (Connection) throws -> Result) throws -> Result {
        try handle.withLock { pointer in
            guard let pointer else { throw Failure.closed }
            return try body(Connection(handle: pointer))
        }
    }

    func transaction<Result: Sendable>(_ body: (Connection) throws -> Result) throws -> Result {
        try read { connection in
            try connection.execute("BEGIN IMMEDIATE")
            do {
                let value = try body(connection)
                try connection.execute("COMMIT")
                return value
            } catch {
                let primary = error
                do { try connection.execute("ROLLBACK") }
                catch { throw RollbackFailure(primary: primary, rollback: error) }
                throw primary
            }
        }
    }
}
