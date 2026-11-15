import AppKit
import Foundation

let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let concepts = [("a-fold", "A · 折译", "Fold", "折面交接 · 蓝紫珐琅"),
                ("b-duet", "B · 合声", "Duet", "双向引语 · 暖色陶瓷"),
                ("c-lens", "C · 透镜", "Lens", "光学切面 · 深蓝玻璃")]
func ink(_ n: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(n >> 16 & 255) / 255, green: CGFloat(n >> 8 & 255) / 255,
            blue: CGFloat(n & 255) / 255, alpha: 1)
}
func render(_ width: Int, _ height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ path: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: path)
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, color: UInt32 = 0x21232A) {
    (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink(color)])
}

let previewDir = base.appendingPathComponent(".preview")
try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
let entries = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [NSImage] = []
for (id, _, title, _) in concepts {
    let source = NSImage(contentsOf: base.appendingPathComponent("raw/\(id).png"))!
    images.append(source)
    let set = previewDir.appendingPathComponent("\(id).iconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for (points, scale) in entries {
        let pixels = points * scale
        let rep = render(pixels, pixels) {
            source.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try save(rep, set.appendingPathComponent(name))
    }
    let app = previewDir.appendingPathComponent("Ora \(title) Preview.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    let executable = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", set.path, "-o", resources.appendingPathComponent("Preview.icns").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("iconutil failed: \(id)") }
    let plist: [String: Any] = ["CFBundleIdentifier": "dev.ora.iconstudy.\(id)",
        "CFBundleName": "Ora \(title)", "CFBundleDisplayName": "Ora \(title)",
        "CFBundleExecutable": "IconPreview", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "CFBundleIconFile": "Preview", "NSHighResolutionCapable": true,
        "LSMinimumSystemVersion": "15.0"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
}

try save(render(1800, 1040) {
    ink(0xF4F4F6).setFill(); NSRect(x: 0, y: 0, width: 1800, height: 1040).fill()
    text("Ora", x: 96, y: 916, size: 48, weight: .semibold)
    text("三种形体，三种材质", x: 98, y: 870, size: 24, color: 0x686B76)
    text("ICON STUDIES  /  02", x: 1420, y: 936, size: 17, weight: .medium, color: 0x818490)
    for (i, item) in concepts.enumerated() {
        let x = CGFloat(100 + i * 570)
        images[i].draw(in: CGRect(x: x + 60, y: 450, width: 350, height: 350))
        text(item.1, x: x + 70, y: 380, size: 27, weight: .semibold)
        text(item.3, x: x + 70, y: 340, size: 19, color: 0x767A85)
        for (offset, size) in [(CGFloat(72), CGFloat(64)), (CGFloat(218), CGFloat(32)), (CGFloat(330), CGFloat(16))] {
            images[i].draw(in: CGRect(x: x + offset, y: 205, width: size, height: size))
            text("\(Int(size)) px", x: x + offset, y: 166, size: 14, color: 0x8C9099)
        }
    }
    text("先看轮廓，再看质感。", x: 98, y: 80, size: 20, weight: .medium, color: 0x60646F)
    text("设计预览 · 非最终上架图标", x: 1410, y: 82, size: 16, color: 0x8C9099)
}, base.appendingPathComponent("concepts.png"))
print("Prepared three iconsets, preview app bundles, and concepts.png")
