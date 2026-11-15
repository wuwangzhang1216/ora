import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Ora Preview"
        let image = NSImage(contentsOf: Bundle.main.url(forResource: "Preview", withExtension: "icns")!)!
        app.applicationIconImage = image
        let menu = NSMenu(); let root = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = submenu; menu.addItem(root); app.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = name + " — Icon Study"
        w.isReleasedWhenClosed = false
        let view = NSImageView(frame: NSRect(x: 30, y: 54, width: 112, height: 112)); view.image = image
        let label = NSTextField(labelWithString: name); label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.frame = NSRect(x: 166, y: 115, width: 250, height: 34)
        let note = NSTextField(wrappingLabelWithString: "Dock 图标预览\n这是独立的设计测试 App。")
        note.textColor = .secondaryLabelColor; note.frame = NSRect(x: 166, y: 62, width: 250, height: 46)
        w.contentView?.addSubview(view); w.contentView?.addSubview(label); w.contentView?.addSubview(note)
        w.center(); w.makeKeyAndOrderFront(nil); window = w
        app.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
let app = NSApplication.shared
let delegate = Delegate(); app.delegate = delegate; app.run()
