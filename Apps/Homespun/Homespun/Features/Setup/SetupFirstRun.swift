// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

// The first task (DESIGN 01·1.10–1.15, 7.1–7.4, §16.2): this library's own number, then the 10
// newest backed up while the person watches, a receipt with real sizes, and space freed.

/// Reads the library on this iPhone: sizes by kind (sampled on big libraries) and what isn't backed up.
enum LibraryMeasure {
    struct Result: Sendable {
        var estimate: FirstTask.Estimate
        /// Not backed up yet, newest first.
        var candidates: [FirstTask.Candidate]
    }

    static func measure(excluding backedUp: Set<String>, photos: any PhotoSource) async -> Result {
        await Task.detached(priority: .userInitiated) { photos.measure(excluding: backedUp) }.value
    }
}

// MARK: 1.10 What you could free up · 7.1 Immich · 7.2 nearly full · 7.3 Live Photos here · 7.4 small

struct EstimatePage: View {
    let flow: SetupFlow
    @State private var storage: ServerAPI.StorageInfo?
    @State private var choosingFolder = false

    private var settings: AppSettings { flow.settings }
    private var library: LibraryController { flow.library ?? AppModel.current.library }
    private var name: String { flow.serverName }
    private var immich: Bool { settings.server?.mode == .immich }
    private var motionOnPhone: Bool { settings.server?.platform?.os != .macOS }

