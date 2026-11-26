// SPDX-License-Identifier: Apache-2.0
import SwiftUI

// Where the demo shows itself: Try the Demo (setup's first page; Help and About), the Demo marker,
// and Leave the Demo (the Server tab, Help and About, setup's pages).

/// Setup's first page: try Homespun on sample photos.
struct TryTheDemoButton: View {
    var body: some View {
        VStack(spacing: 0) {
            SecondaryButton(title: "Try the Demo", systemImage: "play.rectangle", id: "setup.demo") { DemoMode.shared.start() }
                .disabled(DemoMode.shared.settling || DemoMode.shared.isPreparing)
            Text("See how Homespun works with sample photos. Nothing on this iPhone is changed.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// Help and About: try the demo (the person's own app), or leave it (the demo's).
struct DemoHelpSection: View {
    let model: AppModel
    @State private var confirming = false

    /// The demo takes the screen: not while the person's own backup, freeing up or restoring runs.
    private var busy: String? {
        if model.job.isRunning { return "backing up" }
        if model.library.isRemoving { return "freeing up space" }
        if model.library.isRestoring { return "restoring originals" }
        return nil
    }

    var body: some View {
        Section {
            if model.settings.isDemo {
                LeaveDemoButton()
            } else {
                Button { confirming = true } label: {
                    ServerRow(title: "Try the Demo", symbol: "play.rectangle", value: nil, chevron: true)
                }
                .buttonStyle(.plain)
                .disabled(busy != nil || DemoMode.shared.settling || DemoMode.shared.isPreparing)
                .accessibilityHint(busy.map { "Available once Homespun has finished \($0)." } ?? "")
                .accessibilityIdentifier("help.demo")
            }
        } footer: {
            if model.settings.isDemo {
                Text("You're in the demo: sample photos and a pretend server. Leaving clears it and returns to your own Homespun.")
            } else {
                Text(busy.map { "Try the Demo is available once Homespun has finished \($0), so it doesn't interrupt it." }
                     ?? "See how Homespun works with sample photos and a pretend server. Your own photos, server and settings "
                        + "stay as they are.")
            }
        }
        .listRowBackground(Theme.card)
        .alert("Try the demo?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Try the Demo") { DemoMode.shared.start() }
                .accessibilityIdentifier("help.demo.confirm")
        } message: {
            Text("Homespun shows sample photos and a pretend server. Nothing on this iPhone is changed. Leave the demo any "
                 + "time in the Server tab.")
        }
    }
}

/// Leave the Demo, after saying what it clears.
struct LeaveDemoButton: View {
    var prominent = false
    @State private var confirming = false

    var body: some View {
        Group {
            if prominent {
                Button { confirming = true } label: {
                    Label("Leave the Demo", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).tint(Theme.accent)
            } else {
                Button { confirming = true } label: {
                    ServerRow(title: "Leave the Demo", symbol: "rectangle.portrait.and.arrow.right", value: nil, chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("demo.leave")
        .leaveDemoAlert(isPresented: $confirming)
    }
}

extension View {
    /// Asks before leaving the demo.
    func leaveDemoAlert(isPresented: Binding<Bool>) -> some View {
        alert("Leave the demo?", isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Leave the Demo", role: .destructive) { DemoMode.shared.leave() }
                .accessibilityIdentifier("demo.leave.confirm")
        } message: {
            Text("The sample photos, the pretend server and everything you did in the demo are cleared. Your own photos and "
                 + "settings stay as they are.")
        }
    }

    /// In the demo, a Demo mark in the toolbar that leaves it (setup's pages).
    func demoMarker(_ active: Bool, leave: @escaping () -> Void) -> some View {
        modifier(DemoMarker(active: active, leave: leave))
    }
}

/// The Server tab's top card in the demo: what it is, and the way out.
struct DemoCard: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("You're trying the demo").font(.headline).foregroundStyle(Theme.label)
                } icon: {
                    Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                }
                Text("Sample photos and a pretend server, Homespun Demo. Nothing on this iPhone is changed: freeing up space "
                     + "here deletes nothing, and your own photos are never read.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                LeaveDemoButton(prominent: true)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("demo.card")
        }
        .listRowBackground(Theme.accentSoft)
    }
}

private struct DemoMarker: ViewModifier {
    let active: Bool
    let leave: () -> Void

    func body(content: Content) -> some View {
        if active {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Leave the Demo", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                leave()
                            }
                            .accessibilityIdentifier("demo.leave")
                        } label: {
                            Text("Demo").font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("Demo")
                        .accessibilityHint("Leave the demo from here.")
                        .accessibilityIdentifier("demo.menu")
                    }
                }
        } else {
            content
        }
    }
}
