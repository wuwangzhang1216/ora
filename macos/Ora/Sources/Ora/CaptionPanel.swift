import AppKit
import SwiftUI

/// Borderless floating panel hosting the CaptionView. Always on top,
/// draggable by background, transparent chrome, persisted frame origin.
/// Uses NSHostingController so the window automatically resizes to fit
/// the SwiftUI content — long translations grow the card downward
/// while keeping the top edge anchored.
final class CaptionPanel: NSPanel, NSWindowDelegate {
    private let hostingController: NSHostingController<CaptionView>
    private var savedTopY: CGFloat?
    private var isUserMoving = false

    init(engine: TranslatorEngine) {
        let root = CaptionView(engine: engine)
        let hc = NSHostingController(rootView: root)
        // Ask the hosting controller to size itself to the SwiftUI preferred size.
        hc.sizingOptions = [.preferredContentSize]
        self.hostingController = hc

        // Initial frame — the real size gets applied once the controller
        // reports its preferred size.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 624, height: 180),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false
        self.animationBehavior = .utilityWindow
        self.delegate = self

        self.contentViewController = hc

        // Place at saved origin or anchor to top-center of main screen.
        if let saved = Preferences.shared.captionWindowOrigin {
            self.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
            savedTopY = saved.y + frame.height
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let topY = visible.maxY - 24
            let origin = NSPoint(
                x: visible.midX - frame.width / 2,
                y: topY - frame.height
            )
            self.setFrameOrigin(origin)
            savedTopY = topY
        }

        // Observe content-size changes so we can keep the top edge fixed
        // as the SwiftUI card grows / shrinks.
        hc.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: hc.view
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Top-anchored auto-resize

    @objc private func contentFrameDidChange(_ note: Notification) {
        let newSize = hostingController.view.frame.size
        guard newSize.width > 0, newSize.height > 0 else { return }
        guard newSize != frame.size else { return }

        // Keep the top of the window fixed by computing a new origin that
        // preserves the current top edge. Falls back to the current top on
        // first layout.
        let topY = savedTopY ?? (frame.origin.y + frame.height)
        let newOrigin = NSPoint(
            x: frame.origin.x,
            y: topY - newSize.height
        )
        let newFrame = NSRect(origin: newOrigin, size: newSize)
        setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - NSWindowDelegate

    func windowWillMove(_ notification: Notification) {
        isUserMoving = true
    }

    func windowDidMove(_ notification: Notification) {
        Preferences.shared.captionWindowOrigin = frame.origin
        savedTopY = frame.origin.y + frame.height
        isUserMoving = false
    }
}
