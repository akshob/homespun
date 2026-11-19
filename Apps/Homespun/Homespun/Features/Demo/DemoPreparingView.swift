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
        DemoPreparationContent(failure: failure, progress: progress,
                               cancelTitle: demo.origin == .launch ? "Leave the Demo" : "Cancel",
                               retry: { demo.retry() },
                               cancel: { if demo.origin == .launch { leaving = true } else { demo.cancel() } })
            .leaveDemoAlert(isPresented: $leaving)
    }
}

struct DemoPreparationContent: View {
    let failure: DemoMediaStore.Failure?
    let progress: DemoMediaStore.Progress?
    var cancelTitle: String
    var retry: () -> Void
    var cancel: () -> Void

    var body: some View {
        NavigationStack {
            SetupScaffold(symbol: "paintbrush.pointed", title: failure?.title ?? "Preparing the Demo",
                          subtitle: failure == nil
                              ? "Homespun is drawing the demo's sample photos on this iPhone. This takes a few seconds." : nil,
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
                        Text(progress.map { "\($0.done) of \($0.total) photos" } ?? "Getting ready…")
                            .font(.footnote).foregroundStyle(Theme.secondaryLabel).monospacedDigit()
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: 360)
                }
            } actions: {
                if failure != nil {
                    PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise", id: "demo.prepare.retry", action: retry)
                }
                SecondaryButton(title: cancelTitle, id: "demo.prepare.cancel", action: cancel)
            }
        }
        .tint(Theme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("demo.prepare")
    }
}
