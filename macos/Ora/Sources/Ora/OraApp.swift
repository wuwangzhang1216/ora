import AppKit
import Observation
import SwiftUI

// MARK: - Panel manager

@MainActor
@Observable
final class PanelManager {
    static let shared = PanelManager()
    private var panel: CaptionPanel?
    private(set) var isVisible: Bool = false

    func show(engine: TranslatorEngine) {
        if panel == nil {
            panel = CaptionPanel(engine: engine)
        }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggle(engine: TranslatorEngine) {
        if isVisible {
            hide()
        } else {
            show(engine: engine)
        }
    }
}

@MainActor
final class PreferencesWindowPresenter {
    static let shared = PreferencesWindowPresenter()
    private var window: NSWindow?

    func show(engine: TranslatorEngine) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: PreferencesView(engine: engine))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ora Preferences"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window = nil }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

@main
struct OraApp: App {
    @State private var engine: TranslatorEngine

    init() {
        FileHandle.standardError.write("[app] init\n".data(using: .utf8) ?? Data())
        NSApplication.shared.setActivationPolicy(.accessory)
        let openPreferencesOnLaunch = CommandLine.arguments.contains("--open-preferences-on-launch")

        let e = TranslatorEngine()
        _engine = State(initialValue: e)

        // Preload models in the background.
        if !openPreferencesOnLaunch {
            Task { await e.prepare() }
        }

        // Register the global ⌘⇧T hotkey. Carbon's RegisterEventHotKey does
        // not need Accessibility permission.
        HotkeyManager.shared.installDefault { [weak e] in
            guard let e else { return }
            Task { @MainActor in
                PanelManager.shared.show(engine: e)
                e.toggle()
            }
        }

        if openPreferencesOnLaunch {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                PreferencesWindowPresenter.shared.show(engine: e)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: engine)
        } label: {
            MenuBarLabel(phase: engine.phase)
        }
        .menuBarExtraStyle(.menu)

        // A real Settings scene so ⌘, opens the preferences window.
        Settings {
            PreferencesView(engine: engine)
        }
    }
}

/// Menu bar icon — echo-ring motif matching the app's .icns logo: an outer
/// ring + filled center dot. Rendered as an NSImage template so macOS
/// auto-tints it for dark/light menu bar appearance.
private struct MenuBarLabel: View {
    let phase: TranslatorEngine.Phase

    var body: some View {
        switch phase {
        case .loading:
            Image(systemName: "arrow.down.circle")
        case .error:
            Image(systemName: "exclamationmark.triangle")
        default:
            Image(nsImage: MenuBarLabel.echoRingImage)
        }
    }

    /// Cached template NSImage. Built once because the menu bar label view
    /// body is re-evaluated on every phase change.
    private static let echoRingImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = min(rect.width, rect.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)

            ctx.setStrokeColor(NSColor.black.cgColor)  // template color, will be tinted
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            // Outer ring
            let ringRadius = s * 0.40
            let ringWidth = s * 0.13
            ctx.setLineWidth(ringWidth)
            ctx.strokeEllipse(in: CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))

            // Center dot
            let dotRadius = s * 0.15
            ctx.fillEllipse(in: CGRect(
                x: center.x - dotRadius,
                y: center.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))

            return true
        }
        image.isTemplate = true
        return image
    }()
}

// MARK: - Menu content

struct MenuContent: View {
    @Bindable var engine: TranslatorEngine
    @Bindable var prefs = Preferences.shared
    @Bindable var panelMgr = PanelManager.shared

    var body: some View {
        Button(toggleLabel) {
            PanelManager.shared.show(engine: engine)
            engine.toggle()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])

        Divider()

        Menu("Target Language") {
            ForEach(["English", "Chinese", "Japanese", "Korean", "French", "German", "Spanish"], id: \.self) { lang in
                Button {
                    prefs.targetLanguage = lang
                    engine.applyTargetLanguageChange()
                } label: {
                    if lang == prefs.targetLanguage {
                        Label(lang, systemImage: "checkmark")
                    } else {
                        Text(lang)
                    }
                }
            }
        }

        Menu("Quality") {
            ForEach(TranslatorQuality.allCases, id: \.self) { q in
                Button {
                    guard q != prefs.quality else { return }
                    prefs.quality = q
                    Task { await engine.reload() }
                } label: {
                    if q == prefs.quality {
                        Label(q.displayName, systemImage: "checkmark")
                    } else {
                        Text(q.displayName)
                    }
                }
            }
        }

        Menu("Caption Layout") {
            ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                Button {
                    prefs.captionDisplayMode = mode
                } label: {
                    if mode == prefs.captionDisplayMode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        }

        Divider()

        Button(panelMgr.isVisible ? "Hide Caption Window" : "Show Caption Window") {
            panelMgr.toggle(engine: engine)
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Divider()

        Button("Copy Current Translation") {
            copyToPasteboard(engine.translationText)
        }
        .disabled(engine.translationText.isEmpty)

        Button("Copy Last Translation") {
            copyToPasteboard(TranscriptHistory.shared.latestEntry?.translationText ?? "")
        }
        .disabled(TranscriptHistory.shared.latestEntry == nil)

        Button("Export Current Session…") {
            TranscriptExportCoordinator.export(
                entries: TranscriptHistory.shared.currentSession,
                suggestedName: "ora-session-\(TranscriptExportCoordinator.timestamp())"
            )
        }
        .disabled(TranscriptHistory.shared.currentSession.isEmpty)

        Button("Export All History…") {
            TranscriptExportCoordinator.export(
                entries: TranscriptHistory.shared.loadAll(),
                suggestedName: "ora-history-\(TranscriptExportCoordinator.timestamp())"
            )
        }

        Button("Open History Folder") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [TranscriptHistory.shared.historyFolderURL]
            )
        }

        Divider()

        Button("Preferences…") {
            PreferencesWindowPresenter.shared.show(engine: engine)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Ora") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var toggleLabel: String {
        switch engine.phase {
        case .listening: return "Stop Listening"
        case .loading(let status, _): return status
        case .error(let msg): return "Error: \(msg.prefix(40))"
        default: return "Start Listening"
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Transcript export

/// Presents an NSSavePanel with all supported export formats and writes the
/// rendered bytes. Chosen format is inferred from the file extension the
/// user picks in the panel's format dropdown.
@MainActor
enum TranscriptExportCoordinator {
    /// `yyyy-MM-dd-HHmmss` for unique default filenames across exports.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    static func export(entries: [TranscriptEntry], suggestedName: String) {
        guard !entries.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = TranscriptExportFormat.allCases.map(\.utType)
        panel.title = "Export Transcript"
        panel.message = "Pick a format via the file extension (txt / srt / json / md)."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        let format = TranscriptExportFormat(rawValue: ext) ?? .txt
        let data = TranscriptExporter.render(entries, as: format)

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