    var body: some View {
        Group {
            if let estimate = flow.estimate {
                page(estimate)
            } else {
                SetupScaffold(title: "Looking at your library…", subtitle: "On this iPhone. Nothing is uploaded.") {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
        }
        .task { await measure() }
        .sheet(isPresented: $choosingFolder, onDismiss: { Task { storage = try? await settings.client?.storage() } }) {
            NavigationStack {
                OriginalsFolderView(settings: settings)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingFolder = false } }
                    }
            }
        }
    }

    private func measure() async {
        guard flow.estimate == nil else { return }
        let backedUp = Set(await library.job.ledger.snapshot().keys)
        async let folder = settings.client?.storage()
        let result = await LibraryMeasure.measure(excluding: backedUp, photos: settings.photos)
        storage = try? await folder
        flow.notBackedUp = result.candidates.map(\.id)
        flow.taskIDs = FirstTask.pick(result.candidates)
        if result.candidates.isEmpty {
            // Nothing to back up (no photos, or all done): the Library says so.
            flow.finish()
            return
        }
        flow.estimate = result.estimate
    }


    private var tryTitle: String {
        immich ? "Try It on \(flow.taskIDs.count) from Immich" : "Choose Items to Try"
    }

    private var consequence: String {
        if immich {
            return "Makes compact copies of the \(flow.taskIDs.count) newest photos Immich has. Newer ones wait for the "
                + "Immich app. Nothing is removed from this iPhone."
        }
        return "Pick a few in your Library to back up to \(name) and see their compact copies. Nothing is removed "
            + "from this iPhone."
    }

    private func page(_ estimate: FirstTask.Estimate) -> some View {
        let total = SetupAdvisor.roughBytes(estimate.bytes), compact = SetupAdvisor.roughBytes(estimate.compactBytes)
        let nearlyFull = storage?.freeBytes.map { $0 < estimate.bytes } ?? false
        let what = estimate.count == estimate.photos.count + estimate.livePhotos.count ? "photos" : "photos and videos"
        return SetupScaffold(title: "You could free up about \(SetupAdvisor.roughBytes(estimate.freeable))") {
            Text(immich
                 ? "\(name) reads originals from your Immich, so Homespun starts with recent photos Immich has already "
                    + "backed up."
                 : settings.isDemo ? "The demo's \(estimate.count.formatted()) sample \(what) take about \(total). As compact "
                    + "copies they'd take about \(compact)."
                 : "Your \(estimate.count.formatted()) \(what) take about \(total) on this iPhone. As compact copies "
                    + "they'd take about \(compact).")
                .font(.body).foregroundStyle(Theme.secondaryLabel)
            Bars(total: total, compact: compact, ratio: FirstTask.Estimate.ratio)
            if nearlyFull, let free = storage?.freeBytes {
                InlineNotice(tone: .warning, title: "\(name) has \(SetupAdvisor.roughBytes(free)) free",
                             message: "Your originals need about \(total). Choose a bigger folder now, or start small.") {
                    if storage?.storedCount == 0 {
                        Button("Choose Another Folder") { choosingFolder = true }
                            .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.small)
                            .accessibilityIdentifier("estimate.folder")
                    }
                }
            } else {
                SetupCard {
                    if estimate.photos.count > 0 {
                        SetupRow(symbol: "photo", title: "Photos", value: row(estimate.photos))
                    }
                    if estimate.livePhotos.count > 0 {
                        SetupRow(symbol: "livephoto", title: "Live Photos",
                                 detail: motionOnPhone && !immich
                                    ? "Motion compressed on this iPhone: about \(estimate.motionMinutes) min for "
                                        + "\(estimate.livePhotos.count.formatted()), while charging" : nil,
                                 value: motionOnPhone && !immich ? SetupAdvisor.roughBytes(estimate.livePhotos.bytes)
                                    : row(estimate.livePhotos))
                    }
                    if estimate.videos.count > 0 {
                        SetupRow(symbol: "video", title: "Videos", value: row(estimate.videos))
                    }
                }
                Text(settings.isDemo ? "The demo's sample photos come with Homespun; your own library isn't read."
                     : "An estimate from your library, made on this iPhone. If iCloud Photos optimizes this iPhone's "
                        + "storage, you may free less here.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 16)
            }
        } actions: {
            ConsequenceLine(text: consequence)
            PrimaryButton(title: tryTitle, systemImage: immich ? "arrow.up.circle" : "checkmark.circle",
                          id: immich ? "estimate.try" : "estimate.choose") {
                // The person picks what to try in the Library (Free Up Space compares before removing).
                // With Immich, the server can use only what Immich has: the newest of those.
                guard immich else {
                    library.choosePending = true
                    return flow.finish()
                }
                flow.taskStarted = nil
                flow.taskFinished = nil
                flow.go(.firstTask)
            }
                .accessibilityHint(consequence)
            SecondaryButton(title: "Not Now", id: "estimate.notNow") { flow.finish() }
        }
    }

    private func row(_ group: FirstTask.Estimate.Group) -> String {
        "\(group.count.formatted()) · \(SetupAdvisor.roughBytes(group.bytes))"
    }

    /// Two bars: what the library takes now, and as compact copies. Decorative; the numbers are text.
    private struct Bars: View {
        let total: String
        let compact: String
        let ratio: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("On this iPhone now"); Spacer(); Text(total) }
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel)
                Capsule().fill(Theme.accent.opacity(0.4)).frame(height: 18)
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
                HStack { Text("As compact copies"); Spacer(); Text(compact) }
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.top, 6)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill)
                        Capsule().fill(Theme.accent).frame(width: max(18, proxy.size.width * ratio))
                    }
                }
                .frame(height: 18)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("On this iPhone now, \(total). As compact copies, \(compact).")
        }
    }
}

// MARK: 1.11 Trying it on your 10 newest

struct FirstTaskPage: View {
    let flow: SetupFlow
    @State private var stopping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var library: LibraryController { flow.library ?? AppModel.current.library }
    private var job: CompactJob { library.job }
    private var name: String { flow.serverName }
    private var ids: [String] { flow.taskIDs }
    private var states: [String: CompactJob.State] { job.states }

    private func isOpen(_ state: CompactJob.State?) -> Bool {
        guard let state else { return true }
        if case .working = state { return true }
        return state == .waiting
    }

    private var done: Int { ids.filter { !isOpen(states[$0]) }.count }
    private var finished: Bool { flow.taskStarted != nil && ids.allSatisfy { states[$0] != nil && !isOpen(states[$0]) } }
    private var saved: [String] { ids.filter { if case .saved = states[$0] { true } else { false } } }

    private var bytes: (original: Int, compact: Int) {
        ids.reduce((0, 0)) { total, id in
            if case .saved(let original, let compact) = states[id] { return (total.0 + original, total.1 + compact) }
            return total
        }
    }

