import AppKit
import SwiftUI

/// Two-line live captions measured with the rendering fonts. The presenter
/// follows new translated speech; complete transcripts remain in history.
struct CaptionView: View {
    @Bindable var engine: TranslatorEngine
    @Bindable private var prefs = Preferences.shared

    private var translationFontSize: CGFloat { CGFloat(prefs.captionFontSize) }
    private var sourceFontSize: CGFloat { CGFloat(prefs.captionSourceFontSize) }
    private var isCompact: Bool { prefs.captionDisplayMode == .compact }
    private var shouldShowSource: Bool {
        prefs.captionDisplayMode == .bilingual
    }
    private var typography: CaptionTypography {
        CaptionTypography(width: isCompact ? 392 : 560,
                          sourceSize: sourceFontSize, translationSize: translationFontSize,
                          showsSource: shouldShowSource)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            captionContent
            if engine.sessionNotice != nil || engine.droppedUtteranceCount > 0 || engine.lastTranslationError != nil {
                sessionFeedback
            }
        }
        .padding(.horizontal, isCompact ? 14 : 20)
        .padding(.vertical, isCompact ? 12 : 14)
        .frame(width: isCompact ? 420 : 600, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                // A stable dark surface keeps captions legible over white
                // slides and bright meeting windows as well as dark video.
                .fill(Color(red: 0.063, green: 0.075, blue: 0.09).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        // Leave enough slack on all sides for the drop shadow to fade out
        // naturally — less than (shadow radius + y offset) gets clipped by
        // the hosting window and produces a visible hard-edged rectangle
        // under the card.
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        .onAppear { engine.captions.reflow(typography) }
        .onChange(of: typography) { _, value in engine.captions.reflow(value) }
        // No animation on `translationText` — LLM streaming writes dozens
        // of updates per second; animating each one makes the whole line
        // look like it's being "re-printed" every token. Tokens should
        // just append instantly.
        // Source snapshots and status changes must not animate the caption
        // subtree either — that also animates translation reflow implicitly.
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            statusIndicator
            Text(statusLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            ControlButton(
                systemImage: engine.phase == .listening ? "pause.fill" : "play.fill",
                help: engine.phase == .listening ? "End session" : "Start new session"
            ) { engine.toggle() }
            .disabled(engine.isCaptionPreview)
            Menu {
                Toggle("Show source", isOn: Binding(
                    get: { shouldShowSource },
                    set: { prefs.captionDisplayMode = $0 ? .bilingual : .translationOnly }))
                Button("Preferences…", systemImage: "slider.horizontal.3") {
                    PreferencesWindowPresenter.shared.show(engine: engine)
                }
                Button("Transcript history", systemImage: "clock.arrow.circlepath") {
                    TranscriptHistoryWindowPresenter.shared.show()
                }
                Divider()
                Button("Copy visible subtitle", systemImage: "doc.on.doc") { copyCurrentTranslation() }
                    .disabled(engine.captions.visible?.translation.display.isEmpty ?? true)
                Button("Export current session", systemImage: "square.and.arrow.up") {
                    TranscriptExportCoordinator.export(
                        entries: TranscriptHistory.shared.currentSession,
                        suggestedName: "ora-session-\(TranscriptExportCoordinator.timestamp())")
                }
                Divider()
                Button("Hide window", systemImage: "xmark") { PanelManager.shared.hide() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More caption options")
            .accessibilityLabel("More caption options")
        }
    }

    @ViewBuilder
    private var sessionFeedback: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let notice = engine.sessionNotice {
                Text(notice.detail)
                Spacer(minLength: 0)
                switch notice {
                case .saved, .failed:
                    Button("View history") { TranscriptHistoryWindowPresenter.shared.show() }
                        .buttonStyle(.plain)
                case .saving, .empty: EmptyView()
                }
            } else if engine.droppedUtteranceCount > 0 {
                Text("\(engine.droppedUtteranceCount) audio segments missed").foregroundStyle(.orange)
            } else if let error = engine.lastTranslationError {
                Text("Translation failed · source saved").foregroundStyle(.orange).help(error)
                Spacer(minLength: 0)
                Button("Reconnect") { Task { await engine.reload() } }
                    .buttonStyle(.plain)
                    .help(error)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func copyCurrentTranslation() {
        guard let text = engine.captions.visible?.translation.display, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Translation line

    @ViewBuilder
    private var captionContent: some View {
        let cue = engine.captions.visible
        let translation = cue?.translation.display ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if shouldShowSource, let source = cue?.source.display, !source.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source)
                        .font(Font(typography.sourceFont))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("Live recognition can be ahead of the translation.")
                Divider().overlay(Color.white.opacity(0.04)).padding(.vertical, 2)
            }
            Text(engine.sessionNotice?.title ?? (!translation.isEmpty ? translation
                 : engine.lastTranslationError != nil ? "Translation unavailable"
                 : cue != nil ? (cue?.isDraft == true ? "Translating…" : " ") : placeholderText))
                .font(Font(typography.translationFont))
                .foregroundStyle(!translation.isEmpty ? Color.primary : Color.secondary)
                .frame(minHeight: lineHeight(typography.translationFont) * (cue != nil || engine.phase == .listening ? 2 : 1), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    // MARK: - Status indicator

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        if let notice = engine.sessionNotice {
            switch notice {
            case .saving: return .orange
            case .saved: return .green
            case .empty: return .gray
            case .failed: return .pink
            }
        }
        switch engine.phase {
        case .listening: return .mint
        case .ready: return .green
        case .loading: return .orange
        case .idle: return .gray
        case .error: return .pink
        }
    }

    private var statusLabel: String {
        if engine.isCaptionPreview { return "Preview" }
        if let notice = engine.sessionNotice {
            switch notice {
            case .saving: return "Saving"
            case .saved: return "Saved"
            case .empty: return "Session ended"
            case .failed: return "Save failed"
            }
        }
        switch engine.phase {
        case .idle: return "Idle"
        case .loading(let status, _): return status
        case .ready: return engine.captions.isDraining ? "Finishing captions" : "Ready"
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

// MARK: - Persistent caption control

private struct ControlButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isOver: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(isOver ? 0.09 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.12)) { isOver = over }
        }
    }
}
