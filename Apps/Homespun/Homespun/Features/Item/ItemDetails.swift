// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

/// What Details shows about an item, from PhotoKit, the ledger and the server.
struct ItemDetails: Equatable {
    /// The item shown: the compact copy when there is one.
    var shown = MediaFacts()
    var shownMotion: Int?
    /// The original, when the item shown is its compact copy.
    var original = MediaFacts()
    var originalMotion: Int?
    var originalOnPhone = false
    var isLive = false
    var entry: CompactLedger.Entry?
    var backedUpAt: Date?
    /// The server left Live Photo motion for this iPhone to compress (a Linux server).
    var motionOnPhone = false

    @MainActor static func load(model: AppModel, cell: LibraryState.Cell) async -> ItemDetails {
        var details = ItemDetails()
        let photos = model.settings.photos
        if let asset = photos.item(cell.id) {
            let facts = asset.mediaFacts()
            details.shown = facts.main
            details.shownMotion = facts.motion
            details.isLive = asset.itemKind == .livePhoto
        }
        guard let original = cell.original else { return details }
        let entry = await model.job.ledger.entry(for: original)
        details.entry = entry
        details.backedUpAt = entry?.savedAt
        if let asset = photos.item(original) {
            let facts = asset.mediaFacts()
            details.originalOnPhone = true
            details.original = facts.main
            details.originalMotion = facts.motion
        } else {
            details.original.bytes = entry?.originalBytes
        }
        guard let assetID = entry?.serverAssetID, var client = model.settings.client else { return details }
        client.timeout = 6
        guard let status = try? await client.status(assetID) else { return details }
        let main = status.resources.first { $0.role == (status.kind == .video ? .video : .photo) }
        if let verified = main?.verifiedAt { details.backedUpAt = verified }
        if !details.originalOnPhone {
            details.original.bytes = main?.size ?? details.original.bytes
            details.originalMotion = status.resources.first { $0.role == .pairedVideo }?.size
        }
        details.motionOnPhone = status.deviceCompresses.contains(.pairedVideo)
        return details
    }

