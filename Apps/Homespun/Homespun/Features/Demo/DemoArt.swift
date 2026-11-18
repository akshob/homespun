// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The demo's seeded pictures, shared by the app and scripts/demo-media.swift.
/// Keep independent of UIKit and HomespunCore: an original's SHA-256 is its identity.
enum DemoArt {
    nonisolated static let version = 1
    nonisolated static let thumbShortEdge = 360
    nonisolated static let heicQuality = 0.55, jpegQuality = 0.6, thumbQuality = 0.7
    nonisolated static let liveIdentifier = "6F1A7C2E-3B4D-4E5F-9A8B-0C1D2E3F4A5B"

    // MARK: The samples

    /// A scene to draw: what's in it and when.
    struct Scene: Sendable {
        enum Time: Sendable { case dawn, day, sunset, dusk, night }
        enum Ground: Sendable { case mountains, hills, dunes, sea, lake, snow, meadow }
        var time: Time
        var ground: Ground
        var extras: [String] = []
        var seed: UInt64
    }

    struct Recipe: Sendable {
        enum Kind: String, Sendable { case photo, livePhoto = "live_photo", video, screenshot }
        var name: String
        var kind: Kind
        var date: String
        var scene: Scene?
        var portrait = false
        var heic = true
        var favorite = false
        var seconds = 0.0
        var bundled: Bool { kind == .video || kind == .livePhoto }
        var size: (width: Int, height: Int) {
            switch kind {
            case .screenshot: (1206, 2622)
            case .video: (1920, 1080)
            default: portrait ? (3024, 4032) : (4032, 3024)
            }
            private typealias Sample = Recipe
        }
    }

