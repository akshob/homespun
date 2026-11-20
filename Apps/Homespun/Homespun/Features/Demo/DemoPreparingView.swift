// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct DemoPreparingView: View {
    let demo: DemoMode
    @State private var leaving = false
    @State private var canOfferDrawing = false
    @State private var started = ContinuousClock.now

    private var failure: DemoMediaStore.Failure? {
        if case .failed(let failure) = demo.preparation { return failure }
        return nil
    }

    private var progress: DemoMediaStore.Progress? {
        if case .drawing(let progress) = demo.preparation { return progress }
        return nil
    }

    var body: some View {
        NavigationStack {
            SetupScaffold(symbol: progress?.phase == .downloading ? "arrow.down.circle" : "paintbrush.pointed",
                          title: failure?.title ?? "Preparing the Demo",
                          subtitle: failure == nil
                              ? (progress?.phase == .downloading || progress?.phase == .assembling
                                 ? "Homespun is downloading the review photos from its own server and getting them ready."
                                 : "Homespun is drawing the demo's sample photos on this iPhone. This takes a few seconds.") : nil,
                          centered: true) {
                if let failure {
                    InlineNotice(tone: .error, title: failure.title, message: failure.message)
                        .accessibilityIdentifier("demo.prepare.problem")
                } else {
                    VStack(spacing: 8) {
                        ProgressView(value: progress?.fraction ?? 0)
                            .tint(Theme.accent)
                            .accessibilityLabel("Preparing the demo")
                            .accessibilityValue("\(Int(((progress?.fraction ?? 0) * 100).rounded())) percent")
                            .accessibilityIdentifier("demo.prepare.progress")
                        Text(detail)
                            .font(.footnote).foregroundStyle(Theme.secondaryLabel).monospacedDigit()
                            .accessibilityIdentifier("demo.prepare.detail")
                        Text(phaseTitle)
                            .font(.caption2).foregroundStyle(Theme.secondaryLabel)
                            .accessibilityLabel("Preparation phase")
                            .accessibilityValue(progress?.phase.rawValue ?? "drawing")
                            .accessibilityIdentifier("demo.prepare.phase")
                        if let fallback = progress?.fallback {
                            InlineNotice(tone: .info, title: "Using drawn photos", message: fallback)
                                .accessibilityIdentifier("demo.prepare.fallback")
                        }
                    }
                    .frame(maxWidth: 360)
                }
            } actions: {
                if shouldOfferDrawing {
                    SecondaryButton(title: "Draw Them Instead", id: "demo.prepare.drawInstead") { demo.drawInstead() }
                }
                if failure != nil {
                    PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise", id: "demo.prepare.retry") { demo.retry() }
                }
                SecondaryButton(title: demo.origin == .launch ? "Leave the Demo" : "Cancel", id: "demo.prepare.cancel") {
                    if demo.origin == .launch { leaving = true } else { demo.cancel() }
                }
            }
        }
        .tint(Theme.accent)
        .leaveDemoAlert(isPresented: $leaving)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("demo.prepare")
        .task {
            started = .now
            try? await Task.sleep(for: .seconds(12))
            canOfferDrawing = true
        }
        .onChange(of: progress?.phase) { _, phase in
            if phase == .downloading { Announce.say("Downloading the demo's sample photos.") }
            if phase == .drawing { Announce.say("Drawing the demo's sample photos.") }
        }
    }

    private var phaseTitle: String {
        switch progress?.phase {
        case .downloading: "Downloading sample photos"
        case .assembling: "Preparing sample photos"
        default: "Drawing sample photos"
        }
    }

    private var shouldOfferDrawing: Bool {
        guard canOfferDrawing, let progress, progress.phase == .downloading, progress.fraction < 0.45 else { return false }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return seconds * (0.9 - progress.fraction) / max(progress.fraction, 0.001) > 30
    }

    private var detail: String {
        guard let progress else { return "Getting ready…" }
        if progress.phase == .downloading {
            if progress.total == 0 { return "Checking the review code…" }
            return "\(ByteCountFormatter.string(fromByteCount: Int64(progress.done), countStyle: .file)) of "
                + ByteCountFormatter.string(fromByteCount: Int64(progress.total), countStyle: .file)
        }
        if progress.phase == .assembling { return "Getting the photos ready…" }
        return "\(progress.done) of \(progress.total) photos"
    }
}
