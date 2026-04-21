#!/usr/bin/env swift
// Renders a set of Product Hunt promo posters for Ora.
//
// Design direction — "Apple product-page" minimalism:
//   • Huge whitespace, SF Pro Display typography, kerned hero text.
//   • Teal → deep-blue brand gradient (same as AppIcon).
//   • Glass / frosted GUI mockup of the Ora caption window, floating
//     above atmospheric color blobs (faked glassmorphism — no live blur).
//   • 5 feature pills calling out the core pitch:
//       Local · Offline · Private · Accurate · Free
//
// Usage: swift docs/posters/generate-posters.swift

import AppKit
import CoreGraphics
import Foundation

// MARK: - Brand tokens

let brandTeal     = NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.82, alpha: 1.0)
let brandDeepBlue = NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.72, alpha: 1.0)
let brandViolet   = NSColor(calibratedRed: 0.55, green: 0.34, blue: 0.88, alpha: 1.0)
let brandWarm     = NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.40, alpha: 1.0)

let nearBlack     = NSColor(calibratedRed: 0.039, green: 0.039, blue: 0.051, alpha: 1.0)
let nearWhite     = NSColor(calibratedRed: 0.980, green: 0.982, blue: 0.988, alpha: 1.0)
let ink           = NSColor(calibratedRed: 0.110, green: 0.115, blue: 0.130, alpha: 1.0)
let muteOnDark    = NSColor(calibratedRed: 0.66, green: 0.68, blue: 0.74, alpha: 1.0)
let muteOnLight   = NSColor(calibratedRed: 0.40, green: 0.42, blue: 0.48, alpha: 1.0)
let dimOnDark     = NSColor(calibratedRed: 0.46, green: 0.49, blue: 0.55, alpha: 1.0)

let pillAccent    = brandTeal

let outputDir = URL(fileURLWithPath: CommandLine.arguments.first!)
    .deletingLastPathComponent()

// MARK: - Image plumbing

func makeImage(size: CGSize, draw: (CGContext, CGSize) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: size.width, height: size.height))
    image.lockFocus()
    defer { image.unlockFocus() }
    if let ctx = NSGraphicsContext.current?.cgContext {
        draw(ctx, size)
    }
    return image
}

/// JPEG quality — 0.88 is the sweet spot for these gradient/glow
/// posters. Below ~0.80 you start to see banding in the atmospheric
/// blobs; above 0.92 file size grows without visible gain.
let JPEG_QUALITY: Float = 0.88

func save(_ image: NSImage, as name: String) {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff)
    else {
        fputs("failed to render \(name)\n", stderr)
        exit(1)
    }

    let dest = outputDir.appendingPathComponent(name)
    let ext = (name as NSString).pathExtension.lowercased()

    let data: Data?
    switch ext {
    case "jpg", "jpeg":
        data = rep.representation(using: .jpeg, properties: [
            .compressionFactor: NSNumber(value: JPEG_QUALITY),
        ])
    default:
        data = rep.representation(using: .png, properties: [:])
    }

    guard let out = data else {
        fputs("encode failed \(name)\n", stderr)
        exit(1)
    }

    do {
        try out.write(to: dest)
        let bytes = out.count
        let mb = Double(bytes) / 1_048_576
        print(String(format: "  wrote %@  (%d×%d, %.2f MB)",
                     name,
                     Int(image.size.width),
                     Int(image.size.height),
                     mb))
    } catch {
        fputs("write failed \(name): \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Low-level drawing helpers

func fillRect(_ ctx: CGContext, color: NSColor, rect: CGRect) {
    ctx.setFillColor(color.cgColor)
    ctx.fill(rect)
}

func drawLinearGradient(
    _ ctx: CGContext,
    colors: [NSColor],
    from: CGPoint,
    to: CGPoint,
    locations: [CGFloat]? = nil
) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let cgColors = colors.map { $0.cgColor } as CFArray
    let locs: [CGFloat] = locations ?? colors.enumerated().map {
        CGFloat($0.offset) / CGFloat(max(1, colors.count - 1))
    }
    if let g = CGGradient(colorsSpace: cs, colors: cgColors, locations: locs) {
        ctx.drawLinearGradient(g, start: from, end: to, options: [])
    }
}

func drawRadialGlow(
    _ ctx: CGContext,
    center: CGPoint,
    radius: CGFloat,
    color: NSColor,
    innerAlpha: CGFloat
) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let inner = color.withAlphaComponent(innerAlpha).cgColor
    let outer = color.withAlphaComponent(0.0).cgColor
    let colors = [inner, outer] as CFArray
    let locs: [CGFloat] = [0.0, 1.0]
    if let g = CGGradient(colorsSpace: cs, colors: colors, locations: locs) {
        ctx.drawRadialGradient(
            g,
            startCenter: center, startRadius: 0,
            endCenter: center,   endRadius: radius,
            options: []
        )
    }
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawShadow(
    _ ctx: CGContext,
    offset: CGSize = CGSize(width: 0, height: -30),
    blur: CGFloat = 80,
    color: NSColor = NSColor.black.withAlphaComponent(0.55),
    block: () -> Void
) {
    ctx.saveGState()
    ctx.setShadow(offset: offset, blur: blur, color: color.cgColor)
    block()
    ctx.restoreGState()
}

// MARK: - Typography

func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

func textSize(_ s: String, font: NSFont, kern: CGFloat = 0) -> CGSize {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .kern: kern,
    ]
    return NSAttributedString(string: s, attributes: attrs).size()
}

/// Draw text with its bounding-box top-left at `topLeft` (AppKit coords).
func drawText(
    _ text: String,
    topLeft: CGPoint,
    font: NSFont,
    color: NSColor,
    kern: CGFloat = 0
) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .kern: kern,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let size = s.size()
    let origin = CGPoint(x: topLeft.x, y: topLeft.y - size.height)
    s.draw(at: origin)
}

/// Draw text horizontally centered on the canvas, with visual top at `topY`.
func drawCenteredTextAtTop(
    _ text: String,
    topY: CGFloat,
    canvasWidth W: CGFloat,
    font: NSFont,
    color: NSColor,
    kern: CGFloat = 0
) {
    let s = textSize(text, font: font, kern: kern)
    drawText(text,
             topLeft: CGPoint(x: (W - s.width) / 2, y: topY),
             font: font, color: color, kern: kern)
}

/// Draw text horizontally centered with its vertical center on `centerY`.
func drawCenteredText(
    _ text: String,
    centerY: CGFloat,
    canvasWidth W: CGFloat,
    font: NSFont,
    color: NSColor,
    kern: CGFloat = 0
) {
    let s = textSize(text, font: font, kern: kern)
    drawText(text,
             topLeft: CGPoint(x: (W - s.width) / 2, y: centerY + s.height / 2),
             font: font, color: color, kern: kern)
}

