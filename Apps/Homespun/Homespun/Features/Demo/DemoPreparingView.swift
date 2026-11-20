// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct DemoPreparingView: View {
    let demo: DemoMode
    @State private var leaving = false

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
            SetupScaffold(symbol: "paintbrush.pointed", title: failure?.title ?? "Preparing the Demo",
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
                        Text(progress?.phase.rawValue ?? "drawing")
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
    }

    private var detail: String {
        guard let progress else { return "Getting ready…" }
        if progress.phase == .downloading {
            return "\(ByteCountFormatter.string(fromByteCount: Int64(progress.done), countStyle: .file)) of "
                + ByteCountFormatter.string(fromByteCount: Int64(progress.total), countStyle: .file)
        }
        if progress.phase == .assembling { return "Getting the photos ready…" }
        return "\(progress.done) of \(progress.total) photos"
    }
}
