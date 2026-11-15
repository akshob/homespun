// SPDX-License-Identifier: Apache-2.0
import Foundation
import HomespunCore
import UniformTypeIdentifiers

/// The words the item viewer shows: its title, subtitle and the sentence under the photo
/// (DESIGN 03·1.1). Pure, so they can be tested.
enum ItemText {
    /// "November 12", with the year when it isn't this year.
    static func title(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "Item" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.wide).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    /// "9:41 AM · Live", "9:41 AM · Video, 0:48" or "9:41 AM".
    static func subtitle(_ date: Date?, kind: PhotoLibrary.Kind?, duration: TimeInterval = 0, calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        let time = date?.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute())
        let detail: String? = switch kind {
        case .livePhoto: "Live"
        case .video: "Video, " + Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond))
        case .photo, nil: nil
        }
        return [time, detail].compactMap(\.self).joined(separator: " · ")
    }

    /// The sentence beside the badge, under the photo: what the badge means for this item.
    static func sentence(_ badge: Badge, server: String, immich: Bool, job: CompactJob.State? = nil) -> String {
        let home = immich ? "in Immich" : "on \(server)"
        switch badge {
        case .originalOnPhone: return "Ready to free up · original \(home)"
        case .backedUp: return "Original at home · \(home)"
        case .none:
            if case .notYet(let reason)? = job { return "Not backed up yet · \(reason)" }
            return "Not backed up · only on this iPhone"
        case .waiting: return "Waiting to back up"
        case .working:
            if case .working(let step)? = job, !step.isEmpty { return "Backing up · \(step)" }
            return "Backing up"
        case .kept: return "Kept as is · the original stays on this iPhone"
        case .failed: return "Needs attention · couldn't back up"
        case .compactCopy: return "Compact copy · made by Homespun"
        }
    }

    /// The sentence for VoiceOver: "Ready to free up, original on polonium."
    static func spoken(_ sentence: String) -> String {
        sentence.replacingOccurrences(of: " · ", with: ", ") + "."
    }
}

/// The one action under an item, for its state (DESIGN 03·1.1).
enum ItemAction: Equatable {
    case freeUp(original: String)
    case backUp
    case tryAgain
    case none

    static func `for`(_ cell: LibraryState.Cell) -> ItemAction {
        if cell.canFree, let original = cell.original { return .freeUp(original: original) }
        switch cell.badge {
        case .none: return .backUp
        case .failed: return .tryAgain
        default: return .none
        }
    }

    /// Whether Compare can show this item: it has a compact copy and its original can be reached,
    /// on this iPhone or streamed from the server (not in Immich mode, where the server has no
    /// original of its own).
    static func canCompare(_ cell: LibraryState.Cell, immich: Bool) -> Bool {
        guard cell.original != nil else { return false }
        switch cell.badge {
        case .originalOnPhone: return true
        case .backedUp: return !immich
        default: return false
        }
    }
}

/// Where Compare gets the original from.
enum OriginalSource: Equatable {
    /// Still on this iPhone: read from PhotoKit at full size.
    case phone(String)
    /// Only on the server: downloaded for the comparison and deleted afterwards.
    case server(assetID: String)
    /// The server reads originals from Immich and can't send them.
    case immich
    /// No original is known for this item.
    case unknown

    /// `original` is the ledger key (a local identifier, or `CompactLedger.elsewhere(…)`).
    static func choose(original: String?, onPhone: Bool, serverAssetID: String?, mode: ServerAPI.StorageMode?) -> OriginalSource {
        if let original, onPhone { return .phone(original) }
        guard let serverAssetID else { return .unknown }
        return mode == .immich ? .immich : .server(assetID: serverAssetID)
    }

    /// The server resource to download: the photo for photos and Live Photos (their still), the
    /// video for videos.
    static func role(for kind: PhotoLibrary.Kind) -> ServerAPI.ResourceRole {
        kind == .video ? .video : .photo
    }

    /// A file name for the download; AVFoundation needs an extension to open a video.
    static func fileName(for kind: PhotoLibrary.Kind) -> String {
        kind == .video ? "original.mov" : "original"
    }
}

/// A file's size, format and dimensions, as one line: "12.4 MB · HEIC · 4032×3024".
struct MediaFacts: Equatable, Sendable {
    var bytes: Int?
    var format: String?
    var width: Int?
    var height: Int?

    var line: String {
        var parts: [String] = []
        if let bytes, bytes > 0 { parts.append(Self.size(bytes)) }
        if let format { parts.append(format) }
        if let width, let height, width > 0, height > 0 { parts.append("\(width)×\(height)") }
        return parts.joined(separator: " · ")
    }

    var isEmpty: Bool { line.isEmpty }

    static func size(_ bytes: Int) -> String { bytes.formatted(.byteCount(style: .file)) }

    /// "HEIC", "JPEG", "MOV" from a uniform type identifier.
    static func format(uti: String?) -> String? {
        guard let uti, let type = UTType(uti) else { return nil }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        if type.conforms(to: .quickTimeMovie) { return "MOV" }
        if type.conforms(to: .mpeg4Movie) { return "MP4" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .rawImage) { return "RAW" }
        return type.preferredFilenameExtension?.uppercased()
    }

    /// Live Photo motion before and after in the original's unit: "3.1 → 0.6 MB" (or
    /// "1.2 MB → 8 kB" when the copy is too small to show that way).
    static func change(from original: Int?, to compact: Int?) -> String? {
        guard let original, original > 0 else { return nil }
        guard let compact, compact > 0 else { return size(original) }
        let unit: (units: ByteCountFormatStyle.Units, bytes: Int) = switch original {
        case 1_000_000_000...: (.gb, 1_000_000_000)
        case 1_000_000...: (.mb, 1_000_000)
        case 1000...: (.kb, 1000)
        default: (.bytes, 1)
        }
        guard compact * 10 >= unit.bytes else { return size(original) + " → " + size(compact) }
        let style = ByteCountFormatStyle(style: .file, allowedUnits: unit.units)
        let before = original.formatted(style), after = compact.formatted(style)
        guard let space = before.lastIndex(where: \.isWhitespace) else { return before + " → " + after }
        return String(before[..<space]) + " → " + after
    }
}

/// Where the split line sits across the photo, from 0 (all compact copy) to 1 (all original).
enum SplitPosition {
    static let step = 0.1

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    /// From a drag: the finger's x across a view `width` wide.
    static func at(x: Double, width: Double) -> Double {
        width > 0 ? clamp(x / width) : 0.5
    }

    /// VoiceOver's swipe up and down move it by a tenth, to the nearest tenth.
    static func adjusted(_ value: Double, increment: Bool) -> Double {
        let steps = (clamp(value) / step).rounded()
        return clamp((steps + (increment ? 1 : -1)) * step)
    }

    static func spoken(_ value: Double) -> String {
        "Split at \(Int((clamp(value) * 100).rounded())) percent"
    }
}