/// Draw centered, horizontally-aligned text with a strikethrough — used
/// on "wrong / literal" translations to visually rule them out.
@discardableResult
func drawCenteredStrikethrough(
    _ text: String,
    topY: CGFloat,
    canvasWidth W: CGFloat,
    font: NSFont,
    color: NSColor,
    strikeColor: NSColor? = nil,
    kern: CGFloat = 0
) -> CGSize {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .strikethroughStyle: NSUnderlineStyle.thick.rawValue,
        .strikethroughColor: strikeColor ?? color,
        .kern: kern,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let size = s.size()
    let origin = CGPoint(x: (W - size.width) / 2, y: topY - size.height)
    s.draw(at: origin)
    return size
}

/// Draw centered text and return the drawn size (handy for flowing
/// typographic stacks where each line has a different font).
@discardableResult
func drawCenteredLine(
    _ text: String,
    topY: CGFloat,
    canvasWidth W: CGFloat,
    font: NSFont,
    color: NSColor,
    kern: CGFloat = 0
) -> CGSize {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .kern: kern,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let size = s.size()
    let origin = CGPoint(x: (W - size.width) / 2, y: topY - size.height)
    s.draw(at: origin)
    return size
}

// MARK: - SF Symbol glyph

/// Draws an SF Symbol tinted to a given color, centered at `center`,
/// with optional soft glow underneath (for luminous accents on dark bg).
func drawSymbol(
    _ ctx: CGContext,
    name: String,
    center: CGPoint,
    pointSize: CGFloat,
    weight: NSFont.Weight = .medium,
    color: NSColor,
    glow: Bool = false,
    glowColor: NSColor? = nil,
    glowAlpha: CGFloat = 0.45
) {
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return
    }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let styled = sym.withSymbolConfiguration(cfg) else { return }

    if glow {
        drawRadialGlow(ctx,
                       center: center,
                       radius: pointSize * 2.4,
                       color: glowColor ?? color,
                       innerAlpha: glowAlpha)
    }

    // Tint by drawing the symbol as an alpha mask and filling with color.
    let size = styled.size
    let tinted = NSImage(size: size)
    tinted.lockFocus()
    styled.draw(in: CGRect(origin: .zero, size: size))
    color.set()
    NSBezierPath.fill(CGRect(origin: .zero, size: size), using: .sourceIn)
    tinted.unlockFocus()

    let rect = CGRect(
        x: center.x - size.width / 2,
        y: center.y - size.height / 2,
        width: size.width,
        height: size.height
    )
    tinted.draw(in: rect)
}

// NSBezierPath doesn't have a static fill(using:) — use an extension.
extension NSBezierPath {
    static func fill(_ rect: CGRect, using op: NSCompositingOperation) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.compositingOperation = op
        NSBezierPath(rect: rect).fill()
        ctx.restoreGraphicsState()
    }
}

// MARK: - Echo rings (app icon mark)

/// Three concentric rings + center dot in the brand gradient (or a
/// solid color override), centered at `center` with overall `diameter`.
func drawEchoRings(
    _ ctx: CGContext,
    center: CGPoint,
    diameter: CGFloat,
    solidFill: NSColor? = nil
) {
    let w = diameter * 1.05
    let h = diameter * 1.05
    let box = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)

    ctx.saveGState()
    ctx.translateBy(x: box.origin.x, y: box.origin.y)

    // Alpha-mask: white shapes on transparent background.
    let mask = NSImage(size: NSSize(width: w, height: h))
    mask.lockFocus()
    if let mctx = NSGraphicsContext.current?.cgContext {
        mctx.setStrokeColor(NSColor.white.cgColor)
        mctx.setFillColor(NSColor.white.cgColor)
        mctx.setLineCap(.round)
        let p = CGPoint(x: w / 2, y: h / 2)
        let rings: [(CGFloat, CGFloat)] = [
            (0.40, 0.055), (0.27, 0.045), (0.165, 0.040),
        ]
        for (rFrac, wFrac) in rings {
            let r = diameter * rFrac
            mctx.setLineWidth(diameter * wFrac)
            mctx.strokeEllipse(in: CGRect(
                x: p.x - r, y: p.y - r, width: r * 2, height: r * 2
            ))
        }
        let dotR = diameter * 0.075
        mctx.fillEllipse(in: CGRect(
            x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2
        ))
    }
    mask.unlockFocus()

    if let tiff = mask.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let cg = rep.cgImage {
        ctx.clip(to: CGRect(origin: .zero, size: box.size), mask: cg)
        if let solid = solidFill {
            ctx.setFillColor(solid.cgColor)
            ctx.fill(CGRect(origin: .zero, size: box.size))
        } else {
            drawLinearGradient(
                ctx,
                colors: [brandTeal, brandDeepBlue],
                from: CGPoint(x: w / 2, y: h),
                to:   CGPoint(x: w / 2, y: 0)
            )
        }
    }
    ctx.restoreGState()
}

// MARK: - Background atmosphere

enum Scheme { case dark, light }

func drawAtmosphericBackdrop(_ ctx: CGContext, size: CGSize, scheme: Scheme) {
    switch scheme {
    case .dark:
        // Same blue brand gradient as say-it.jpg: deep-blue floor → teal sky.
        drawLinearGradient(
            ctx,
            colors: [
                NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.30, alpha: 1),
                brandDeepBlue,
                brandTeal,
            ],
            from: CGPoint(x: 0, y: 0),
            to:   CGPoint(x: 0, y: size.height),
            locations: [0.0, 0.55, 1.0]
        )
        // Subtle diagonal atmosphere — violet bottom-left, warm top-right.
        drawRadialGlow(ctx, center: CGPoint(x: size.width * 0.22, y: size.height * 0.75),
                       radius: size.width * 0.45, color: brandViolet, innerAlpha: 0.22)
        drawRadialGlow(ctx, center: CGPoint(x: size.width * 0.85, y: size.height * 0.28),
                       radius: size.width * 0.35, color: brandWarm, innerAlpha: 0.14)
    case .light:
        fillRect(ctx, color: nearWhite, rect: CGRect(origin: .zero, size: size))
        drawRadialGlow(ctx, center: CGPoint(x: size.width * 0.18, y: size.height * 0.85),
                       radius: size.width * 0.60, color: brandTeal, innerAlpha: 0.14)
        drawRadialGlow(ctx, center: CGPoint(x: size.width * 0.82, y: size.height * 0.25),
                       radius: size.width * 0.55, color: brandDeepBlue, innerAlpha: 0.12)
        drawRadialGlow(ctx, center: CGPoint(x: size.width * 0.90, y: size.height * 0.90),
                       radius: size.width * 0.40, color: brandWarm, innerAlpha: 0.10)
    }
}