    private var title: String {
        if flow.notBackedUp.count <= FirstTask.size { return ids.count == 1 ? "Backing up your photo" : "Backing up all \(ids.count)" }
        return "Backing up your \(ids.count) newest"
    }

    var body: some View {
        SetupScaffold(title: title, subtitle: "Their originals go to \(name). Compact copies come back to Photos.") {
            // At most ten: every tile laid out, five to a row.
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: ids.count, by: 5)), id: \.self) { start in
                    GridRow {
                        ForEach(ids[start..<min(start + 5, ids.count)], id: \.self) { tile($0) }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(done) of \(ids.count) backed up")
            .accessibilityIdentifier("first.tiles")
            ProgressView(value: Double(done), total: Double(max(ids.count, 1)))
                .tint(Theme.accent)
                .accessibilityLabel("Backing up")
                .accessibilityValue("\(done) of \(ids.count)")
            VStack(alignment: .leading, spacing: 4) {
                Text(status).font(.body.monospacedDigit()).foregroundStyle(Theme.label)
                    .accessibilityIdentifier("first.status")
                Text("Usually under a minute").font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
            if finished, saved.isEmpty {
                InlineNotice(tone: .error, title: "Nothing was backed up",
                             message: firstProblem ?? "Check that \(name) is on and on this Wi‑Fi, then try again.")
            } else {
                Label {
                    Text("Keep Homespun open while it works; the screen stays on.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                } icon: {
                    Image(systemName: "iphone").foregroundStyle(Theme.accent)
                }
            }
        } actions: {
            if finished, saved.isEmpty {
                PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise", id: "first.retry") { start(again: true) }
                SecondaryButton(title: "Not Now", id: "first.notNow") { flow.finish() }
            } else {
                ConsequenceLine(text: "Stop keeps the ones already backed up.")
                Button {
                    stopping = true
                    job.stopWaiting(Set(ids))
                    if !job.isRunning { complete() }
                } label: {
                    BusyLabel(title: "Stop", busy: stopping)
                }
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .allowsHitTesting(!stopping && !finished)
                .accessibilityIdentifier("first.stop")
            }
        }
        // Back only once the task has ended (going back mid-task would leave it running unseen).
        .navigationBarBackButtonHidden(!finished)
        .onAppear { start(again: false) }
        .onChange(of: job.isRunning) { _, running in
            // A stop drops the items that hadn't started: the receipt shows what made it.
            if !running, stopping { complete() }
        }
        .onChange(of: finished) { _, finished in
            if finished, !saved.isEmpty { complete() }
        }
    }

    private func tile(_ id: String) -> some View {
        Thumbnail(identifier: id, library: library.library, side: 64)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                JobBadge(job: job, id: id, badge: badge).padding(4)
            }
    }

    private var status: String {
        if finished, saved.isEmpty { return "Backed up · 0 of \(ids.count)" }
        let (original, compact) = bytes
        var text = "Backing up · \(min(done + (finished ? 0 : 1), ids.count)) of \(ids.count)"
        if original > 0 { text += " · \(SetupAdvisor.roughBytes(original)) → \(SetupAdvisor.roughBytes(compact)) so far" }
        return text
    }

    private var firstProblem: String? {
        for id in ids {
            switch states[id] {
            case .failed(let reason), .notYet(let reason), .unchanged(let reason): return reason
            default: continue
            }
        }
        return nil
    }

    private func badge(_ state: CompactJob.State?) -> Badge {
        switch state {
        case nil, .waiting?: .waiting
        case .working?: .working
        case .saved?: .originalOnPhone
        case .unchanged?: .kept
        case .notYet?: .waiting
        case .failed?: .failed
        case .backedUp?: .copyLater
        }
    }

    private func start(again: Bool) {
        guard again || flow.taskStarted == nil else { return }
        flow.taskStarted = Date()
        stopping = false
        library.backUp(ids)
    }

    private func complete() {
        guard flow.current == .firstTask else { return }
        if stopping {
            // Stopped: the ones that never started are no longer part of the task.
            flow.taskIDs = ids.filter { states[$0] != nil }
            stopping = false
        }
        flow.taskFinished = Date()
        if !saved.isEmpty {
            Announce.say(saved.count == 1 ? "Your newest is safe on \(name)." : "Your \(saved.count) newest are safe on \(name).")
            flow.replaceTop(with: .receipt)
        } else if flow.taskIDs.isEmpty {
            flow.finish()
        }
    }
}

