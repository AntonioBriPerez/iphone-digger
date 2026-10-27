// Renders the app icon and fills iPhoneDigger/Assets.xcassets/AppIcon.appiconset.
// Usage: swift tools/make-icon.swift   (from the repo root)
import AppKit
import SwiftUI

/// Heartbeat line that crosses the phone: the "live" in live observability.
struct Pulse: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.5), (0.3, 0.5), (0.38, 0.22), (0.47, 0.9), (0.56, 0.0), (0.64, 0.62), (0.7, 0.5), (1, 0.5)]
        var p = Path()
        p.addLines(pts.map { CGPoint(x: r.minX + $0.0 * r.width, y: r.minY + $0.1 * r.height) })
        return p
    }
}

/// Soil strata at the bottom of the tile: the "digger".
struct Strata: Shape {
    let level: CGFloat
    let phase: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.height * level
        p.move(to: CGPoint(x: 0, y: y))
        for i in stride(from: 0, through: 1, by: 0.02) {
            let x = r.width * i
            p.addLine(to: CGPoint(x: x, y: y + sin((i * 2.2 + phase) * .pi) * r.height * 0.025))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: r.height))
        p.closeSubpath()
        return p
    }
}

struct Icon: View {
    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.42), Color(red: 0.03, green: 0.36, blue: 0.47)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Strata(level: 0.7, phase: 0).fill(Color(red: 0.36, green: 0.24, blue: 0.16).opacity(0.85))
                // phone half-dug out of the ground: the front strata cover its base
                RoundedRectangle(cornerRadius: 64, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.06, blue: 0.14).opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 64, style: .continuous).stroke(.white, lineWidth: 24))
                    .overlay(alignment: .top) { Capsule().fill(.white).frame(width: 96, height: 28).padding(.top, 44) }
                    .frame(width: 320, height: 600)
                    .offset(y: 40)
                Strata(level: 0.8, phase: 0.6).fill(Color(red: 0.29, green: 0.18, blue: 0.11))
                Strata(level: 0.9, phase: 1.3).fill(Color(red: 0.18, green: 0.11, blue: 0.07))
            }
            .frame(width: 824, height: 824)
            .clipShape(tile)
            .overlay(tile.stroke(.white.opacity(0.12), lineWidth: 4))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 14)

            Pulse()
                .stroke(LinearGradient(colors: [Color(red: 0.4, green: 1, blue: 0.75), Color(red: 0.2, green: 0.85, blue: 1)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 26, lineCap: .round, lineJoin: .round))
                .frame(width: 600, height: 230)
                .shadow(color: Color(red: 0.4, green: 1, blue: 0.8).opacity(0.8), radius: 18)
                .offset(y: -20)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let dir = URL(fileURLWithPath: "iPhoneDigger/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon_1024.png"))

    var images: [[String: String]] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let name = "icon_\(px).png"
            if px != 1024 {
                let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                try small.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            }
            images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    try #"{"info":{"version":1,"author":"xcode"}}"#.write(to: dir.deletingLastPathComponent().appendingPathComponent("Contents.json"),
                                                         atomically: true, encoding: .utf8)
}

try MainActor.assumeIsolated { try render() }
