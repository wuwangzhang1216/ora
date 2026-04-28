#!/usr/bin/env swift
// Generates a placeholder AppIcon.icns from an SF Symbol rendered on a
// rounded-rectangle gradient background. Run once; commit the produced
// AppIcon.icns. Replace with a real designed icon later.
//
// Usage: swift Resources/generate-icon.swift

import AppKit
import CoreGraphics
import Foundation

let outputDir = URL(fileURLWithPath: CommandLine.arguments.first!)
    .deletingLastPathComponent()
let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
let icns = outputDir.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Sizes required by iconutil.
let entries: [(size: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

func renderIcon(pixelSize: Int) -> NSImage {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let rect = CGRect(origin: .zero, size: size)

    // Rounded square with a subtle vertical gradient (indigo → purple).
    let corner = CGFloat(pixelSize) * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Teal → deep-blue gradient — visually distinct from the orange system
    // microphone indicator.
    let colors = [
        CGColor(red: 0.15, green: 0.72, blue: 0.82, alpha: 1.0),  // teal
        CGColor(red: 0.10, green: 0.30, blue: 0.72, alpha: 1.0),  // deep blue
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    // Concentric echo rings — radar/sonar motif representing real-time
    // speech translation. Three rings + a filled center dot at large sizes;
    // simplified to one ring + dot when the tile is too small to render
    // thinner strokes cleanly.
    let s = CGFloat(pixelSize)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)

    // Rings specified as (radius fraction, stroke-width fraction).
    // Small-tile fallback keeps strokes thick enough to antialias cleanly.
    let rings: [(Double, Double)]
    let dotR: Double
    if pixelSize >= 128 {
        rings = [(0.40, 0.055), (0.27, 0.045), (0.165, 0.040)]
        dotR = 0.075
    } else if pixelSize >= 48 {
        rings = [(0.40, 0.075), (0.22, 0.060)]
        dotR = 0.10
    } else {
        rings = [(0.38, 0.11)]
        dotR = 0.14
    }

    for (rFrac, wFrac) in rings {
        let r = s * rFrac
        let lw = s * wFrac
        ctx.setLineWidth(lw)
        let rect = CGRect(
            x: center.x - r,
            y: center.y - r,
            width: r * 2,
            height: r * 2
        )
        ctx.strokeEllipse(in: rect)
    }

    let dotRadius = s * dotR
    let dotRect = CGRect(
        x: center.x - dotRadius,
        y: center.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    ctx.fillEllipse(in: dotRect)

    return image
}

for entry in entries {
    let pixels = entry.size * entry.scale
    let image = renderIcon(pixelSize: pixels)
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("failed to render \(entry.name)\n", stderr)
        exit(1)
    }
    let dest = iconset.appendingPathComponent(entry.name)
    try png.write(to: dest)
    print("  wrote \(entry.name) (\(pixels)x\(pixels))")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("✅ \(icns.path)")
    try? FileManager.default.removeItem(at: iconset)
} else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
