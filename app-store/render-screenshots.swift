#!/usr/bin/env swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let out = root.appendingPathComponent("screenshots")
let white = NSColor(calibratedWhite: 0.98, alpha: 1)
let ink = NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.19, alpha: 1)
let muted = NSColor(calibratedRed: 0.36, green: 0.43, blue: 0.50, alpha: 1)
let teal = NSColor(calibratedRed: 0.09, green: 0.52, blue: 0.56, alpha: 1)

func text(_ value: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, color: NSColor = ink) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 5
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph]
    let string = NSAttributedString(string: value, attributes: attributes)
    let height = ceil(string.boundingRect(with: NSSize(width: width, height: 1000),
        options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    string.draw(with: NSRect(x: x, y: 900-top-height, width: width, height: height),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
}
func label(_ value: String, x: CGFloat, y: CGFloat) {
    let p = NSBezierPath(roundedRect: NSRect(x:x,y:y,width:300,height:62),xRadius:20,yRadius:20)
    NSColor.white.withAlphaComponent(0.72).setFill(); p.fill()
    text(value,x:x+24,top:900-y-45,width:260,size:19,weight:.medium)
}
func shot(_ name: String, in rect: CGRect, crop: CGRect? = nil) {
    let url = out.appendingPathComponent("raw/\(name).jpg")
    guard let image = NSImage(contentsOf:url), let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil),
          let ctx = NSGraphicsContext.current?.cgContext else { fatalError(name) }
    let chosen = crop.flatMap { cg.cropping(to:$0) } ?? cg
    ctx.saveGState()
    ctx.setShadow(offset:CGSize(width:0,height:-15),blur:35,color:NSColor.black.withAlphaComponent(0.18).cgColor)
    ctx.setFillColor(ink.cgColor)
    let path = CGPath(roundedRect:rect,cornerWidth:25,cornerHeight:25,transform:nil)
    ctx.addPath(path);ctx.fillPath()
    ctx.setShadow(offset:.zero,blur:0,color:nil)
    ctx.addPath(path);ctx.clip();ctx.draw(chosen,in:rect)
    ctx.restoreGState()
}
func render(_ language: String, _ index: Int) {
    let zh = language == "zh-Hans"
    let image = NSImage(size:NSSize(width:1440,height:900))
    image.lockFocus()
    let bg=NSGradient(colors:[NSColor(calibratedRed:0.92,green:0.97,blue:0.97,alpha:1),
                              NSColor(calibratedRed:0.94,green:0.95,blue:0.99,alpha:1)])!
    bg.draw(in:NSRect(x:0,y:0,width:1440,height:900),angle:-35)
    text("◉  Ora",x:88,top:55,width:600,size:31,weight:.semibold,color:teal)
    if index == 1 {
        text(zh ? "让字幕跟上对话。" : "Follow the conversation.",x:84,top:135,width:1280,size:72,weight:.semibold)
        text(zh ? "本地语音识别与翻译，呈现在清晰的双语字幕中。" : "Speech and translation, together in a clear floating window.",
             x:90,top:242,width:1260,size:27,color:muted)
        shot("bilingual",in:CGRect(x:88,y:238,width:1264,height:312),crop:CGRect(x:56,y:48,width:1200,height:296))
        label(zh ? "原文与译文一起看" : "Original + translation",x:88,y:111)
        label(zh ? "文字历史保存在本机" : "Local transcript history",x:422,y:111)
        label(zh ? "随时开始或停止" : "Start and stop anytime",x:756,y:111)
        text(zh ? "真实应用预览 · 字幕文字为演示内容" : "Native app preview · Illustrative caption text",x:90,top:837,width:1250,size:17,color:muted)
    } else if index == 2 {
        text(zh ? "适合你的 Mac。" : "Made for your Mac.",x:84,top:145,width:760,size:65,weight:.semibold)
        text(zh ? "系统音频、麦克风，或会议双输入。" : "System audio, microphone,\nor both for meetings.",x:90,top:258,width:620,size:28,color:muted)
        shot("compact",in:CGRect(x:88,y:266,width:610,height:164),crop:CGRect(x:56,y:48,width:840,height:224))
        text(zh ? "选择双语、仅译文或紧凑布局。\n调整字号，留出更多屏幕空间。" : "Bilingual, translation-only, or compact.\nAdjust text size to fit your screen.",x:90,top:677,width:620,size:23,color:muted)
        shot("general",in:CGRect(x:805,y:108,width:535,height:564),crop:CGRect(x:0,y:80,width:1200,height:1264))
        text(zh ? "需要 Apple Silicon 与 macOS 15 或更新版本 · 字幕为预览内容" : "Apple Silicon · macOS 15 or later · Preview caption text",x:90,top:837,width:1260,size:17,color:muted)
    } else {
        text(zh ? "默认本地。\n分享由你决定。" : "Local by default.\nSharing is a choice.",x:84,top:149,width:740,size:62,weight:.semibold)
        text(zh ? "本地模型在 Mac 上处理语音。\n外部 AI 服务每次会话单独确认。" : "Local models process speech on your Mac.\nExternal AI asks before each session.",x:90,top:367,width:650,size:25,color:muted)
        text(zh ? "查看隐私说明，管理文字历史，\n将导出文件保存到你选择的位置。" : "Read the privacy policy, manage history,\nand choose where exports are saved.",x:90,top:546,width:640,size:24,color:muted)
        shot("privacy",in:CGRect(x:805,y:108,width:535,height:564),crop:CGRect(x:0,y:80,width:1200,height:1264))
        text(zh ? "本地处理需选择本地后端 · 首次使用需要下载模型" : "Select local backends for on-device processing. Initial model download required.",x:90,top:837,width:1270,size:17,color:muted)
    }
    image.unlockFocus()
    let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
    // Exact supported Mac App Store dimensions, independent of the display scale.
    let final = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2880,pixelsHigh:1800,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context=NSGraphicsContext(bitmapImageRep:final)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    NSImage(cgImage:rep.cgImage!,size:NSSize(width:2880,height:1800)).draw(in:NSRect(x:0,y:0,width:2880,height:1800))
    NSGraphicsContext.restoreGraphicsState()
    let dir=out.appendingPathComponent(language)
    try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    let path=dir.appendingPathComponent(String(format:"%02d.jpg",index))
    try! final.representation(using:.jpeg,properties:[.compressionFactor:0.94])!.write(to:path)
    print(path.path)
}
for lang in ["en-US","zh-Hans"] { for index in 1...3 { render(lang,index) } }
