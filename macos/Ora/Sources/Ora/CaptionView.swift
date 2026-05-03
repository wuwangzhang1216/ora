import AppKit
import SwiftUI

/// Two-line caption card: source text above, translation below. Uses
/// ultraThinMaterial for the frosted look and smooth cross-fades on text
/// changes so partial updates don't flicker.
struct CaptionView: View {
    @Bindable var engine: TranslatorEngine
    @Bindable private var prefs = Preferences.shared
    @State private var isHovered: Bool = false

    private var translationFontSize: CGFloat { CGFloat(prefs.captionFontSize) }
    private var sourceFontSize: CGFloat { CGFloat(prefs.captionSourceFontSize) }
    private var isCompact: Bool { prefs.captionDisplayMode == .compact }
    private var shouldShowSource: Bool {
        prefs.captionDisplayMode == .bilingual && !engine.sourceText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            header

            if shouldShowSource {
                Text(engine.sourceText)
                    .font(.system(size: sourceFontSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            translationLine
        }
        .padding(.horizontal, isCompact ? 14 : 20)
        .padding(.vertical, isCompact ? 12 : 16)
        .frame(width: isCompact ? 420 : 600, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)
        // Leave enough slack on all sides for the drop shadow to fade out
        // naturally — less than (shadow radius + y offset) gets clipped by
        // the hosting window and produces a visible hard-edged rectangle
        // under the card.
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 40)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        // No animation on `translationText` — LLM streaming writes dozens
        // of updates per second; animating each one makes the whole line
        // look like it's being "re-printed" every token. Tokens should
        // just append instantly.
        .animation(.easeOut(duration: 0.18), value: engine.sourceText)
        .animation(.easeOut(duration: 0.2), value: engine.phase)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()

            // Language chip / hover controls — share the same slot so the
            // card doesn't jiggle when the hover state flips.
            ZStack(alignment: .trailing) {
                Text("→ \(engine.targetLanguage)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 0 : 1)
                controlButtons
                    .opacity(isHovered ? 1 : 0)
            }
        }
    }

    // MARK: - Control buttons (hover-revealed)

    private var controlButtons: some View {
        HStack(spacing: 4) {
            ControlButton(
                systemImage: engine.phase == .listening ? "pause.fill" : "play.fill",
                help: engine.phase == .listening ? "Pause listening" : "Resume listening"
            ) {
                engine.toggle()
            }

            ControlButton(systemImage: "gearshape", help: "Preferences") {
                PreferencesWindowPresenter.shared.show(engine: engine)
            }

            ControlButton(systemImage: "clock.arrow.circlepath", help: "Transcript history") {
                TranscriptHistoryWindowPresenter.shared.show()
            }

            ControlButton(systemImage: "doc.on.doc", help: "Copy translation") {
                copyCurrentTranslation()
            }
            .disabled(engine.translationText.isEmpty)

            ControlButton(
                systemImage: "square.and.arrow.up",
                help: "Export current session"
            ) {
                TranscriptExportCoordinator.export(
                    entries: TranscriptHistory.shared.currentSession,
                    suggestedName: "ora-session-\(TranscriptExportCoordinator.timestamp())"
                )
            }

            ControlButton(systemImage: "xmark", help: "Hide window") {
                PanelManager.shared.hide()
            }
        }
    }

    private func copyCurrentTranslation() {
        guard !engine.translationText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(engine.translationText, forType: .string)
    }

    // MARK: - Translation line

    @ViewBuilder
    private var translationLine: some View {
        let display = engine.translationText.isEmpty ? placeholderText : engine.translationText
        Text(display)
            .font(.system(size: translationFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(engine.translationText.isEmpty ? Color.secondary : Color.primary)
            .opacity(engine.isPartial && !engine.translationText.isEmpty ? 0.72 : 1.0)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Status indicator

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        switch engine.phase {
        case .listening: return .red
        case .ready: return .green
        case .loading: return .orange
        case .idle: return .gray
        case .error: return .pink
        }
    }

    private var statusLabel: String {
        switch engine.phase {
        case .idle: return "Idle"
        case .loading(let status, _): return status
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .error: return "Error"
        }
    }

    private var placeholderText: String {
        switch engine.phase {
        case .idle: return "Click the menu bar icon to begin"
        case .loading(let status, _): return status
        case .ready: return "Ready — speak to translate"
        case .listening: return "Listening…"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Small circular control button

private struct ControlButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isOver: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isOver ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.12)) { isOver = over }
        }
    }
}