    /// Under Sizes: where the motion was compressed and what freeing up saves.
    func footer(server: String, backedUp: Bool) -> String? {
        var parts: [String] = []
        if isLive, backedUp { parts.append("Motion was compressed on \(motionOnPhone ? "this iPhone" : server).") }
        if let entry, entry.originalBytes > entry.compactBytes {
            let saved = MediaFacts.size(entry.originalBytes - entry.compactBytes)
            parts.append(originalOnPhone ? "Saves \(saved) when you free up space." : "Saved \(saved) on this iPhone.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Details (DESIGN 03·1.2): where the item is and its sizes; or, when it couldn't be backed up or
/// was kept as is, why, with what to do (1.3, 1.4).
struct ItemDetailsSheet: View {
    let model: AppModel
    let cell: LibraryState.Cell
    var job: CompactJob.State?
    /// Closes it: an inspector (a column on the open iPhone Duo, a sheet on a phone) isn't dismissed
    /// like a sheet (`dismiss` there would leave the item).
    var close: (() -> Void)?
    @State private var details: ItemDetails?
    @Environment(\.dismiss) private var dismiss

    private func done() {
        if let close { close() } else { dismiss() }
    }

    private enum Problem {
        case failed(String), kept(String), notYet(String)
    }

    private var server: String { model.library.serverName }
    private var immich: Bool { model.settings.server?.mode == .immich }
    private var backedUp: Bool { cell.original != nil }

    private var problem: Problem? {
        switch job {
        case .failed(let message)?: .failed(message)
        case .unchanged(let message)?: .kept(message)
        case .notYet(let message)? where cell.badge == .none: .notYet(message)
        default: nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let problem { problemView(problem) } else { facts }
            }
            .background(Theme.background)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm, action: done)
                        .accessibilityIdentifier("details.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { details = await ItemDetails.load(model: model, cell: cell) }
    }

    // MARK: Where it is, and sizes

    private var facts: some View {
        List {
            Section("Where it is") { whereRows }
                .listRowBackground(Theme.card)
            Section {
                if let details { sizeRows(details) } else { ProgressView().frame(maxWidth: .infinity) }
            } header: {
                Text("Sizes")
            } footer: {
                if let footer = details?.footer(server: server, backedUp: backedUp) { Text(footer) }
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("details.list")
    }

    @ViewBuilder private var whereRows: some View {
        switch cell.badge {
        case .originalOnPhone, .backedUp:
            row("checkmark.shield", immich ? "Original in Immich (checked)" : "Original on \(server)", backedUpLine)
            row("photo.on.rectangle", "Compact copy in Photos", "Homespun album · same date, place, favorite")
            if cell.badge == .originalOnPhone {
                row("iphone", "Original still on this iPhone", "Free Up Space removes it here", tint: Theme.amber)
            } else {
                row("iphone.slash", "Not on this iPhone", "Freed up. The compact copy stays in Photos.")
            }
        case .compactCopy:
            row("square.on.square", "A Homespun compact copy", "This iPhone has no record of where its original is.")
        case .waiting, .working:
            let step: String? = if case .working(let step)? = job { step } else { nil }
            row("arrow.up.circle", "Backing up to \(server)", step ?? "Waiting to start")
            row("iphone", "Original on this iPhone", "Only here until it's backed up.")
        case .copyLater:
            row("checkmark.shield", "Original on \(server)", "Backed up · checked (SHA-256)")
            row("clock", "Compact copy later", Badge.compactLater(cell.compactAfter).capitalizedFirst
                + ". Delete it here before then and it never comes back; the server keeps its original 30 days.")
            row("iphone", "Original still on this iPhone", "Free Up Space can remove it once the compact copy is in Photos.")
        case .none, .kept, .failed:
            row("iphone", "Only on this iPhone", model.settings.isPaired
                ? "Not backed up yet. Back Up keeps the original on \(server)."
                : "Set up your home computer to back it up.")
        }
    }

    private var backedUpLine: String {
        let when = details?.backedUpAt?.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let verb = immich ? "Found in Immich" : "Backed up"
        return [when.map { "\(verb) \($0)" }, "checked (SHA-256)"].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder private func sizeRows(_ details: ItemDetails) -> some View {
        if backedUp {
            LabeledContent("Original", value: details.original.isEmpty ? "Unknown" : details.original.line)
            LabeledContent("Compact copy", value: details.shown.line)
            if details.isLive, let motion = MediaFacts.change(from: details.originalMotion, to: details.shownMotion) {
                LabeledContent("Live Photo motion", value: motion)
            }
        } else {
            LabeledContent("On this iPhone", value: details.shown.line)
            if details.isLive, let motion = details.shownMotion {
                LabeledContent("Live Photo motion", value: MediaFacts.size(motion))
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint ?? Theme.accent).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(tint ?? Theme.label)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Couldn't back up, kept as is

    private func problemView(_ problem: Problem) -> some View {
        let blocked = model.library.backUpBlockedReason
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch problem {
                case .failed(let message):
                    card("exclamationmark.triangle.fill", Theme.red, "Couldn't back up", message, spokenTone: "Problem")
                    tryAgain(blocked)
                    Button("Keep As Is") {
                        model.automatic.keepAsIs(cell.id)
                        done()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("Homespun stops trying to back it up. The original stays on this iPhone.")
                    .accessibilityIdentifier("details.keep")
                case .kept(let message):
                    card("equal.circle", Theme.secondaryLabel, "Kept as is", message, spokenTone: nil)
                case .notYet(let message):
                    card("hourglass", Theme.amber, "Not backed up yet", message, spokenTone: "Warning")
                    tryAgain(blocked)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("details.problem")
    }

    private func card(_ symbol: String, _ tint: Color, _ title: String, _ message: String, spokenTone: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3).foregroundStyle(Theme.label)
                Text(message).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([spokenTone.map { "\($0): \(title)" } ?? title, message].joined(separator: ". "))
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func tryAgain(_ blocked: String?) -> some View {
        Button {
            model.library.backUp([cell.id])
            done()
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
        }
        .primaryAction()
        .disabled(blocked != nil)
        .accessibilityHint(blocked ?? "Backs it up to \(server) again.")
        .accessibilityIdentifier("details.tryAgain")
        if let blocked {
            Text(blocked).font(.footnote).foregroundStyle(Theme.secondaryLabel).frame(maxWidth: .infinity)
        }
    }
}