// MARK: - Glass card

/// Renders a frosted-glass rounded rectangle with soft shadow, body
/// tint, top highlight, and a thin 1px border. Works on dark or light
/// backdrops via `scheme`.
func drawGlassCard(
    _ ctx: CGContext,
    rect: CGRect,
    cornerRadius r: CGFloat,
    scheme: Scheme
) {
    let path = roundedRectPath(rect, radius: r)

    // Drop shadow.
    drawShadow(ctx,
               offset: CGSize(width: 0, height: -24),
               blur: 110,
               color: NSColor.black.withAlphaComponent(scheme == .dark ? 0.75 : 0.35)) {
        ctx.saveGState()
        ctx.addPath(path)
        let baseColor: NSColor = scheme == .dark
            ? NSColor(calibratedWhite: 0.07, alpha: 0.78)
            : NSColor(calibratedWhite: 1.00, alpha: 0.72)
        ctx.setFillColor(baseColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Inner vertical gradient wash (subtle top-to-bottom darker — adds depth).
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let washTop: NSColor = scheme == .dark
        ? NSColor(calibratedWhite: 1.0, alpha: 0.06)
        : NSColor(calibratedWhite: 1.0, alpha: 0.45)
    let washBot: NSColor = scheme == .dark
        ? NSColor(calibratedWhite: 1.0, alpha: 0.00)
        : NSColor(calibratedWhite: 1.0, alpha: 0.00)
    drawLinearGradient(ctx,
                       colors: [washTop, washBot],
                       from: CGPoint(x: rect.midX, y: rect.maxY),
                       to:   CGPoint(x: rect.midX, y: rect.midY))
    ctx.restoreGState()

    // Top inner highlight strip — mimics a specular edge on glass.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let hl = CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)
    let hlColor: NSColor = scheme == .dark
        ? NSColor.white.withAlphaComponent(0.28)
        : NSColor.white.withAlphaComponent(0.85)
    ctx.setFillColor(hlColor.cgColor)
    ctx.fill(hl)
    ctx.restoreGState()

    // Border.
    ctx.addPath(path)
    let borderColor: NSColor = scheme == .dark
        ? NSColor.white.withAlphaComponent(0.10)
        : NSColor.black.withAlphaComponent(0.08)
    ctx.setStrokeColor(borderColor.cgColor)
    ctx.setLineWidth(1.5)
    ctx.strokePath()
}

// MARK: - Caption-window mockup (the "GUI 示意图")

/// Renders a faithful-enough mockup of Ora's floating caption card —
/// source text on top, translation below, listening indicator and a
/// target-language chip in the header, a thin VAD bar at the bottom.
func drawCaptionMockup(
    _ ctx: CGContext,
    rect: CGRect,
    scheme: Scheme,
    sourceText: String,
    translationText: String,
    targetLang: String
) {
    let radius: CGFloat = 36
    drawGlassCard(ctx, rect: rect, cornerRadius: radius, scheme: scheme)

    let insetX: CGFloat = 72
    let insetTop: CGFloat = 64
    let headerH: CGFloat = 68

    let inkColor: NSColor = scheme == .dark ? .white : ink
    let muteColor: NSColor = scheme == .dark ? muteOnDark : muteOnLight

    // ── Header ────────────────────────────────────────────────
    // "Listening" indicator: pulsing-green dot + label.
    let headerTopY = rect.maxY - insetTop
    let dotR: CGFloat = 12
    let dotCenter = CGPoint(x: rect.minX + insetX + dotR, y: headerTopY - dotR * 1.0)
    // Soft glow.
    drawRadialGlow(ctx,
                   center: dotCenter,
                   radius: dotR * 4,
                   color: NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.50, alpha: 1),
                   innerAlpha: 0.35)
    ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.50, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR,
                               width: dotR * 2, height: dotR * 2))
    drawText("Listening",
             topLeft: CGPoint(x: dotCenter.x + dotR + 18, y: headerTopY + 4),
             font: font(28, weight: .medium),
             color: muteColor,
             kern: 0.4)

    // Target-language chip (top-right).
    let chipText = targetLang.uppercased()
    let chipFont = font(26, weight: .semibold)
    let chipPad: CGFloat = 26
    let chipH: CGFloat = 56
    let chipTextSize = textSize(chipText, font: chipFont, kern: 1.6)
    let chipW = chipTextSize.width + chipPad * 2
    let chipRect = CGRect(x: rect.maxX - insetX - chipW,
                          y: headerTopY - chipH + 10,
                          width: chipW, height: chipH)
    let chipPath = roundedRectPath(chipRect, radius: chipH / 2)
    ctx.addPath(chipPath)
    let chipFill: NSColor = scheme == .dark
        ? NSColor.white.withAlphaComponent(0.10)
        : NSColor.black.withAlphaComponent(0.05)
    ctx.setFillColor(chipFill.cgColor)
    ctx.fillPath()
    ctx.addPath(chipPath)
    let chipBorder: NSColor = scheme == .dark
        ? NSColor.white.withAlphaComponent(0.16)
        : NSColor.black.withAlphaComponent(0.10)
    ctx.setStrokeColor(chipBorder.cgColor)
    ctx.setLineWidth(1.3)
    ctx.strokePath()
    let chipTextOrigin = CGPoint(
        x: chipRect.minX + chipPad,
        y: chipRect.midY + chipTextSize.height / 2
    )
    drawText(chipText,
             topLeft: chipTextOrigin,
             font: chipFont, color: muteColor, kern: 1.6)

    // ── Source text ───────────────────────────────────────────
    let contentLeft = rect.minX + insetX
    let contentRight = rect.maxX - insetX
    let sourceTop = headerTopY - headerH
    let sourceFont = font(38, weight: .regular)
    drawWrappedText(
        sourceText,
        in: CGRect(x: contentLeft, y: rect.minY + 160,
                   width: contentRight - contentLeft,
                   height: sourceTop - rect.minY - 160),
        font: sourceFont,
        color: muteColor,
        lineHeightMultiple: 1.25,
        anchor: .topLeft
    )

    // ── Translation ───────────────────────────────────────────
    // The translation is the visual star — larger, bolder, full-ink.
    let transFont = font(62, weight: .semibold)
    let transTop = sourceTop - 110
    drawWrappedText(
        translationText,
        in: CGRect(x: contentLeft, y: rect.minY + 160,
                   width: contentRight - contentLeft,
                   height: transTop - (rect.minY + 160)),
        font: transFont,
        color: inkColor,
        lineHeightMultiple: 1.15,
        anchor: .topLeft
    )

    // ── VAD meter (decorative bars at the bottom) ─────────────
    drawVADMeter(ctx,
                 at: CGPoint(x: contentLeft, y: rect.minY + 78),
                 width: 180,
                 scheme: scheme)
}