// MARK: 1.12 Your 10 newest are safe

struct ReceiptPage: View {
    let flow: SetupFlow
    var onCompare: ((String) -> Void)?
    @State private var entries: [String: CompactLedger.Entry] = [:]
    @State private var outcome: OriginalRemover.Report?

    private var library: LibraryController { flow.library ?? AppModel.current.library }
    private var name: String { flow.serverName }
    /// What made it home, in the task's order.
    private var safe: [String] { flow.taskIDs.filter { entries[$0]?.serverAssetID != nil } }
    private var originalBytes: Int { safe.reduce(0) { $0 + (entries[$1]?.originalBytes ?? 0) } }
    private var compactBytes: Int { safe.reduce(0) { $0 + (entries[$1]?.compactBytes ?? 0) } }
    private var left: Int { flow.taskIDs.count - safe.count }
    /// The item the compare card shows: a still photo when there is one.
    @State private var sample: String?

    private var title: String {
        switch safe.count {
        case 1: "Your newest is safe on \(name)"
        case flow.taskIDs.count where flow.notBackedUp.count <= FirstTask.size: "All \(safe.count) are safe on \(name)"
        default: "Your \(safe.count) newest are safe on \(name)"
        }
    }

    private var consequence: String {
        let these = safe.count == 1 ? "this original" : "these \(safe.count) originals"
        return "Removes \(these) from this iPhone. Their compact copies stay. Recently Deleted keeps the originals for "
            + "30 days; with iCloud Photos, they leave your other devices too."
    }

    private var checking: String? {
        if case .checking(let message) = library.removal { return message }
        return nil
    }

    var body: some View {
        SetupScaffold(symbol: "checkmark.circle.fill", symbolColor: Theme.teal, title: title) {
            if let started = flow.taskStarted {
                Text("Done in \(SetupAdvisor.duration((flow.taskFinished ?? .now).timeIntervalSince(started))) · each "
                     + "original checked by SHA-256")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            HStack(alignment: .top) {
                amount(SetupAdvisor.roughBytes(originalBytes), "Originals", color: Theme.label)
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(Theme.secondaryLabel).padding(.top, 10)
                    .accessibilityHidden(true)
                amount(SetupAdvisor.roughBytes(compactBytes), "Compact copies", color: Theme.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("receipt.sizes")
            if let first = sample ?? safe.first, let entry = entries[first] {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        side(first, "Original · \(LibraryController.bytes(entry.originalBytes))")
                        side(entry.compactIdentifier, "Compact copy · \(LibraryController.bytes(entry.compactBytes))")
                    }
                    if let onCompare {
                        Button("Compare Them", systemImage: "rectangle.split.2x1") { onCompare(entry.compactIdentifier) }
                            .foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("receipt.compare")
                    }
                }
                .card(padding: 14)
            }
            if left > 0 {
                InlineNotice(tone: .info, title: "\(left) more wait for later",
                             message: "They weren't backed up this time. Activity says why.")
            }
            if let outcome { result(outcome) }
        } actions: {
            if let checking {
                Text(checking.hasPrefix("Checking ") && !checking.hasPrefix("Checking with")
                     ? "Checking with \(name) · " + checking.dropFirst("Checking ".count) : checking)
                    .font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryLabel)
                    .accessibilityIdentifier("receipt.checking")
            } else {
                ConsequenceLine(text: consequence)
            }
            PrimaryButton(title: "Free Up \(SetupAdvisor.roughBytes(originalBytes))", systemImage: "iphone",
                          busy: checking != nil, id: "receipt.freeUp") {
                Task { await freeUp() }
            }
            .accessibilityHint(consequence)
            .disabled(safe.isEmpty)
            SecondaryButton(title: "Not Now", id: "receipt.notNow") { flow.finish() }
                .disabled(checking != nil)
        }
        .task {
            entries = await library.job.ledger.snapshot()
            sample = safe.first { [.photo, .livePhoto].contains(library.settings.photos.item($0)?.itemKind) }
        }
    }

