// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import OSLog
import Photos
import SwiftUI

/// What a problem report includes besides the person's words (they can see it before sending):
/// versions, counts, settings, the server's kind and check results, recent runs as counts, this
/// session's Homespun log, and iOS's latest crash diagnostics. Never photos, file names, server
/// names or addresses.
enum ReportDiagnostics {
    @MainActor static func make(model: AppModel, checks: ServerSetup.Report?) async -> [String: Any] {
        let settings = model.settings, state = model.library.library.state
        // Not the iPhone's free space: that's read only to show it (its required reason keeps it on the device).
        let library: [String: Any] = [
            "access": accessName(model.library.access),
            "items": state.count(.all), "notBackedUp": state.count(.notBackedUp), "readyToFree": state.count(.readyToFree),
            "originalAtHome": state.count(.atHome), "compactLater": state.count(.copyLater),
            "needsAttention": state.count(.needsAttention), "freedBytes": settings.freedBytes,
        ]
        var server: [String: Any] = ["paired": settings.isPaired, "status": statusName(settings.serverStatus)]
        if let info = settings.server {
            server["version"] = info.version
            server["apiVersion"] = info.apiVersion
            server["mode"] = info.mode.rawValue
            server["os"] = info.platform?.os.rawValue ?? "unknown"
            server["platform"] = info.platform?.name ?? "unknown"
            server["hardware"] = info.hardware?.kind.rawValue ?? "unknown"
            if let free = info.freeBytes { server["freeBytes"] = free }
        }
        if let checks {
            server["checks"] = checks.checks.map { ["id": $0.id, "status": $0.status.rawValue] }
        }
        let schedule = model.automatic.compactSchedule
        let automatic: [String: Any] = [
            "enabled": model.automatic.enabled, "everything": model.automatic.backsUpEverything,
            "cutoffDays": schedule.days, "keepFavorites": schedule.keepFavorites,
            "lastRun": model.automatic.state.lastRun.map { $0.ISO8601Format() } ?? "never",
            "lastSummary": model.automatic.state.lastSummary ?? "",
        ]
        let runs: [[String: Any]] = model.history.runs.prefix(5).map { run in
            ["kind": run.kind.rawValue, "trigger": run.trigger.rawValue, "end": run.end.ISO8601Format(),
             "seconds": Int(run.end.timeIntervalSince(run.start)), "items": run.items.count,
             "compacted": run.count(.saved), "backedUp": run.count(.backedUp), "kept": run.count(.kept),
             "notYet": run.count(.notYet), "failed": run.count(.failed), "freedBytes": run.freedBytes]
        }
        var report: [String: Any] = [
            "library": library, "server": server, "automatic": automatic, "recentRuns": runs,
            "premium": model.premium.isUnlocked, "analytics": Telemetry.shared.consent.rawValue,
            "lastSessionEndedUnexpectedly": SessionMarker.shared.endedUnexpectedly,
            "log": recentLog(),
        ]
        if let crash = DiagnosticsStore.shared.latest() { report["metricKitDiagnostics"] = crash }
        return report
    }