/// Wrap + draw text inside a rectangle with a given anchor.
enum TextAnchor { case topLeft }

func drawWrappedText(
    _ text: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor,
    lineHeightMultiple: CGFloat = 1.2,
    anchor: TextAnchor = .topLeft
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = lineHeightMultiple
    paragraph.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let bounding = s.boundingRect(
        with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    // For topLeft anchor, draw with the top of bounding aligned to rect.maxY.
    let origin = CGPoint(x: rect.minX, y: rect.maxY - bounding.height)
    s.draw(in: CGRect(origin: origin,
                      size: CGSize(width: rect.width, height: bounding.height)))
}

/// Compact caption mockup for feature grids — smaller padding, smaller
/// type scale, no VAD bar. Same visual language as the full mockup.
func drawMiniCaptionMockup(
    _ ctx: CGContext,
    rect: CGRect,
    scheme: Scheme,
    sourceText: String,
    translationText: String,
    targetLang: String
) {
    let radius: CGFloat = 28
    drawGlassCard(ctx, rect: rect, cornerRadius: radius, scheme: scheme)

    let pad: CGFloat = 44
    let headerH: CGFloat = 52

    let inkColor: NSColor = scheme == .dark ? .white : ink
    let muteColor: NSColor = scheme == .dark ? muteOnDark : muteOnLight

    // ── Header
    let headerTopY = rect.maxY - pad
    let dotR: CGFloat = 9
    let dotCenter = CGPoint(x: rect.minX + pad + dotR, y: headerTopY - dotR)
    drawRadialGlow(ctx, center: dotCenter, radius: dotR * 4,
                   color: NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.50, alpha: 1),
                   innerAlpha: 0.32)
    ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.50, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR,
                               width: dotR * 2, height: dotR * 2))
    drawText("Listening",
             topLeft: CGPoint(x: dotCenter.x + dotR + 12, y: headerTopY + 4),
             font: font(20, weight: .medium),
             color: muteColor, kern: 0.3)

    // Target-language chip.
    let chipFont = font(18, weight: .semibold)
    let chipPad: CGFloat = 16
    let chipH: CGFloat = 40
    let chipTextSz = textSize(targetLang.uppercased(), font: chipFont, kern: 1.2)
    let chipW = chipTextSz.width + chipPad * 2
    let chipRect = CGRect(x: rect.maxX - pad - chipW,
                          y: headerTopY - chipH + 8,
                          width: chipW, height: chipH)
    let chipPath = roundedRectPath(chipRect, radius: chipH / 2)
    ctx.addPath(chipPath)
    ctx.setFillColor((scheme == .dark
        ? NSColor.white.withAlphaComponent(0.10)
        : NSColor.black.withAlphaComponent(0.05)).cgColor)
    ctx.fillPath()
    ctx.addPath(chipPath)
    ctx.setStrokeColor((scheme == .dark
        ? NSColor.white.withAlphaComponent(0.16)
        : NSColor.black.withAlphaComponent(0.10)).cgColor)
    ctx.setLineWidth(1.2)
    ctx.strokePath()
    drawText(targetLang.uppercased(),
             topLeft: CGPoint(x: chipRect.minX + chipPad,
                              y: chipRect.midY + chipTextSz.height / 2),
             font: chipFont, color: muteColor, kern: 1.2)

    // ── Body: source (muted) on top visually, translation (ink) below.
    let contentLeft = rect.minX + pad
    let contentRight = rect.maxX - pad
    let sourceTop = headerTopY - headerH
    let transTop = sourceTop - 60
    let sourceFont = font(26, weight: .regular)
    let transFont = font(46, weight: .semibold)

    drawWrappedText(sourceText,
                    in: CGRect(x: contentLeft, y: rect.minY + pad,
                               width: contentRight - contentLeft,
                               height: sourceTop - (rect.minY + pad)),
                    font: sourceFont, color: muteColor,
                    lineHeightMultiple: 1.25)

    drawWrappedText(translationText,
                    in: CGRect(x: contentLeft, y: rect.minY + pad,
                               width: contentRight - contentLeft,
                               height: transTop - (rect.minY + pad)),
                    font: transFont, color: inkColor,
                    lineHeightMultiple: 1.15)

    // ── VAD waveform (bottom-left) — matches the hero caption card.
    drawVADMeter(ctx,
                 at: CGPoint(x: contentLeft, y: rect.minY + pad + 2),
                 width: 120,
                 scheme: scheme)
}

