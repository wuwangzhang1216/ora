import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func bitmap(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    draw(gc.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func write(_ rep: NSBitmapImageRep, _ name: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
}

// Original vector mark: a single O-shaped speech aperture and two caption lines.
// These are design previews only; the submitted App Store binary is untouched.
func drawIcon(_ ctx: CGContext, size: CGFloat, dark: Bool) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                      cornerWidth: 194, cornerHeight: 194, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: color(0x062A27, 0.18).cgColor)
    ctx.setFillColor(color(dark ? 0x0A3938 : 0xF3F7F3).cgColor)
    ctx.addPath(tile); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let stops = (dark ? [color(0x17655B).cgColor, color(0x092F34).cgColor]
                      : [color(0xFFFFFF).cgColor, color(0xE9F0EB).cgColor]) as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 280, y: 944), end: CGPoint(x: 720, y: 80),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.setStrokeColor(color(dark ? 0xA4FFE0 : 0xFFFFFF, dark ? 0.12 : 0.85).cgColor)
    ctx.setLineWidth(2); ctx.addPath(tile); ctx.strokePath()

    ctx.saveGState()
    // Draw using top-down coordinates, matching the companion SVG master.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 512, y: 224))
    mark.addCurve(to: CGPoint(x: 224, y: 512), control1: CGPoint(x: 353, y: 224), control2: CGPoint(x: 224, y: 353))
    mark.addCurve(to: CGPoint(x: 512, y: 800), control1: CGPoint(x: 224, y: 671), control2: CGPoint(x: 353, y: 800))
    mark.addCurve(to: CGPoint(x: 677, y: 748), control1: CGPoint(x: 575, y: 800), control2: CGPoint(x: 633, y: 780))
    mark.addLine(to: CGPoint(x: 800, y: 800)); mark.addLine(to: CGPoint(x: 748, y: 677))
    mark.addCurve(to: CGPoint(x: 800, y: 512), control1: CGPoint(x: 780, y: 633), control2: CGPoint(x: 800, y: 575))
    mark.addCurve(to: CGPoint(x: 512, y: 224), control1: CGPoint(x: 800, y: 353), control2: CGPoint(x: 671, y: 224))
    mark.closeSubpath()
    mark.addEllipse(in: CGRect(x: 320, y: 320, width: 384, height: 384))
    ctx.setFillColor(color(dark ? 0xEAFFF5 : 0x105D52).cgColor)
    ctx.addPath(mark); ctx.fillPath(using: .evenOdd)
    ctx.setFillColor(color(dark ? 0x8BE5C7 : 0x105D52).cgColor)
    for rect in [CGRect(x: 402, y: 444, width: 220, height: 44), CGRect(x: 402, y: 536, width: 160, height: 44)] {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
    }
    ctx.restoreGState()
}

for dark in [false, true] {
    try write(bitmap(1024, 1024) { drawIcon($0, size: 1024, dark: dark) }, dark ? "ora-dark-1024.png" : "ora-light-1024.png")
}

func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, ink: UInt32 = 0x152C28) {
    (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(ink)
    ])
}
let old = NSImage(contentsOfFile: root.appendingPathComponent("../../macos/Ora/Resources/AppIcon.icns").standardizedFileURL.path)!
let sheet = bitmap(1600, 1060) { ctx in
    ctx.setFillColor(color(0xF1F3EF).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1060))
    text("Ora", 90, 944, size: 44, weight: .semibold)
    text("一个对话环，两行字幕。", 90, 892, size: 23, ink: 0x687771)
    text("图标设计预览 · 尚未替换已送审版本", 1022, 956, size: 17, ink: 0x73817B)
    let cards: [(CGFloat, String, String, Bool?)] = [
        (70, "当前图标", "同心圆密集，视觉重心偏满", nil),
        (570, "新版 · 浅色", "温润底色，更清楚的 O 形识别", false),
        (1070, "新版 · 深色", "同一符号，保留 Ora 的青绿色", true)
    ]
    for (x, title, note, dark) in cards {
        ctx.setFillColor(color(0xFFFFFF).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 210, width: 460, height: 620), cornerWidth: 30, cornerHeight: 30, transform: nil)); ctx.fillPath()
        text(title, x + 34, 760, size: 23, weight: .semibold)
        text(note, x + 34, 722, size: 17, ink: 0x78847E)
        if let dark = dark {
            ctx.saveGState(); ctx.translateBy(x: x + 90, y: 400); drawIcon(ctx, size: 280, dark: dark); ctx.restoreGState()
        } else {
            old.draw(in: CGRect(x: x + 110, y: 420, width: 240, height: 240))
        }
        for (offset, size) in [(CGFloat(48), CGFloat(64)), (CGFloat(168), CGFloat(32)), (CGFloat(276), CGFloat(16))] {
            if let dark = dark {
                ctx.saveGState(); ctx.translateBy(x: x + offset, y: 310); drawIcon(ctx, size: size, dark: dark); ctx.restoreGState()
            } else { old.draw(in: CGRect(x: x + offset + size * 0.078, y: 310 + size * 0.078, width: size * 0.844, height: size * 0.844)) }
            text("\(Int(size)) px", x + offset, 268, size: 14, ink: 0x87918C)
        }
    }
    text("更少的线条，更清楚的字幕符号。", 90, 125, size: 24, weight: .medium)
    text("减少圆环 · 增加留白 · 检查小尺寸 · 保留可编辑矢量", 90, 84, size: 17, ink: 0x73817B)
}
try write(sheet, "comparison.png")
print(root.appendingPathComponent("comparison.png").path)