    /// Days out over a few years, a few photos each (a walk, a beach week, holidays, a festival), as a
    /// library has them; the newest include a Live Photo, a video and a screenshot.
    nonisolated static let recipes: [Recipe] = [
        // A mountain weekend, May 2024.
        Sample(
            name: "IMG_0102", kind: .photo, date: "2024-05-11T06:52:10-07:00",
            scene: Scene(time: .dawn, ground: .lake, extras: ["pines"], seed: 1)),
        Sample(
            name: "IMG_0105", kind: .photo, date: "2024-05-11T13:05:44-07:00",
            scene: Scene(time: .day, ground: .mountains, extras: ["clouds", "pines"], seed: 2), heic: false),
        Sample(
            name: "IMG_0109", kind: .photo, date: "2024-05-12T06:31:09-07:00",
            scene: Scene(time: .dawn, ground: .mountains, extras: ["clouds"], seed: 19)),
        // A week at the beach, July 2024.
        Sample(
            name: "IMG_0215", kind: .photo, date: "2024-07-03T20:31:02-07:00",
            scene: Scene(time: .sunset, ground: .sea, extras: ["boat"], seed: 3), favorite: true),
        Sample(
            name: "IMG_0219", kind: .photo, date: "2024-07-04T11:16:37-07:00",
            scene: Scene(time: .day, ground: .sea, extras: ["clouds", "lighthouse"], seed: 4), portrait: true),
        Sample(
            name: "IMG_0224", kind: .video, date: "2024-07-04T15:02:40-07:00",
            scene: Scene(time: .day, ground: .sea, extras: ["clouds"], seed: 8), seconds: 6),
        Sample(
            name: "IMG_0231", kind: .photo, date: "2024-07-05T13:13:13-07:00",
            scene: Scene(time: .day, ground: .sea, extras: ["kite", "clouds"], seed: 20), portrait: true, heic: false),
        Sample(
            name: "IMG_0238", kind: .photo, date: "2024-07-06T21:05:11-07:00",
            scene: Scene(time: .dusk, ground: .sea, extras: ["lighthouse"], seed: 27), heic: false),
        // Autumn, October 2024.
        Sample(
            name: "IMG_0301", kind: .photo, date: "2024-10-19T17:22:08-07:00",
            scene: Scene(time: .sunset, ground: .hills, extras: ["autumn"], seed: 14), favorite: true),
        Sample(
            name: "IMG_0305", kind: .photo, date: "2024-10-20T09:09:09-07:00",
            scene: Scene(time: .day, ground: .hills, extras: ["autumn", "clouds"], seed: 24)),
        Sample(
            name: "IMG_0309", kind: .photo, date: "2024-10-20T15:37:29-07:00",
            scene: Scene(time: .day, ground: .hills, extras: ["rainbow", "clouds"], seed: 13), heic: false),
        // The holidays, December 2024.
        Sample(
            name: "IMG_0352", kind: .photo, date: "2024-12-24T18:02:55-08:00",
            scene: Scene(
                time: .night, ground: .snow,
                extras: ["cake"], seed: 6), portrait: true, favorite: true),
        Sample(
            name: "IMG_0358", kind: .photo, date: "2024-12-30T17:05:03-08:00",
            scene: Scene(time: .dusk, ground: .hills, extras: ["city"], seed: 9), heic: false),
        Sample(
            name: "IMG_0361", kind: .photo, date: "2024-12-31T23:41:16-08:00",
            scene: Scene(time: .night, ground: .hills, extras: ["city"], seed: 15)),
        // Snow, February 2025.
        Sample(
            name: "IMG_0420", kind: .photo, date: "2025-02-08T10:30:12-08:00",
            scene: Scene(time: .day, ground: .snow, extras: ["pines"], seed: 7)),
        Sample(
            name: "IMG_0428", kind: .photo, date: "2025-02-09T22:14:47-08:00",
            scene: Scene(time: .night, ground: .mountains, extras: ["aurora"], seed: 12)),
        // A balloon festival, April 2025.
        Sample(
            name: "IMG_0510", kind: .photo, date: "2025-04-19T08:20:31-07:00",
            scene: Scene(time: .day, ground: .hills, extras: ["balloons", "clouds"], seed: 10), portrait: true),
        Sample(
            name: "IMG_0514", kind: .video, date: "2025-04-19T19:30:05-07:00",
            scene: Scene(time: .sunset, ground: .hills, extras: ["balloons"], seed: 18), seconds: 5),
        Sample(
            name: "IMG_0517", kind: .photo, date: "2025-04-20T11:48:33-07:00",
            scene: Scene(time: .day, ground: .meadow, extras: ["tulips", "clouds"], seed: 17)),
        Sample(
            name: "IMG_0519", kind: .photo, date: "2025-04-20T16:48:20-07:00",
            scene: Scene(time: .day, ground: .meadow, extras: ["flowers", "clouds"], seed: 5), heic: false),
        // Summer at the lake, August 2025.
        Sample(
            name: "IMG_0640", kind: .photo, date: "2025-08-09T20:12:42-07:00",
            scene: Scene(time: .sunset, ground: .lake, extras: ["pines"], seed: 21)),
        Sample(
            name: "IMG_0644", kind: .photo, date: "2025-08-10T10:44:20-07:00",
            scene: Scene(time: .day, ground: .lake, extras: ["boat", "clouds"], seed: 22), heic: false),
        Sample(
            name: "IMG_0651", kind: .photo, date: "2025-08-12T16:26:58-07:00",
            scene: Scene(time: .day, ground: .meadow, extras: ["sunflowers"], seed: 23), portrait: true),
        Sample(
            name: "IMG_0655", kind: .photo, date: "2025-08-13T08:05:51-07:00",
            scene: Scene(
                time: .day, ground: .meadow,
                extras: ["coffee"], seed: 16), portrait: true, heic: false),
        // A sailing weekend, September 2026, and the latest.
        Sample(
            name: "IMG_0941", kind: .photo, date: "2026-09-05T07:20:36-07:00",
            scene: Scene(time: .dawn, ground: .dunes, seed: 26)),
        Sample(
            name: "IMG_0944", kind: .photo, date: "2026-09-05T14:02:19-07:00",
            scene: Scene(time: .day, ground: .dunes, seed: 11)),
        Sample(
            name: "IMG_0950", kind: .livePhoto, date: "2026-09-06T12:31:45-07:00",
            scene: Scene(time: .day, ground: .sea, extras: ["clouds", "boat"], seed: 25), seconds: 2),
        Sample(name: "IMG_0958", kind: .screenshot, date: "2026-09-12T08:15:00-07:00", heic: false),
        Sample(
            name: "IMG_0973", kind: .video, date: "2026-10-04T11:03:27-07:00",
            scene: Scene(time: .day, ground: .meadow, extras: ["kite", "clouds", "flowers"], seed: 28), seconds: 5),
        Sample(
            name: "IMG_0978", kind: .photo, date: "2026-10-04T15:40:02-07:00",
            scene: Scene(time: .day, ground: .mountains, extras: ["pines", "clouds"], seed: 29), portrait: true),
    ]

    // MARK: Drawing