/// Decorative VAD meter — 16 bars of varying height, teal, glassmorphic.
func drawVADMeter(_ ctx: CGContext, at origin: CGPoint, width: CGFloat, scheme: Scheme) {
    let barCount = 18
    let totalSpacing = width
    let barW: CGFloat = 6
    let gap: CGFloat = (totalSpacing - barW * CGFloat(barCount)) / CGFloat(barCount - 1)
    // Pseudo-waveform heights.
    let heights: [CGFloat] = [
        0.30, 0.55, 0.70, 0.45, 0.80, 0.95, 0.75, 0.60, 0.85,
        1.00, 0.82, 0.55, 0.42, 0.60, 0.75, 0.48, 0.30, 0.20,
    ]
    let maxH: CGFloat = 44
    for i in 0..<barCount {
        let h = heights[i] * maxH
        let x = origin.x + CGFloat(i) * (barW + gap)
        let y = origin.y
        let r = CGRect(x: x, y: y, width: barW, height: h)
        let path = roundedRectPath(r, radius: barW / 2)
        ctx.addPath(path)
        let color: NSColor = scheme == .dark
            ? brandTeal.withAlphaComponent(0.85)
            : brandDeepBlue.withAlphaComponent(0.75)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
}

// MARK: - Feature pills

struct FeaturePill {
    let label: String
    let accent: NSColor
}

let coreFeatures: [FeaturePill] = [
    FeaturePill(label: "Local",    accent: brandTeal),
    FeaturePill(label: "Offline",  accent: NSColor(calibratedRed: 0.50, green: 0.75, blue: 1.00, alpha: 1)),
    FeaturePill(label: "Private",  accent: brandViolet),
    FeaturePill(label: "Accurate", accent: brandWarm),
    FeaturePill(label: "Free",     accent: NSColor(calibratedRed: 0.43, green: 0.90, blue: 0.70, alpha: 1)),
]

/// Draws a single pill and returns its total width (so the caller can
/// lay out a row).
@discardableResult
func drawFeaturePill(
    _ ctx: CGContext,
    at origin: CGPoint,
    pill: FeaturePill,
    scheme: Scheme,
    fontSize: CGFloat = 30
) -> CGFloat {
    let pillH: CGFloat = fontSize * 2.15
    let padX: CGFloat = fontSize * 1.1
    let dotR: CGFloat = fontSize * 0.28
    let labelFont = font(fontSize, weight: .medium)
    let labelSize = textSize(pill.label, font: labelFont, kern: 0.4)
    let pillW = padX + dotR * 2 + 16 + labelSize.width + padX
    let rect = CGRect(x: origin.x, y: origin.y, width: pillW, height: pillH)
    let path = roundedRectPath(rect, radius: pillH / 2)

    // Fill
    ctx.addPath(path)
    let fill: NSColor = scheme == .dark
        ? NSColor.white.withAlphaComponent(0.06)
        : NSColor.black.withAlphaComponent(0.035)
    ctx.setFillColor(fill.cgColor)
    ctx.fillPath()

    // Border
    ctx.addPath(path)
    let border: NSColor = scheme == .dark
        ? NSColor.white.withAlphaComponent(0.14)
        : NSColor.black.withAlphaComponent(0.10)
    ctx.setStrokeColor(border.cgColor)
    ctx.setLineWidth(1.5)
    ctx.strokePath()

    // Dot
    let dotCenter = CGPoint(x: rect.minX + padX + dotR, y: rect.midY)
    ctx.setFillColor(pill.accent.cgColor)
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR,
                               width: dotR * 2, height: dotR * 2))

    // Label
    let labelColor: NSColor = scheme == .dark ? .white : ink
    let labelOrigin = CGPoint(
        x: dotCenter.x + dotR + 16,
        y: rect.midY + labelSize.height / 2
    )
    drawText(pill.label,
             topLeft: labelOrigin,
             font: labelFont, color: labelColor, kern: 0.4)

    return pillW
}

/// Lay out a row of pills centered horizontally with `gap` between them.
func drawFeaturePillRow(
    _ ctx: CGContext,
    pills: [FeaturePill],
    centerX: CGFloat,
    bottomY: CGFloat,
    scheme: Scheme,
    fontSize: CGFloat = 30,
    gap: CGFloat = 28
) {
    // First pass: measure widths.
    let pillH: CGFloat = fontSize * 2.15
    let padX: CGFloat = fontSize * 1.1
    let dotR: CGFloat = fontSize * 0.28
    let labelFont = font(fontSize, weight: .medium)
    let widths: [CGFloat] = pills.map { p in
        let l = textSize(p.label, font: labelFont, kern: 0.4).width
        return padX + dotR * 2 + 16 + l + padX
    }
    let totalW = widths.reduce(0, +) + gap * CGFloat(pills.count - 1)
    var cursorX = centerX - totalW / 2
    _ = pillH
    for (i, p) in pills.enumerated() {
        drawFeaturePill(ctx,
                        at: CGPoint(x: cursorX, y: bottomY),
                        pill: p,
                        scheme: scheme,
                        fontSize: fontSize)
        cursorX += widths[i] + gap
    }
}

// MARK: - Wordmark combo (icon + "Ora" inline)

func drawWordmarkInline(
    _ ctx: CGContext,
    centerX: CGFloat,
    centerY: CGFloat,
    iconDiameter: CGFloat,
    textSize ts: CGFloat,
    scheme: Scheme,
    iconFill: NSColor? = nil
) {
    let iconWordGap: CGFloat = iconDiameter * 0.22
    let textFont = font(ts, weight: .bold)
    let textW = textSize("Ora", font: textFont, kern: -1.5).width
    let totalW = iconDiameter + iconWordGap + textW
    let iconCenter = CGPoint(x: centerX - totalW / 2 + iconDiameter / 2, y: centerY)
    // On the unified blue backdrop the teal→blue gradient echo-ring blends in —
    // default to pure white on dark schemes so the mark matches the wordmark text.
    let resolvedIconFill = iconFill ?? (scheme == .dark ? NSColor.white : nil)
    drawEchoRings(ctx, center: iconCenter, diameter: iconDiameter, solidFill: resolvedIconFill)
    let textOrigin = CGPoint(
        x: iconCenter.x + iconDiameter / 2 + iconWordGap,
        y: centerY + textSize("Ora", font: textFont, kern: -1.5).height / 2
    )
    drawText("Ora",
             topLeft: textOrigin,
             font: textFont,
             color: scheme == .dark ? .white : ink,
             kern: -1.5)
}

// MARK: ─────────────────────────────────────────────────────
// MARK: POSTERS
// MARK: ─────────────────────────────────────────────────────

let DEMO_SOURCE      = "今天的产品发布会非常精彩，感谢大家的支持。"
let DEMO_TRANSLATION = "Today's product launch was fantastic — thank you all for the support."
let DEMO_LANG        = "EN"

/// 1) hero-mockup-dark.png — just wordmark, mockup, pills. Nothing else.
func renderHeroMockupDark() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Small wordmark up top (compact — the mockup is the hero).
        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 200,
                           iconDiameter: 96, textSize: 88,
                           scheme: .dark)

        // Caption mockup, elevated, center.
        let cardW: CGFloat = 1720
        let cardH: CGFloat = 640
        let cardRect = CGRect(
            x: (W - cardW) / 2,
            y: 480,
            width: cardW, height: cardH
        )
        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .dark,
                          sourceText: DEMO_SOURCE,
                          translationText: DEMO_TRANSLATION,
                          targetLang: DEMO_LANG)

        // Feature pills row — bottom.
        drawFeaturePillRow(ctx,
                           pills: coreFeatures,
                           centerX: W / 2,
                           bottomY: 260,
                           scheme: .dark,
                           fontSize: 36,
                           gap: 36)
    }
}

/// 2) hero-mockup-light.png — light variant.
func renderHeroMockupLight() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .light)

        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 200,
                           iconDiameter: 96, textSize: 88,
                           scheme: .light)

        let cardW: CGFloat = 1720
        let cardH: CGFloat = 640
        let cardRect = CGRect(
            x: (W - cardW) / 2,
            y: 480,
            width: cardW, height: cardH
        )
        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .light,
                          sourceText: DEMO_SOURCE,
                          translationText: DEMO_TRANSLATION,
                          targetLang: DEMO_LANG)

        drawFeaturePillRow(ctx,
                           pills: coreFeatures,
                           centerX: W / 2,
                           bottomY: 260,
                           scheme: .light,
                           fontSize: 36,
                           gap: 36)
    }
}