    /// This session's Homespun log lines (newest 200), from the unified log.
    static func recentLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let start = store.position(timeIntervalSinceLatestBoot: 0)
        let entries = (try? store.getEntries(at: start, matching: NSPredicate(format: "subsystem == %@", AppLog.subsystem))) ?? AnySequence([])
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            "\(entry.date.ISO8601Format()) [\(entry.category)] \(entry.composedMessage)"
        }
        return Array(lines.suffix(200))
    }

    static func accessName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "full"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    static func statusName(_ status: AppSettings.ServerStatus) -> String {
        switch status {
        case .reachable: "reachable"
        case .checking: "checking"
        case .unreachable: "unreachable"
        default: "unknown"
        }
    }

    /// Pretty JSON for the preview and for copying.
    static func text(_ diagnostics: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Homespun's own log (unified logging): job and run summaries and error codes, no names.
enum AppLog {
    static let subsystem = "photos.homespun.app"
    static let job = Logger(subsystem: subsystem, category: "job")
    static let server = Logger(subsystem: subsystem, category: "server")
    static let app = Logger(subsystem: subsystem, category: "app")
}

/// Server › Help and About › Report a Problem.
struct ReportProblemView: View {
    let model: AppModel
    /// Opened after Homespun quit unexpectedly.
    var afterCrash = false
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var email = ""
    @State private var includeDiagnostics = true
    @State private var diagnostics: [String: Any]?
    @State private var sending = false
    @State private var sentID: String?
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private var trimmedEmail: String? {
        let text = email.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private var emailLooksValid: Bool {
        guard let trimmedEmail else { return true }
        return trimmedEmail.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil && trimmedEmail.count <= 254
    }

    /// The service takes up to 5,000 characters.
    static let maximumLength = 5000

    private var canSend: Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.maximumLength && emailLooksValid && !sending
    }

    var body: some View {
        Group {
            if let sentID { sent(sentID) } else { form }
        }
        .navigationTitle("Report a Problem")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            var checks: ServerSetup.Report?
            if let client = model.settings.client { checks = try? await client.setup() }
            diagnostics = await ReportDiagnostics.make(model: model, checks: checks)
        }
    }

    private var form: some View {
        List {
            if afterCrash {
                Section {
                    InlineNotice(tone: .info, title: "Homespun quit unexpectedly",
                                 message: "Say what you were doing just before. The crash details from iOS are included if "
                                    + "iOS has them.")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                TextField("For example: the backup stopped at 40 of 120 photos", text: $message, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($messageFocused)
                    .accessibilityIdentifier("report.message")
            } header: {
                Text("What happened?")
            } footer: {
                if message.count > Self.maximumLength {
                    FieldError(text: "Up to \(Self.maximumLength.formatted()) characters; this is \(message.count.formatted()).")
                }
            }
            .listRowBackground(Theme.card)
            Section {
                TextField("Email (optional)", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("report.email")
                if !emailLooksValid { FieldError(text: "That doesn't look like an email address.") }
            } footer: {
                Text("Only if you'd like a reply. It's used for nothing else.")
            }
            .listRowBackground(Theme.card)
            Section {
                Toggle("Include Diagnostics", isOn: $includeDiagnostics)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("report.includeDiagnostics")
                NavigationLink {
                    DiagnosticsPreview(text: diagnostics.map(ReportDiagnostics.text) ?? "Gathering…")
                } label: {
                    Text("See What's Included").foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("report.preview")
            } footer: {
                Text("Versions, counts, settings, your server's kind and check results, recent runs, Homespun's log "
                     + "from this session, and crash details from iOS. Never photos, file names, or your server's name "
                     + "or address.")
            }
            .listRowBackground(Theme.card)
            if let error {
                Section {
                    InlineNotice(tone: .error, title: error) {
                        Button("Copy Report") { copyReport() }
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("report.copy")
                    }
                } footer: {
                    Text("You can paste it into an email to support@homespun.photos.")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .homespunList()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send", systemImage: "paperplane") { Task { await send() } }
                    .disabled(!canSend)
                    .accessibilityIdentifier("report.send")
            }
        }
        .overlay { if sending { ProgressView("Sending…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
        .onAppear { messageFocused = true }
    }

    private func sent(_ id: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.teal)
                .accessibilityHidden(true)
            Text("Thank you").displayTitle().accessibilityAddTraits(.isHeader)
            Text(trimmedEmail == nil ? "Your report reached the developer." : "Your report reached the developer. Any reply "
                 + "goes to \(trimmedEmail!).")
                .multilineTextAlignment(.center).foregroundStyle(Theme.secondaryLabel)
            Text("Report \(id)").font(.body.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("report.id")
            Button("Copy Report Number", systemImage: "doc.on.doc") { UIPasteboard.general.string = id }
                .tint(Theme.accent)
                .accessibilityIdentifier("report.copyID")
            Text("You'll find it again in Help and About › Sent Reports.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
            PrimaryButton(title: "Done", id: "report.done") { dismiss() }
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        let report = ProblemReport(message: message.trimmingCharacters(in: .whitespacesAndNewlines), email: trimmedEmail,
                                   diagnostics: includeDiagnostics ? diagnostics : nil)
        do {
            let id = try await Telemetry.shared.sendReport(report)
            SentReports.shared.add(id: id, message: report.message)
            sentID = id
            if afterCrash { SessionMarker.shared.offersReport = false }
        } catch let failure as TelemetryError {
            error = failure.localizedDescription
        } catch {
            self.error = "The report couldn't be sent. Check the connection and try again."
        }
    }

    private func copyReport() {
        var text = "What happened:\n\(message)\n"
        if let trimmedEmail { text += "\nEmail: \(trimmedEmail)\n" }
        if includeDiagnostics, let diagnostics { text += "\nDiagnostics:\n" + ReportDiagnostics.text(diagnostics) }
        UIPasteboard.general.string = text
    }
}

/// Exactly what goes with the report.
private struct DiagnosticsPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("report.diagnostics")
        }
        .background(Theme.background)
        .navigationTitle("What's Included")
        .navigationBarTitleDisplayMode(.inline)
    }
}