    private struct Random {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + next() * (high - low) }
    }

    nonisolated static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    nonisolated private static func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
        CGColor(
            srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    nonisolated private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    private struct Palette {
        var skyTop: UInt32, skyHorizon: UInt32, sun: UInt32, far: UInt32, near: UInt32, water: UInt32, ground: UInt32
        var light: Double

        static func of(_ time: Scene.Time) -> Palette {
            switch time {
            case .dawn:
                Palette(
                    skyTop: 0x5B6FA8, skyHorizon: 0xF6C3A0, sun: 0xFFE2B0, far: 0x8C86A8, near: 0x4C4E6E,
                    water: 0x9C9CC0, ground: 0x5E6B58, light: 0.8)
            case .day:
                Palette(
                    skyTop: 0x3E7CCB, skyHorizon: 0xBFE0F5, sun: 0xFFF8E1, far: 0x7F9DB8, near: 0x4F7A4A,
                    water: 0x3F8FB8, ground: 0x6E9E4F, light: 1)
            case .sunset:
                Palette(
                    skyTop: 0x2E3A73, skyHorizon: 0xF59A4B, sun: 0xFFD27A, far: 0x7A4B66, near: 0x3B2C44,
                    water: 0xC77A5A, ground: 0x4B3A3A, light: 0.7)
            case .dusk:
                Palette(
                    skyTop: 0x1D2550, skyHorizon: 0x9B6FA8, sun: 0xF2B6C6, far: 0x4A4870, near: 0x262842,
                    water: 0x4D4F7C, ground: 0x2E3346, light: 0.45)
            case .night:
                Palette(
                    skyTop: 0x060B22, skyHorizon: 0x1E2A55, sun: 0xF4F1DE, far: 0x1C2340, near: 0x0E1328,
                    water: 0x1A2550, ground: 0x151B30, light: 0.25)
            }
        }
    }

    nonisolated private static func fillGradient(_ context: CGContext, _ rect: CGRect, top: UInt32, bottom: UInt32) {
        let gradient = CGGradient(colorsSpace: sRGB, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    nonisolated private static func glow(_ context: CGContext, at point: CGPoint, radius: Double, color hex: UInt32, alpha: Double) {
        let gradient = CGGradient(colorsSpace: sRGB, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
    }

    /// A ridge line from midpoint displacement, filled down to `bottom`.
    nonisolated private static func ridge(
        _ context: CGContext, width: Double, base: Double, amplitude: Double, roughness: Double, bottom: Double,
        color hex: UInt32, random: inout Random, smooth: Bool = false
    ) {
        var points = [base + random.range(-amplitude, amplitude), base + random.range(-amplitude, amplitude)]
        var spread = amplitude
        for _ in 0..<8 {
            var next: [Double] = []
            for index in 0..<(points.count - 1) {
                next.append(points[index])
                next.append((points[index] + points[index + 1]) / 2 + random.range(-spread, spread))
            }
            next.append(points.last!)
            points = next
            spread *= roughness
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: bottom))
        for (index, y) in points.enumerated() {
            let x = width * Double(index) / Double(points.count - 1)
            if smooth, index > 0 {
                let previous = CGPoint(x: width * Double(index - 1) / Double(points.count - 1), y: points[index - 1])
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: (previous.x + x) / 2, y: previous.y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.addLine(to: CGPoint(x: width, y: bottom))
        path.closeSubpath()
        context.setFillColor(color(hex))
        context.addPath(path)
        context.fillPath()
    }

    /// Draws a scene into a context whose origin is top-left (y grows downward). `t` (0…1) moves things
    /// for videos and Live Photo motion.
    nonisolated static func draw(_ scene: Scene, in context: CGContext, width w: Double, height h: Double, t: Double = 0) {
        var random = Random(scene.seed)
        let palette = Palette.of(scene.time)
        let horizon = h * (scene.ground == .sea || scene.ground == .lake ? 0.56 : 0.52)
        fillGradient(context, CGRect(x: 0, y: 0, width: w, height: horizon + 2), top: palette.skyTop, bottom: palette.skyHorizon)
        let unit = min(w, h)

        // Stars and moon, or the sun.
        if scene.time == .night || scene.time == .dusk {
            for _ in 0..<(scene.time == .night ? 420 : 120) {
                let x = random.range(0, w)
                let y = random.range(0, horizon * 0.9)
                let r = random.range(0.6, 2.4) * unit / 1500
                context.setFillColor(color(0xFFFFFF, random.range(0.3, 0.95)))
                context.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
            }
        }
        if scene.extras.contains("aurora") {
            for band in 0..<4 {
                let path = CGMutablePath()
                let top = horizon * (0.12 + Double(band) * 0.08)
                path.move(to: CGPoint(x: 0, y: top))
                for step in 0...40 {
                    let x = w * Double(step) / 40
                    path.addLine(to: CGPoint(x: x, y: top + sin(Double(step) * 0.35 + Double(band) + t * 2) * unit * 0.05))
                }
                context.saveGState()
                context.addPath(path)
                context.setStrokeColor(color(band % 2 == 0 ? 0x5CF2B0 : 0x7FD8F0, 0.18))
                context.setLineWidth(unit * 0.08)
                context.setLineCap(.round)
                context.setBlendMode(.screen)
                context.strokePath()
                context.restoreGState()
            }
        }
        let sunY: Double =
            switch scene.time {
            case .dawn: horizon * 0.82
            case .day: horizon * 0.25
            case .sunset: horizon * 0.78 + t * unit * 0.04
            case .dusk: horizon * 0.35
            case .night: horizon * 0.25
            }
        let sunX = w * (0.25 + random.next() * 0.5)
        let sunRadius = unit * (scene.time == .night ? 0.045 : 0.06)
        if !scene.extras.contains("cake"), !scene.extras.contains("coffee") {
            glow(
                context, at: CGPoint(x: sunX, y: sunY), radius: sunRadius * 6, color: palette.sun,
                alpha: scene.time == .night ? 0.25 : 0.55)
            context.setFillColor(color(palette.sun))
            context.fillEllipse(in: CGRect(x: sunX - sunRadius, y: sunY - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
            if scene.time == .night {
                context.setFillColor(color(palette.skyTop, 0.9))
                context.fillEllipse(
                    in: CGRect(
                        x: sunX - sunRadius * 0.55, y: sunY - sunRadius * 1.1, width: sunRadius * 2,
                        height: sunRadius * 2))
            }
        }

        // Clouds, drifting.
        if scene.extras.contains("clouds") {
            for _ in 0..<6 {
                let cx = (random.range(-0.1, 1.1) * w + t * unit * 0.15).truncatingRemainder(dividingBy: w * 1.2)
                let cy = random.range(0.08, 0.4) * horizon
                let size = random.range(0.08, 0.16) * unit
                for _ in 0..<7 {
                    let dx = random.range(-1.4, 1.4) * size
                    let dy = random.range(-0.3, 0.3) * size
                    let r = random.range(0.4, 0.8) * size
                    context.setFillColor(color(mix(0xFFFFFF, palette.skyHorizon, 0.25), 0.55 * palette.light + 0.2))
                    context.fillEllipse(in: CGRect(x: cx + dx - r, y: cy + dy - r * 0.6, width: r * 2, height: r * 1.2))
                }
            }
        }
        if scene.extras.contains("rainbow") {
            let colors: [UInt32] = [0xE84A5F, 0xFF9F43, 0xFECA57, 0x48DBA0, 0x54A0FF, 0x8E6CEF]
            for (index, hex) in colors.enumerated() {
                let radius = unit * (0.62 - Double(index) * 0.025)
                context.setStrokeColor(color(hex, 0.35))
                context.setLineWidth(unit * 0.025)
                context.addArc(
                    center: CGPoint(x: w * 0.55, y: horizon * 1.05), radius: radius, startAngle: .pi, endAngle: 0,
                    clockwise: false)
                context.strokePath()
            }
        }

        // The land, far to near.
        switch scene.ground {
        case .mountains, .snow:
            ridge(
                context, width: w, base: horizon * 0.62, amplitude: unit * 0.12, roughness: 0.55, bottom: h,
                color: mix(palette.far, palette.skyHorizon, 0.35), random: &random)
            ridge(
                context, width: w, base: horizon * 0.85, amplitude: unit * 0.08, roughness: 0.6, bottom: h,
                color: palette.far, random: &random)
            fillGradient(
                context, CGRect(x: 0, y: horizon, width: w, height: h - horizon),
                top: scene.ground == .snow ? 0xE8EEF5 : palette.ground,
                bottom: scene.ground == .snow ? 0xC9D6E6 : mix(palette.ground, 0x000000, 0.3))
        case .hills, .meadow:
            ridge(
                context, width: w, base: horizon * 0.9, amplitude: unit * 0.05, roughness: 0.5, bottom: h,
                color: mix(palette.far, palette.skyHorizon, 0.3), random: &random, smooth: true)
            ridge(
                context, width: w, base: horizon * 1.02, amplitude: unit * 0.04, roughness: 0.5, bottom: h,
                color: mix(palette.ground, palette.far, 0.4), random: &random, smooth: true)
            fillGradient(
                context, CGRect(x: 0, y: horizon * 1.08, width: w, height: h - horizon * 1.08),
                top: palette.ground, bottom: mix(palette.ground, 0x1E3A12, 0.5))
        case .dunes:
            for layer in 0..<4 {
                let tone = mix(0xE9B872, 0xB5713E, Double(layer) / 3)
                ridge(
                    context, width: w, base: horizon + Double(layer) * unit * 0.1, amplitude: unit * 0.05, roughness: 0.45,
                    bottom: h, color: mix(tone, palette.skyTop, 1 - palette.light), random: &random, smooth: true)
            }
        case .sea, .lake:
            if scene.ground == .lake {
                ridge(
                    context, width: w, base: horizon * 0.88, amplitude: unit * 0.07, roughness: 0.55, bottom: horizon,
                    color: mix(palette.far, palette.skyHorizon, 0.2), random: &random)
            }
            fillGradient(
                context, CGRect(x: 0, y: horizon, width: w, height: h - horizon),
                top: mix(palette.water, palette.skyHorizon, 0.35), bottom: mix(palette.water, 0x000000, 0.35))
            // Waves and the sun's path on the water.
            for row in 0..<90 {
                let y = horizon + pow(Double(row) / 90, 1.6) * (h - horizon)
                let length = unit * (0.01 + Double(row) * 0.0012)
                for _ in 0..<(8 + row / 6) {
                    let x = (random.range(0, w) + t * unit * 0.05 * Double(row % 3 + 1)).truncatingRemainder(dividingBy: w)
                    let near = abs(x - sunX) < unit * (0.04 + Double(row) * 0.002)
                    context.setStrokeColor(color(near ? palette.sun : 0xFFFFFF, near ? 0.55 : 0.12))
                    context.setLineWidth(max(1, unit * 0.002 * (1 + Double(row) / 30)))
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x + length, y: y))
                    context.strokePath()
                }
            }
            if scene.ground == .sea {
                fillGradient(context, CGRect(x: 0, y: h * 0.86, width: w, height: h * 0.14), top: 0xE5CFA3, bottom: 0xC9AE7C)
            }
        }

        // Things in front.
        if scene.extras.contains("pines") {
            for index in 0..<26 {
                let x = random.range(-0.05, 1.05) * w
                let base = horizon * (1.0 + random.range(0, 0.12)) + (scene.ground == .lake ? 0 : unit * 0.02)
                let height = unit * random.range(0.08, 0.2) * (index < 10 ? 0.7 : 1)
                context.setFillColor(color(mix(palette.near, 0x0B2B1A, 0.4)))
                for tier in 0..<4 {
                    let top = base - height + Double(tier) * height * 0.2
                    let half = height * (0.12 + Double(tier) * 0.05)
                    context.move(to: CGPoint(x: x, y: top))
                    context.addLine(to: CGPoint(x: x - half, y: top + height * 0.35))
                    context.addLine(to: CGPoint(x: x + half, y: top + height * 0.35))
                    context.closePath()
                    context.fillPath()
                }
            }
        }
        if scene.extras.contains("autumn") {
            for _ in 0..<18 {
                let x = random.range(0, w)
                let base = horizon * random.range(1.05, 1.25)
                let size = unit * random.range(0.04, 0.09)
                context.setFillColor(color(0x4A3424))
                context.fill(CGRect(x: x - size * 0.08, y: base - size, width: size * 0.16, height: size * 1.2))
                let leaf: UInt32 = [0xD9822B, 0xC0392B, 0xE1B12C, 0xA0522D][Int(random.next() * 4)]
                context.setFillColor(color(mix(leaf, palette.skyTop, 1 - palette.light)))
                context.fillEllipse(in: CGRect(x: x - size, y: base - size * 2, width: size * 2, height: size * 1.6))
            }
        }
        if scene.extras.contains("flowers") || scene.extras.contains("tulips") || scene.extras.contains("sunflowers") {
            let tones: [UInt32] =
                scene.extras.contains("sunflowers")
                ? [0xF6C90E, 0xF4B400]
                : scene.extras.contains("tulips") ? [0xE84A5F, 0xFF6F91, 0xFFC75F, 0xF9F871] : [0xFFFFFF, 0xF8B4D9, 0xC7A6F7, 0xFFE066]
            for _ in 0..<700 {
                let depth = random.next()
                let y = horizon * 1.1 + depth * (h - horizon * 1.1)
                let size = unit * (0.003 + depth * 0.018)
                let x = random.range(0, w)
                if scene.extras.contains("sunflowers") || scene.extras.contains("tulips") {
                    context.setStrokeColor(color(0x2F6B2F))
                    context.setLineWidth(max(1, size * 0.15))
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x, y: y + size * 2.5))
                    context.strokePath()
                }
                context.setFillColor(color(tones[Int(random.next() * Double(tones.count)) % tones.count]))
                context.fillEllipse(in: CGRect(x: x - size, y: y - size, width: size * 2, height: size * 2))
                if scene.extras.contains("sunflowers") {
                    context.setFillColor(color(0x5B3A1A))
                    context.fillEllipse(in: CGRect(x: x - size * 0.4, y: y - size * 0.4, width: size * 0.8, height: size * 0.8))
                }
            }
        }
        if scene.extras.contains("city") {
            var x = 0.0
            while x < w {
                let width = unit * random.range(0.04, 0.1)
                let height = unit * random.range(0.1, 0.38)
                let top = horizon * 1.02 - height
                context.setFillColor(color(mix(palette.near, 0x000000, 0.2)))
                context.fill(CGRect(x: x, y: top, width: width, height: height + h))
                let lit = scene.time == .night ? 0.55 : 0.3
                var wy = top + unit * 0.012
                while wy < horizon {
                    var wx = x + unit * 0.008
                    while wx < x + width - unit * 0.012 {
                        if random.next() < lit {
                            context.setFillColor(color(0xFFD98A, random.range(0.6, 1)))
                            context.fill(CGRect(x: wx, y: wy, width: unit * 0.008, height: unit * 0.011))
                        }
                        wx += unit * 0.016
                    }
                    wy += unit * 0.022
                }
                x += width + unit * random.range(0.002, 0.02)
            }
        }
        if scene.extras.contains("lighthouse") {
            let x = w * 0.78
            let base = horizon * 1.0
            let height = unit * 0.32
            let half = unit * 0.035
            context.setFillColor(color(0x3B3B3B))
            context.fill(CGRect(x: x - half * 2.2, y: base - unit * 0.02, width: half * 4.4, height: unit * 0.05))
            for stripe in 0..<5 {
                let top = base - height + Double(stripe) * height / 5
                context.setFillColor(color(stripe % 2 == 0 ? 0xF2F2F2 : 0xC0392B))
                let narrow = half * (0.75 + Double(stripe) * 0.06)
                context.fill(CGRect(x: x - narrow, y: top, width: narrow * 2, height: height / 5 + 1))
            }
            if scene.time == .dusk || scene.time == .night || scene.time == .sunset {
                glow(context, at: CGPoint(x: x, y: base - height - unit * 0.02), radius: unit * 0.25, color: 0xFFF1B5, alpha: 0.6)
            }
            context.setFillColor(color(0x222222))
            context.fill(CGRect(x: x - half * 0.9, y: base - height - unit * 0.04, width: half * 1.8, height: unit * 0.04))
        }
        if scene.extras.contains("boat") {
            let x = w * (0.3 + t * 0.06)
            let y = horizon + (h - horizon) * 0.18
            let size = unit * 0.07
            context.setFillColor(color(0x5B3A29))
            context.move(to: CGPoint(x: x - size, y: y))
            context.addLine(to: CGPoint(x: x + size, y: y))
            context.addLine(to: CGPoint(x: x + size * 0.7, y: y + size * 0.25))
            context.addLine(to: CGPoint(x: x - size * 0.7, y: y + size * 0.25))
            context.closePath()
            context.fillPath()
            context.setFillColor(color(0xFAFAFA, 0.95))
            context.move(to: CGPoint(x: x, y: y - size * 1.6))
            context.addLine(to: CGPoint(x: x + size * 0.8, y: y - size * 0.1))
            context.addLine(to: CGPoint(x: x, y: y - size * 0.1))
            context.closePath()
            context.fillPath()
        }
        if scene.extras.contains("balloons") {
            let tones: [(UInt32, UInt32)] = [(0xE84A5F, 0xFECA57), (0x54A0FF, 0xFFFFFF), (0x10AC84, 0xFF9F43), (0x8E6CEF, 0xF8B4D9)]
            for index in 0..<4 {
                let x = w * random.range(0.15, 0.85)
                let y = horizon * random.range(0.25, 0.75) - t * unit * 0.12
                let r = unit * random.range(0.035, 0.075) * (index == 0 ? 1.4 : 1)
                let (a, b) = tones[index]
                context.saveGState()
                context.addEllipse(in: CGRect(x: x - r, y: y - r * 1.15, width: r * 2, height: r * 2.3))
                context.clip()
                for stripe in 0..<6 {
                    context.setFillColor(color(stripe % 2 == 0 ? a : b))
                    context.fill(CGRect(x: x - r + Double(stripe) * r / 3, y: y - r * 1.2, width: r / 3 + 1, height: r * 2.4))
                }
                context.restoreGState()
                context.setFillColor(color(0x6B4A2B))
                context.fill(CGRect(x: x - r * 0.2, y: y + r * 1.35, width: r * 0.4, height: r * 0.3))
            }
        }
        if scene.extras.contains("kite") {
            let x = w * (0.62 + sin(t * 6) * 0.02)
            let y = horizon * 0.3
            let size = unit * 0.06
            context.setFillColor(color(0xE84A5F))
            context.move(to: CGPoint(x: x, y: y - size))
            context.addLine(to: CGPoint(x: x + size * 0.7, y: y))
            context.addLine(to: CGPoint(x: x, y: y + size * 1.3))
            context.addLine(to: CGPoint(x: x - size * 0.7, y: y))
            context.closePath()
            context.fillPath()
            context.setStrokeColor(color(0xFFFFFF, 0.8))
            context.setLineWidth(max(1, unit * 0.002))
            context.move(to: CGPoint(x: x, y: y + size * 1.3))
            for step in 1...12 {
                context.addLine(
                    to: CGPoint(
                        x: x - Double(step) * size * 0.25,
                        y: y + size * 1.3 + Double(step) * size * 0.45
                            + sin(Double(step) + t * 8) * size * 0.2))
            }
            context.strokePath()
        }
        if scene.extras.contains("cake") {
            // Indoors: a warm room with lights, a table and a cake with candles.
            fillGradient(context, CGRect(x: 0, y: 0, width: w, height: h), top: 0x2B1B2E, bottom: 0x5A3A3A)
            for _ in 0..<40 {
                let x = random.range(0, w)
                let y = random.range(0, h * 0.5)
                let r = unit * random.range(0.02, 0.07)
                glow(
                    context, at: CGPoint(x: x, y: y), radius: r, color: [0xFFD98A, 0xF8B4D9, 0x9AD0F5][Int(random.next() * 3)],
                    alpha: 0.45)
            }
            fillGradient(context, CGRect(x: 0, y: h * 0.62, width: w, height: h * 0.38), top: 0x7A4E2D, bottom: 0x4A2E1A)
            let cx = w / 2
            let top = h * 0.48
            let width = unit * 0.5
            context.setFillColor(color(0xF4E1D2))
            context.fillEllipse(in: CGRect(x: cx - width * 0.65, y: h * 0.6, width: width * 1.3, height: unit * 0.1))
            context.setFillColor(color(0xFFF3E6))
            context.fill(CGRect(x: cx - width / 2, y: top, width: width, height: h * 0.64 - top))
            context.setFillColor(color(0xF8B4D9))
            context.fill(CGRect(x: cx - width / 2, y: top + (h * 0.64 - top) * 0.45, width: width, height: unit * 0.025))
            context.setFillColor(color(0xFFF8F0))
            context.fillEllipse(in: CGRect(x: cx - width / 2, y: top - unit * 0.035, width: width, height: unit * 0.07))
            for index in 0..<5 {
                let x = cx - width * 0.32 + Double(index) * width * 0.16
                context.setFillColor(color([0x54A0FF, 0xFECA57, 0xE84A5F, 0x10AC84, 0x8E6CEF][index]))
                context.fill(CGRect(x: x - unit * 0.006, y: top - unit * 0.1, width: unit * 0.012, height: unit * 0.08))
                glow(context, at: CGPoint(x: x, y: top - unit * 0.115), radius: unit * 0.04, color: 0xFFD27A, alpha: 0.9)
                context.setFillColor(color(0xFFF1B5))
                context.fillEllipse(in: CGRect(x: x - unit * 0.006, y: top - unit * 0.13, width: unit * 0.012, height: unit * 0.025))
            }
        }
        if scene.extras.contains("coffee") {
            // A table from above: planks, a saucer, a cup with a heart in the foam.
            for plank in 0..<8 {
                let tone = mix(0x8B5A3C, 0x6B4226, Double(plank % 3) / 2)
                context.setFillColor(color(tone))
                context.fill(CGRect(x: 0, y: Double(plank) * h / 8, width: w, height: h / 8 - unit * 0.004))
            }
            let cx = w / 2
            let cy = h / 2
            context.setFillColor(color(0xF2F2F2))
            context.fillEllipse(in: CGRect(x: cx - unit * 0.33, y: cy - unit * 0.33, width: unit * 0.66, height: unit * 0.66))
            context.setFillColor(color(0xFFFFFF))
            context.fillEllipse(in: CGRect(x: cx - unit * 0.22, y: cy - unit * 0.22, width: unit * 0.44, height: unit * 0.44))
            context.setFillColor(color(0x7B4B2A))
            context.fillEllipse(in: CGRect(x: cx - unit * 0.18, y: cy - unit * 0.18, width: unit * 0.36, height: unit * 0.36))
            context.setFillColor(color(0xEAD7C3))
            let heart = unit * 0.07
            context.fillEllipse(in: CGRect(x: cx - heart, y: cy - heart * 0.8, width: heart, height: heart))
            context.fillEllipse(in: CGRect(x: cx, y: cy - heart * 0.8, width: heart, height: heart))
            context.move(to: CGPoint(x: cx - heart * 0.95, y: cy - heart * 0.15))
            context.addLine(to: CGPoint(x: cx + heart * 0.95, y: cy - heart * 0.15))
            context.addLine(to: CGPoint(x: cx, y: cy + heart * 0.9))
            context.closePath()
            context.fillPath()
            context.setFillColor(color(0xFFFFFF))
            context.fill(CGRect(x: cx + unit * 0.21, y: cy - unit * 0.035, width: unit * 0.12, height: unit * 0.07))
        }
    }

    /// Fine grain, so the photos look (and compress) like photos rather than flat drawings.
    nonisolated static func grain(_ context: CGContext, width: Int, height: Int, seed: UInt64) {
        let tile = 256
        var random = Random(seed)
        var pixels = [UInt8](repeating: 0, count: tile * tile)
        for index in pixels.indices { pixels[index] = UInt8(random.range(0, 255)) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: tile, height: tile, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: tile,
            space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        context.saveGState()
        context.setAlpha(0.03)
        context.setBlendMode(.overlay)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                context.draw(image, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
        context.restoreGState()
    }

    nonisolated static func render(width: Int, height: Int, flipped: Bool = true, _ body: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if flipped {
            context.translateBy(x: 0, y: Double(height))
            context.scaleBy(x: 1, y: -1)
        }
        body(context)
        return context.makeImage()!
    }

    nonisolated static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage {
        let scale = Double(maxEdge) / Double(max(image.width, image.height))
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        return render(width: width, height: height, flipped: false) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: Writing

    nonisolated static func dateParts(_ iso: String) -> (date: Date, exif: String, offset: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let date = ISO8601DateFormatter().date(from: iso)!
        let offset = String(iso.suffix(6))
        let sign = offset.hasPrefix("-") ? -1 : 1
        let hours = Int(offset.dropFirst().prefix(2))!
        let minutes = Int(offset.suffix(2))!
        formatter.timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
        return (date, formatter.string(from: date), offset)
    }

    nonisolated static func writeImage(
        _ image: CGImage, to url: URL, type: UTType, quality: Double, date: String?, contentIdentifier: String? = nil,
        screenshot: Bool = false
    ) throws {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let date {
            let parts = dateParts(date)
            var exif: [CFString: Any] = [
                kCGImagePropertyExifDateTimeOriginal: parts.exif,
                kCGImagePropertyExifDateTimeDigitized: parts.exif,
                kCGImagePropertyExifOffsetTimeOriginal: parts.offset,
            ]
            if screenshot { exif[kCGImagePropertyExifUserComment] = "Screenshot" }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if let contentIdentifier { properties[kCGImagePropertyMakerAppleDictionary] = ["17": contentIdentifier] }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A screenshot of a pretend notes app: a plain list, drawn with text.
    nonisolated static func screenshot() -> CGImage {
        let width = 1206
        let height = 2622
        return render(width: width, height: height, flipped: false) { context in
            context.setFillColor(color(0xFBF8F1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func text(_ string: String, x: Double, y: Double, size: Double, weight: Double = 0, hex: UInt32 = 0x1C1C1E) {
                let font = CTFontCreateWithName((weight > 0 ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
                let attributed = NSAttributedString(
                    string: string,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex),
                    ])
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: x, y: Double(height) - y)
                CTLineDraw(line, context)
            }
            text("9:41", x: 120, y: 120, size: 50, weight: 1)
            text("Weekend", x: 72, y: 380, size: 104, weight: 1)
            text("Saturday, September 12", x: 72, y: 470, size: 46, hex: 0x8E8E93)
            let rows = [
                "Pick up the prints from the shop", "Call Grandma about Sunday", "Plant the tulip bulbs",
                "Back up the beach photos", "Fix the bike's back light", "Buy film for the trip",
                "Water the tomatoes", "Bake bread for the picnic",
            ]
            for (index, row) in rows.enumerated() {
                let y = 640 + Double(index) * 190
                let done = index % 3 == 1
                context.setStrokeColor(color(0xE0A100))
                context.setLineWidth(6)
                context.strokeEllipse(in: CGRect(x: 72, y: Double(height) - y - 26, width: 64, height: 64))
                if done {
                    context.setFillColor(color(0xE0A100))
                    context.fillEllipse(in: CGRect(x: 84, y: Double(height) - y - 14, width: 40, height: 40))
                }
                text(row, x: 172, y: y + 20, size: 54, hex: done ? 0x8E8E93 : 0x1C1C1E)
                context.setFillColor(color(0xE5E5EA))
                context.fill(CGRect(x: 172, y: Double(height) - y - 95, width: Double(width) - 172, height: 3))
            }
        }
    }

    nonisolated static func photo(_ recipe: Recipe) -> CGImage {
        let (width, height) = recipe.size
        return render(width: width, height: height) { context in
            draw(recipe.scene!, in: context, width: Double(width), height: Double(height), t: recipe.kind == .livePhoto ? 0.5 : 0)
            grain(context, width: width, height: height, seed: recipe.scene!.seed)
        }
    }

    nonisolated static func thumbnail(of image: CGImage) -> CGImage {
        let short = Double(min(image.width, image.height))
        let long = Double(max(image.width, image.height))
        return scaled(image, maxEdge: Int((Double(thumbShortEdge) * long / short).rounded()))
    }

    nonisolated static func videoThumbnail(_ recipe: Recipe) -> CGImage {
        render(width: 640, height: 360) { draw(recipe.scene!, in: $0, width: 640, height: 360) }
    }

    struct Entry: Codable, Sendable {
        var name: String
        var kind: String
        var date: String
        var width: Int
        var height: Int
        var seconds: Double?
        var favorite: Bool?
        var screenshot: Bool?
        /// Files by role: "photo", "video", "paired_video".
        var files: [String: String]
        /// The compact copy's files the pretend server sends back (only for videos and Live Photos; it
        /// makes photos' own by shrinking them).
        var compact: [String: String]?
        /// The grid's picture of it (and of its compact copy).
        var thumbnail: String?
    }

}