/// 3) say-it.png — big split layout: headline on the left, tilted mockup
///    on the right, atop a soft brand gradient.
func renderSayIt() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        // Bottom-heavy brand gradient.
        drawLinearGradient(
            ctx,
            colors: [
                NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.30, alpha: 1),  // near-black blue
                brandDeepBlue,
                brandTeal,
            ],
            from: CGPoint(x: 0, y: 0),
            to:   CGPoint(x: 0, y: H),
            locations: [0.0, 0.55, 1.0]
        )

        // Extra atmosphere.
        drawRadialGlow(ctx, center: CGPoint(x: W * 0.22, y: H * 0.75),
                       radius: W * 0.45, color: brandViolet, innerAlpha: 0.25)
        drawRadialGlow(ctx, center: CGPoint(x: W * 0.85, y: H * 0.28),
                       radius: W * 0.35, color: brandWarm, innerAlpha: 0.18)

        // LEFT COLUMN — headline only. No sub-text, no pills.
        let leftX: CGFloat = 200
        drawText(
            "Say it.",
            topLeft: CGPoint(x: leftX, y: H - 440),
            font: font(220, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.82),
            kern: -5
        )
        drawText(
            "See it",
            topLeft: CGPoint(x: leftX, y: H - 690),
            font: font(220, weight: .bold),
            color: .white,
            kern: -5
        )
        drawText(
            "translated.",
            topLeft: CGPoint(x: leftX, y: H - 940),
            font: font(220, weight: .bold),
            color: .white,
            kern: -5
        )

        // Small wordmark bottom-left.
        drawWordmarkInline(ctx,
                           centerX: leftX + 120, centerY: 220,
                           iconDiameter: 78, textSize: 72,
                           scheme: .dark,
                           iconFill: .white)

        // RIGHT COLUMN — tilted glass mockup.
        let cardW: CGFloat = 1060
        let cardH: CGFloat = 560
        let cardCenter = CGPoint(x: W - 680, y: H / 2 + 40)
        let cardRect = CGRect(
            x: cardCenter.x - cardW / 2,
            y: cardCenter.y - cardH / 2,
            width: cardW, height: cardH
        )

        ctx.saveGState()
        ctx.translateBy(x: cardCenter.x, y: cardCenter.y)
        ctx.rotate(by: -4.5 * .pi / 180)  // slight tilt
        ctx.translateBy(x: -cardCenter.x, y: -cardCenter.y)

        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .dark,
                          sourceText: "今天天气真好，一起去公园散步吧。",
                          translationText: "It's such a lovely day — let's go for a walk in the park.",
                          targetLang: "EN")
        ctx.restoreGState()
    }
}

/// 4) languages.png — multilingual proof-by-typography. No caption
///    cards; instead a typographic stack of "hello" in ten native scripts.
///    Shows the range of supported languages viscerally — the scripts
///    themselves do the talking.
func renderLanguages() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Small wordmark top-center.
        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 110,
                           iconDiameter: 58, textSize: 54,
                           scheme: .dark)

        // Eyebrow headline — muted, sits above the typographic stack.
        drawCenteredTextAtTop(
            "Every language.",
            topY: H - 220,
            canvasWidth: W,
            font: font(64, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.72),
            kern: -1.0
        )

        // "Hello" in ten native scripts, each drawn at its own size and
        // weight to create a typographic rhythm.  Order is curated for
        // visual flow (big → medium → big → medium …), not alphabetical.
        struct Word {
            let text: String
            let size: CGFloat
            let weight: NSFont.Weight
            let alpha: CGFloat
        }
        let words: [Word] = [
            Word(text: "你好",       size: 124, weight: .bold,     alpha: 1.00),
            Word(text: "Bonjour",   size: 104, weight: .semibold, alpha: 0.94),
            Word(text: "こんにちは",  size:  86, weight: .regular,  alpha: 0.82),
            Word(text: "Hola",      size:  96, weight: .medium,   alpha: 0.90),
            Word(text: "नमस्ते",     size: 104, weight: .semibold, alpha: 0.96),
            Word(text: "안녕하세요",  size:  76, weight: .regular,  alpha: 0.78),
            Word(text: "Guten Tag", size:  82, weight: .medium,   alpha: 0.84),
            Word(text: "مرحبا",      size: 122, weight: .bold,     alpha: 1.00),
            Word(text: "Привет",    size:  90, weight: .regular,  alpha: 0.82),
            Word(text: "Olá",       size:  64, weight: .regular,  alpha: 0.62),
        ]

        let lineGap: CGFloat = 10

        // Measure each line first so we can vertically center the stack.
        let measured: [(word: Word, height: CGFloat)] = words.map {
            let h = textSize($0.text,
                             font: font($0.size, weight: $0.weight),
                             kern: -1.0).height
            return ($0, h)
        }
        let totalH = measured.reduce(0) { $0 + $1.height }
            + CGFloat(measured.count - 1) * lineGap

        let topBound: CGFloat = H - 320   // below eyebrow headline
        let bottomBound: CGFloat = 120     // bottom margin
        let availableH = topBound - bottomBound
        let startY: CGFloat = topBound - max(0, (availableH - totalH) / 2)

        var cursorTop = startY
        for (w, h) in measured {
            drawCenteredLine(w.text,
                             topY: cursorTop,
                             canvasWidth: W,
                             font: font(w.size, weight: w.weight),
                             color: NSColor.white.withAlphaComponent(w.alpha),
                             kern: -1.0)
            cursorTop -= (h + lineGap)
        }
    }
}

/// 5) square.png — 1:1 for PH thumbnail / social. Wordmark, mockup, pills.
func renderSquare() -> NSImage {
    let S: CGFloat = 2160
    return makeImage(size: CGSize(width: S, height: S)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: S, height: S), scheme: .dark)

        // Wordmark top.
        drawWordmarkInline(ctx,
                           centerX: S / 2, centerY: S - 240,
                           iconDiameter: 130, textSize: 120,
                           scheme: .dark)

        // Mockup centered.
        let cardW: CGFloat = 1780
        let cardH: CGFloat = 700
        let rect = CGRect(x: (S - cardW) / 2, y: S / 2 - cardH / 2 + 20,
                          width: cardW, height: cardH)
        drawCaptionMockup(ctx,
                          rect: rect,
                          scheme: .dark,
                          sourceText: DEMO_SOURCE,
                          translationText: DEMO_TRANSLATION,
                          targetLang: DEMO_LANG)

        // Pills bottom.
        drawFeaturePillRow(ctx,
                           pills: coreFeatures,
                           centerX: S / 2,
                           bottomY: 260,
                           scheme: .dark,
                           fontSize: 38,
                           gap: 32)
    }
}