    private func amount(_ value: String, _ caption: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).bigNumber().foregroundStyle(color)
            Text(caption).font(.footnote).foregroundStyle(Theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
    }

    private func side(_ id: String, _ caption: String) -> some View {
        VStack(spacing: 6) {
            Thumbnail(identifier: id, library: library.library, side: 140)
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipped()
                .accessibilityHidden(true)
            Text(caption).font(.footnote).foregroundStyle(Theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func result(_ report: OriginalRemover.Report) -> some View {
        if report.cancelled {
            InlineNotice(tone: .info, title: "Nothing was removed",
                         message: "iOS asked, and you chose not to delete them. They stay on this iPhone.")
                .accessibilityIdentifier("receipt.nothing")
        }
        if !report.blocked.isEmpty {
            InlineNotice(tone: .error, title: "\(report.blocked.count) originals stayed on this iPhone",
                         message: "They didn't match \(name)'s copies, so Homespun kept them. Backing them up again "
                            + "fixes it.")
        }
    }

    /// RM-1: checks each original with the server again, then iOS asks (1.14).
    private func freeUp() async {
        outcome = nil
        await library.freeUp(only: Set(safe))
        guard case .done(let report) = library.removal else { return }
        library.dismissRemoval()
        if report.removed.isEmpty {
            outcome = report
        } else {
            flow.freed = report
            flow.replaceTop(with: .freed)
        }
    }
}

// MARK: 1.15 Freed, and what's next

struct FreedPage: View {
    let flow: SetupFlow
    @State private var restBytes: Int64?

    private var library: LibraryController { flow.library ?? AppModel.current.library }
    private var name: String { flow.serverName }
    private var rest: [String] { flow.notBackedUp.filter { !flow.taskIDs.contains($0) } }

    var body: some View {
        let report = flow.freed ?? .init()
        let until = Date.now.addingTimeInterval(30 * 86_400).formatted(.dateTime.month(.wide).day())
        SetupScaffold(symbol: "checkmark.circle.fill", symbolColor: Theme.teal,
                      title: "Freed \(SetupAdvisor.roughBytes(report.freedBytes))",
                      subtitle: "The \(report.removed.count == 1 ? "original is" : "\(report.removed.count) originals are") "
                        + "in Recently Deleted until \(until). Their compact copies stay in Photos.") {
            if !rest.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.up.circle").font(.title2).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next: the rest of your library").font(.body).foregroundStyle(Theme.label)
                        Text("\(rest.count.formatted()) items" + (restBytes.map { ", about \(SetupAdvisor.roughBytes($0))" } ?? "")
                             + ". It can take a few hours; keep Homespun open while it works.")
                            .font(.footnote).foregroundStyle(Theme.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                }
                .card()
                .accessibilityElement(children: .combine)
            }
        } actions: {
            if rest.isEmpty {
                PrimaryButton(title: "Go to Library", id: "freed.library") { flow.finish() }
            } else {
                ConsequenceLine(text: "Copies originals to \(name). Nothing is removed from this iPhone; you choose when "
                                + "to free up space.")
                PrimaryButton(title: "Back Up the Rest", systemImage: "arrow.up.circle", id: "freed.rest") {
                    library.backUp(rest)
                    flow.finish()
                }
                SecondaryButton(title: "Go to Library", id: "freed.library") { flow.finish() }
            }
        }
        .onAppear { Announce.say("Freed \(SetupAdvisor.roughBytes(report.freedBytes)).") }
        .task {
            let rest = rest
            let photos = library.settings.photos
            restBytes = await Task.detached { Int64(photos.estimatedBytes(rest, sample: 200).bytes) }.value
        }
    }
}

/// A tile's badge that reads the job itself, so it changes as the item does (a lazy grid doesn't
/// reliably rebuild a cell when a value passed down to it changes).
private struct JobBadge: View {
    let job: CompactJob
    let id: String
    let badge: (CompactJob.State?) -> Badge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = job.states[id]
        BadgeView(badge: badge(state), size: 20)
            .animation(reduceMotion ? nil : .default, value: badge(state))
    }
}
