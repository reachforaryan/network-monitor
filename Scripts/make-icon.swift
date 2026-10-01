// Draws the app icon and writes NetworkMonitor.icns.
// Run with: swift Scripts/make-icon.swift
//
// The mark is the app's own hatched meter, rising — the same slanted bars the widget
// draws, so the icon and the UI are visibly the same object.

import AppKit
import SwiftUI

let canvas: CGFloat = 1024

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS rounds the icon itself; the inset leaves the standard margin.
            RoundedRectangle(cornerRadius: canvas * 0.2237, style: .continuous)
                .fill(.black)
                .overlay {
                    RoundedRectangle(cornerRadius: canvas * 0.2237, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: canvas * 0.012)
                }

            Canvas { context, size in
                let bars = 4
                let slant = size.width * 0.052
                let barWidth = size.width * 0.112
                let gap = size.width * 0.052
                let totalWidth = CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap
                let left = (size.width - totalWidth - slant) / 2
                let bottom = size.height * 0.735
                let shortest = size.height * 0.145
                let tallest = size.height * 0.5

                for index in 0..<bars {
                    let x = left + CGFloat(index) * (barWidth + gap)
                    let height = shortest + (tallest - shortest) * CGFloat(index) / CGFloat(bars - 1)
                    let top = bottom - height

                    let bar = Path { path in
                        path.move(to: CGPoint(x: x + slant, y: top))
                        path.addLine(to: CGPoint(x: x + slant + barWidth, y: top))
                        path.addLine(to: CGPoint(x: x + barWidth, y: bottom))
                        path.addLine(to: CGPoint(x: x, y: bottom))
                        path.closeSubpath()
                    }
                    context.fill(bar, with: .color(.white))
                }

                // The measure line that closes every panel in the app.
                let rulerY = size.height * 0.8
                let rulerLeft = size.width * 0.235
                let rulerRight = size.width * 0.765
                var x = rulerLeft
                var tick = 0
                while x <= rulerRight {
                    let tall = tick.isMultiple(of: 3)
                    let line = Path { path in
                        path.move(to: CGPoint(x: x, y: rulerY))
                        path.addLine(to: CGPoint(x: x, y: rulerY - size.height * (tall ? 0.042 : 0.022)))
                    }
                    context.stroke(line, with: .color(.white.opacity(0.55)), lineWidth: size.width * 0.009)
                    x += size.width * 0.038
                    tick += 1
                }
            }
            .padding(canvas * 0.06)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1

    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let master = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else {
        fatalError("could not render icon")
    }

    let iconset = URL(fileURLWithPath: "NetworkMonitor.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let masterURL = iconset.appending(path: "icon_512x512@2x.png")
    try master.write(to: masterURL)

    // iconutil wants every size present under these exact names.
    let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512),
    ]

    for size in sizes {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = [
            "-z", String(size.pixels), String(size.pixels),
            masterURL.path, "--out", iconset.appending(path: "\(size.name).png").path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/NetworkMonitor.icns"]
    try iconutil.run()
    iconutil.waitUntilExit()

    try? FileManager.default.removeItem(at: iconset)
    print("wrote Resources/NetworkMonitor.icns")
}

try MainActor.assumeIsolated { try render() }