// MARK: - Feature posters (one per pillar)

/// local.png — "Runs on your Mac."  Split: headline + laptop glyph left,
/// mockup right.
func renderLocal() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Small wordmark top-left.
        drawWordmarkInline(ctx,
                           centerX: 240, centerY: H - 120,
                           iconDiameter: 60, textSize: 56,
                           scheme: .dark)

        // LEFT — headline + glyph.
        let leftX: CGFloat = 200
        drawText("Runs on",
                 topLeft: CGPoint(x: leftX, y: H - 440),
                 font: font(180, weight: .bold),
                 color: .white, kern: -4)
        drawText("your Mac.",
                 topLeft: CGPoint(x: leftX, y: H - 640),
                 font: font(180, weight: .bold),
                 color: .white, kern: -4)

        // Symbol glyph beneath the text — Metal GPU on Apple Silicon.
        drawSymbol(ctx,
                   name: "cpu.fill",
                   center: CGPoint(x: leftX + 110, y: 430),
                   pointSize: 170,
                   weight: .medium,
                   color: brandTeal,
                   glow: true,
                   glowAlpha: 0.55)
        drawText("Apple Silicon  ·  Metal GPU",
                 topLeft: CGPoint(x: leftX + 220, y: 450),
                 font: font(28, weight: .medium),
                 color: muteOnDark, kern: 3.5)

        // RIGHT — mockup.
        let cardW: CGFloat = 1080
        let cardH: CGFloat = 580
        let cardRect = CGRect(x: W - cardW - 140,
                              y: (H - cardH) / 2,
                              width: cardW, height: cardH)
        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .dark,
                          sourceText: "今天的产品发布会非常精彩。",
                          translationText: "Today's product launch was fantastic.",
                          targetLang: "EN")
    }
}

/// offline.png — "No internet. No problem."  Mockup center with a
/// prominent wifi-slash accent.
func renderOffline() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Wordmark top-center.
        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 140,
                           iconDiameter: 76, textSize: 70,
                           scheme: .dark)

        // Headline — centered, two lines.
        drawCenteredTextAtTop("No internet.",
                              topY: H - 290,
                              canvasWidth: W,
                              font: font(140, weight: .semibold),
                              color: NSColor.white.withAlphaComponent(0.85),
                              kern: -3)
        drawCenteredTextAtTop("No problem.",
                              topY: H - 450,
                              canvasWidth: W,
                              font: font(140, weight: .bold),
                              color: .white,
                              kern: -3)

        // Glyph + mockup composed as a horizontal pair, centered.
        let glyphSize: CGFloat = 260
        let cardW: CGFloat = 1240
        let cardH: CGFloat = 520
        let pairGap: CGFloat = 120
        let pairW = glyphSize + pairGap + cardW
        let pairStartX = (W - pairW) / 2

        let glyphCenter = CGPoint(
            x: pairStartX + glyphSize / 2,
            y: 480
        )
        drawSymbol(ctx,
                   name: "wifi.slash",
                   center: glyphCenter,
                   pointSize: glyphSize,
                   weight: .medium,
                   color: NSColor(calibratedRed: 0.50, green: 0.75, blue: 1.00, alpha: 1),
                   glow: true,
                   glowAlpha: 0.45)

        let cardRect = CGRect(
            x: pairStartX + glyphSize + pairGap,
            y: 480 - cardH / 2,
            width: cardW, height: cardH
        )
        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .dark,
                          sourceText: "下一班列车三分钟后到达。",
                          translationText: "The next train arrives in three minutes.",
                          targetLang: "EN")
    }
}

/// private.png — "Never leaves your Mac."  Split mirror of local.
func renderPrivate() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Small wordmark top-right.
        drawWordmarkInline(ctx,
                           centerX: W - 240, centerY: H - 120,
                           iconDiameter: 60, textSize: 56,
                           scheme: .dark)

        // RIGHT — headline + shield glyph.
        let rightBlockX: CGFloat = W - 200 - 900
        drawText("Never",
                 topLeft: CGPoint(x: rightBlockX, y: H - 440),
                 font: font(180, weight: .bold),
                 color: NSColor.white.withAlphaComponent(0.85), kern: -4)
        drawText("leaves",
                 topLeft: CGPoint(x: rightBlockX, y: H - 640),
                 font: font(180, weight: .bold),
                 color: .white, kern: -4)
        drawText("your Mac.",
                 topLeft: CGPoint(x: rightBlockX, y: H - 840),
                 font: font(180, weight: .bold),
                 color: .white, kern: -4)

        // Lock shield glyph beneath.
        drawSymbol(ctx,
                   name: "lock.shield.fill",
                   center: CGPoint(x: rightBlockX + 110, y: 440),
                   pointSize: 180,
                   weight: .medium,
                   color: brandViolet,
                   glow: true,
                   glowAlpha: 0.55)
        drawText("No cloud  ·  No telemetry",
                 topLeft: CGPoint(x: rightBlockX + 230, y: 450),
                 font: font(28, weight: .medium),
                 color: muteOnDark, kern: 3.5)

        // LEFT — mockup.
        let cardW: CGFloat = 1040
        let cardH: CGFloat = 580
        let cardRect = CGRect(x: 140,
                              y: (H - cardH) / 2,
                              width: cardW, height: cardH)
        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .dark,
                          sourceText: "这是我想和你说的话。",
                          translationText: "This is what I want to tell you.",
                          targetLang: "EN")
    }
}

