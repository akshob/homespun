// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Testing
import UIKit
import WidgetKit

/// The widgets' views in every size and state, drawn without WidgetKit (which only draws them on a
/// Home Screen, Lock Screen or watch face). Each has to draw; with
/// `TEST_RUNNER_HOMESPUN_WIDGET_SHOTS=<folder>` each state is also saved as a PNG for review: the Home
/// Screen in light and dark, the Lock Screen, and Apple Watch. The system's own tinting (Lock Screen,
/// tinted watch faces) and the watch's fonts and curved corner text are only approximated here.
@MainActor @Suite struct WidgetRenderTests {
    static let now = Date()

    static func snapshot(_ state: String) -> StatusSnapshot? {
        var snapshot = StatusSnapshot.sample(now: now)
        snapshot.lastBackup?.date = now.addingTimeInterval(-2 * 3600)
        switch state {
        case "ready": break
        case "away": snapshot.server?.reachable = false
        case "nothing":
            snapshot.ready = .init(bytes: 0, count: 0)
            snapshot.automatic.enabled = false
        case "locked": snapshot.unlocked = false
        case "unpaired": snapshot.server = nil
        case "stale": snapshot.updatedAt = now.addingTimeInterval(-7 * 3600)
        default: return nil
        }
        return snapshot
    }

    @Test(arguments: ["ready", "away", "nothing", "locked", "unpaired", "empty", "stale"])
    func drawsEverySize(state: String) throws {
        let snapshot = Self.snapshot(state)
        let phone = StatusEntry(date: Self.now, snapshot: snapshot, watch: false)
        let watch = StatusEntry(date: Self.now, snapshot: snapshot, watch: true)
        let sheet = Sheet(state: state, phone: phone, watch: watch)
        for scheme in [ColorScheme.light, .dark] {
            for (name, view) in sheet.homeScreen {
                let image = try #require(Self.render(view.environment(\.colorScheme, scheme)), "\(name) didn't draw")
                #expect(image.size.width > 0)
            }
        }
        if let folder = ProcessInfo.processInfo.environment["HOMESPUN_WIDGET_SHOTS"] {
            let image = try #require(Self.render(sheet))
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(state).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: url)
        }
    }

    static func render(_ view: some View) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage
    }
}

/// One state of the widget in every size, on a page: the Home Screen (light and dark), the Lock Screen,
/// and Apple Watch (the Smart Stack in full colour, faces in a tint).
private struct Sheet: View {
    let state: String
    let phone: StatusEntry
    let watch: StatusEntry

    var homeScreen: [(String, AnyView)] {
        [("small", AnyView(HomeTile(size: CGSize(width: 170, height: 170)) { SmallStatusView(entry: phone) })),
         ("medium", AnyView(HomeTile(size: CGSize(width: 364, height: 170)) { MediumStatusView(entry: phone) }))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Homespun widget: \(state)").font(.title2.weight(.bold))
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                row(scheme == .light ? "Home Screen, light" : "Home Screen, dark") {
                    ForEach(homeScreen, id: \.0) { $0.1 }
                }
                .padding(12)
                .background(scheme == .light ? Color(white: 0.85) : Color(white: 0.12), in: .rect(cornerRadius: 12))
                .environment(\.colorScheme, scheme)
            }
            row("Lock Screen") {
                LockItem(size: CGSize(width: 72, height: 72), circle: true) { CircularStatusView(entry: phone) }
                LockItem(size: CGSize(width: 172, height: 76)) { RectangularStatusView(entry: phone) }
                LockItem(size: CGSize(width: 260, height: 26)) { InlineStatusView(entry: phone) }
            }
            .padding(12)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.36), Color(red: 0.45, green: 0.28, blue: 0.3)],
                                       startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
            .environment(\.widgetRenderingMode, .vibrant)
            ForEach([WidgetRenderingMode.fullColor, .accented], id: \.description) { mode in
                row(mode == .fullColor ? "Apple Watch, Smart Stack and full colour faces" : "Apple Watch, tinted faces") {
                    WatchItem(size: CGSize(width: 50, height: 50), circle: true, mode: mode) { CircularStatusView(entry: watch) }
                    WatchItem(size: CGSize(width: 184, height: 86), stack: mode == .fullColor, mode: mode) {
                        RectangularStatusView(entry: watch)
                    }
                    WatchItem(size: CGSize(width: 192, height: 22), mode: mode) { InlineStatusView(entry: watch) }
                    CornerSketch(entry: watch, mode: mode)
                }
                .padding(12)
                .background(.black, in: .rect(cornerRadius: 12))
                .environment(\.colorScheme, .dark)
                .environment(\.widgetRenderingMode, mode)
            }
        }
        .padding(20)
        .frame(width: 860, alignment: .leading)
        .background(.white)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.gray)
            HStack(alignment: .top, spacing: 16) { content() }
        }
    }
}

/// A Home Screen widget: its background, margins and rounded corners.
private struct HomeTile<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(16).frame(width: size.width, height: size.height)
            .background(WidgetPalette.background).clipShape(.rect(cornerRadius: 22, style: .continuous))
    }
}

/// A Lock Screen widget: white on the wallpaper (the system's vibrancy, roughly).
private struct LockItem<Content: View>: View {
    let size: CGSize
    var circle = false
    @ViewBuilder let content: Content

    var body: some View {
        content.frame(width: size.width, height: size.height)
            .background { if circle { Circle().fill(.white.opacity(0.2)) } }
            .foregroundStyle(.white)
    }
}

/// A watch widget: in the Smart Stack on its background, on a face in white or a tint.
private struct WatchItem<Content: View>: View {
    let size: CGSize
    var circle = false
    var stack = false
    let mode: WidgetRenderingMode
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(stack ? 8 : 0).frame(width: size.width, height: size.height)
            .background {
                if circle { Circle().fill(.white.opacity(0.18)) }
                if stack { RoundedRectangle(cornerRadius: 18).fill(WidgetPalette.stackBackground) }
            }
            .foregroundStyle(mode == .accented ? Color.orange : .white)
    }
}

/// The corner widget, roughly: its symbol in the corner of a face and the headline along the curve.
private struct CornerSketch: View {
    let entry: StatusEntry
    let mode: WidgetRenderingMode

    var body: some View {
        let headline = StatusWords.headline(entry.snapshot, now: entry.date, watch: true)
        ZStack {
            Circle().stroke(.gray.opacity(0.4))
            CurvedText(text: headline, radius: 76).rotationEffect(.degrees(-45))
            CornerStatusView(entry: entry).foregroundStyle(mode == .accented ? Color.orange : WidgetPalette.accent)
                .position(x: 52, y: 52)
        }
        .frame(width: 170, height: 170)
        .foregroundStyle(mode == .accented ? Color.orange : .white)
    }
}

private struct CurvedText: View {
    let text: String
    let radius: CGFloat

    var body: some View {
        let characters = Array(text)
        let step = 5.4
        ZStack {
            ForEach(characters.indices, id: \.self) { index in
                Text(String(characters[index])).font(.system(size: 11, weight: .semibold))
                    .offset(y: -radius)
                    .rotationEffect(.degrees((Double(index) - Double(characters.count - 1) / 2) * step))
            }
        }
    }
}