/// accurate.png — "Word for word." tells the story through contrast:
/// for each source phrase, show the obvious-but-wrong literal translation
/// (struck through, warm-orange) and Ora's correct idiomatic output
/// (bold white). Demonstrates that "accurate" means *meaning*, not just
/// mapped tokens.
func renderAccurate() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Wordmark top.
        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 110,
                           iconDiameter: 58, textSize: 54,
                           scheme: .dark)

        // Headline + sub-eyebrow.
        drawCenteredTextAtTop("Word for word.",
                              topY: H - 200,
                              canvasWidth: W,
                              font: font(118, weight: .bold),
                              color: .white,
                              kern: -2.5)
        drawCenteredTextAtTop("Not token for token.",
                              topY: H - 340,
                              canvasWidth: W,
                              font: font(56, weight: .regular),
                              color: NSColor.white.withAlphaComponent(0.58),
                              kern: -0.5)

        // Three contrast rows: source → struck literal → correct idiomatic.
        struct Row {
            let source: String
            let wrong:  String
            let right:  String
        }
        let rows: [Row] = [
            Row(source: "The ball is in your court.",
                wrong:  "球在你的场里。",
                right:  "现在轮到你了。"),
            Row(source: "お疲れ様でした。",
                wrong:  "You are tired.",
                right:  "Thank you for your hard work."),
            Row(source: "Break a leg!",
                wrong:  "摔断一条腿！",
                right:  "祝你好运！"),
        ]

        // Per-row typography.
        let sourceFont = font(36, weight: .regular)
        let wrongFont  = font(58, weight: .regular)
        let rightFont  = font(92, weight: .bold)
        let sourceColor = NSColor.white.withAlphaComponent(0.46)
        let wrongColor  = brandWarm.withAlphaComponent(0.68)
        let wrongStrike = brandWarm.withAlphaComponent(0.95)
        let rightColor: NSColor = .white

        let srcH:   CGFloat = 46
        let wrongH: CGFloat = 76
        let rightH: CGFloat = 118
        let gapSW:  CGFloat = 10   // source → wrong
        let gapWR:  CGFloat = 22   // wrong → right
        let rowH = srcH + gapSW + wrongH + gapWR + rightH
        let rowGap: CGFloat = 78

        let totalH = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * rowGap
        let topOfStack: CGFloat = H - 500
        let bottomBound: CGFloat = 80
        let availableH = topOfStack - bottomBound
        let startTop: CGFloat = topOfStack - max(0, (availableH - totalH) / 2)

        for (i, r) in rows.enumerated() {
            let rowTop = startTop - CGFloat(i) * (rowH + rowGap)

            drawCenteredLine(r.source,
                             topY: rowTop,
                             canvasWidth: W,
                             font: sourceFont,
                             color: sourceColor,
                             kern: 0.2)

            drawCenteredStrikethrough(r.wrong,
                                      topY: rowTop - srcH - gapSW,
                                      canvasWidth: W,
                                      font: wrongFont,
                                      color: wrongColor,
                                      strikeColor: wrongStrike,
                                      kern: -0.2)

            drawCenteredLine(r.right,
                             topY: rowTop - srcH - gapSW - wrongH - gapWR,
                             canvasWidth: W,
                             font: rightFont,
                             color: rightColor,
                             kern: -1.0)
        }
    }
}

/// instant.png — "At the speed of speech."  Bolt glyph + mockup,
///   evokes a personal simultaneous interpreter.
func renderInstant() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Wordmark top.
        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 140,
                           iconDiameter: 76, textSize: 70,
                           scheme: .dark)

        // Headline — centered.
        drawCenteredTextAtTop("At the speed",
                              topY: H - 300,
                              canvasWidth: W,
                              font: font(140, weight: .semibold),
                              color: NSColor.white.withAlphaComponent(0.85),
                              kern: -3)
        drawCenteredTextAtTop("of speech.",
                              topY: H - 460,
                              canvasWidth: W,
                              font: font(140, weight: .bold),
                              color: .white,
                              kern: -3)

        // Glyph + mockup horizontal pair, centered.
        let glyphSize: CGFloat = 240
        let cardW: CGFloat = 1240
        let cardH: CGFloat = 520
        let pairGap: CGFloat = 120
        let pairW = glyphSize + pairGap + cardW
        let pairStartX = (W - pairW) / 2
        let pairCenterY: CGFloat = 460

        let glyphCenter = CGPoint(
            x: pairStartX + glyphSize / 2,
            y: pairCenterY
        )
        drawSymbol(ctx,
                   name: "bolt.fill",
                   center: glyphCenter,
                   pointSize: glyphSize,
                   weight: .semibold,
                   color: NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.35, alpha: 1),
                   glow: true,
                   glowColor: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.25, alpha: 1),
                   glowAlpha: 0.55)

        let cardRect = CGRect(
            x: pairStartX + glyphSize + pairGap,
            y: pairCenterY - cardH / 2,
            width: cardW, height: cardH
        )
        drawCaptionMockup(ctx,
                          rect: cardRect,
                          scheme: .dark,
                          sourceText: "我刚才说的这句话还没说完…",
                          translationText: "I haven't even finished saying this yet…",
                          targetLang: "EN")

        // Tiny latency footer.
        drawCenteredTextAtTop("Sub-second end-to-end latency",
                              topY: 160,
                              canvasWidth: W,
                              font: font(26, weight: .medium),
                              color: dimOnDark,
                              kern: 4)
    }
}

/// free.png — "Free. Forever."  Pure typography, no mockup.
func renderFree() -> NSImage {
    let W: CGFloat = 2540, H: CGFloat = 1520
    return makeImage(size: CGSize(width: W, height: H)) { ctx, _ in
        drawAtmosphericBackdrop(ctx, size: CGSize(width: W, height: H), scheme: .dark)

        // Wordmark top-center (smaller, discrete).
        drawWordmarkInline(ctx,
                           centerX: W / 2, centerY: H - 180,
                           iconDiameter: 80, textSize: 74,
                           scheme: .dark)

        // Giant "Free." with a mint glow behind it.
        let mint = NSColor(calibratedRed: 0.43, green: 0.90, blue: 0.70, alpha: 1)
        drawRadialGlow(ctx,
                       center: CGPoint(x: W / 2, y: H / 2 + 60),
                       radius: 820,
                       color: mint,
                       innerAlpha: 0.35)

        drawCenteredTextAtTop("Free.",
                              topY: H / 2 + 380,
                              canvasWidth: W,
                              font: font(460, weight: .bold),
                              color: .white,
                              kern: -14)

        drawCenteredTextAtTop("Forever.",
                              topY: H / 2 - 300,
                              canvasWidth: W,
                              font: font(200, weight: .semibold),
                              color: NSColor.white.withAlphaComponent(0.72),
                              kern: -4)

        // Footer micro-line — the only explanation.
        drawCenteredTextAtTop("No accounts.  No subscriptions.  No ads.",
                              topY: 220,
                              canvasWidth: W,
                              font: font(30, weight: .medium),
                              color: dimOnDark,
                              kern: 4)
    }
}

// MARK: - Run

print("Rendering Ora promo posters → \(outputDir.path)")
save(renderHeroMockupDark(),  as: "hero-dark.jpg")
save(renderHeroMockupLight(), as: "hero-light.jpg")
save(renderSayIt(),           as: "say-it.jpg")
save(renderLocal(),           as: "local.jpg")
save(renderInstant(),         as: "instant.jpg")
save(renderOffline(),         as: "offline.jpg")
save(renderPrivate(),         as: "private.jpg")
save(renderAccurate(),        as: "accurate.jpg")
save(renderFree(),            as: "free.jpg")
save(renderLanguages(),       as: "languages.jpg")
save(renderSquare(),          as: "square.jpg")
print("✅ Done.")
