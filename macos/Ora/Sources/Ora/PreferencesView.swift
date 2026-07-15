import SwiftUI

/// Preferences window — hosts all user-tunable settings. Bound directly to
/// `Preferences.shared`. Quality and ASR language changes trigger a full
/// engine reload; target language changes apply live without reload.
struct PreferencesView: View {
    @Bindable var prefs = Preferences.shared
    let engine: TranslatorEngine

    private let languages = [
        "English", "Chinese", "Japanese", "Korean",
        "French", "German", "Spanish", "Italian",
        "Portuguese", "Russian", "Arabic",
    ]

    private let asrLanguageCodes: [(label: String, code: String?)] = [
        ("Auto-detect", nil),
        ("Chinese (zh)", "zh"),
        ("English (en)", "en"),
        ("Japanese (ja)", "ja"),
        ("Korean (ko)", "ko"),
        ("French (fr)", "fr"),
        ("German (de)", "de"),
        ("Spanish (es)", "es"),
    ]

    @State private var showClearConfirm = false
    @State private var clearError: String?

    var body: some View {
        TabView {
            Form {
                audioInputSection
                translationSection
                hotkeySection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "slider.horizontal.3")
            }

            Form {
                captionAppearanceSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Captions", systemImage: "captions.bubble")
            }

            Form {
                speechRecognitionSection
                vadSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Advanced", systemImage: "waveform")
            }

            Form {
                transcriptHistorySection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
        .frame(width: 500, height: 620)
        .navigationTitle("Ora Preferences")
        .confirmationDialog(
            "Delete all transcript history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                do {
                    try TranscriptHistory.shared.clearAll()
                    clearError = nil
                } catch {
                    clearError = "Clear failed: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every .jsonl log file in the history folder. This cannot be undone.")
        }
    }

    private var audioInputSection: some View {
        Section("Audio Input") {
            Picker("Source", selection: $prefs.audioSource) {
                ForEach(AudioSourceKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Text(prefs.audioSource == .systemAudio
                 ? "Captures audio played by other apps. Requires Screen Recording permission. Takes effect at next Start Listening."
                 : "Captures your microphone input. Takes effect at next Start Listening.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var translationSection: some View {
        Section("Translation") {
            Picker("Target Language", selection: $prefs.targetLanguage) {
                ForEach(languages, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
            .onChange(of: prefs.targetLanguage) { _, _ in
                engine.applyTargetLanguageChange()
            }

            Picker("LLM Backend", selection: $prefs.llmBackend) {
                ForEach(LLMBackendKind.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .onChange(of: prefs.llmBackend) { _, _ in
                Task { await engine.reload() }
            }
            Text(prefs.llmBackend.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if prefs.llmBackend == .mlxSwift {
                Picker("Quality", selection: $prefs.quality) {
                    ForEach(TranslatorQuality.allCases, id: \.self) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                .onChange(of: prefs.quality) { _, _ in
                    Task { await engine.reload() }
                }
            } else {
                TextField("Rapid-MLX URL", text: $prefs.rapidMLXURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $prefs.rapidMLXModel)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Reconnect Translator") {
                        Task { await engine.reload() }
                    }
                    Spacer()
                }
                Text("Start Rapid-MLX separately, then reconnect. Example: rapid-mlx serve qwen3.5-4b --served-model-name default --port 8000 --no-thinking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            Picker("Start / Stop Listening", selection: $prefs.startStopHotkey) {
                ForEach(GlobalHotkey.allCases, id: \.self) { hotkey in
                    Text(hotkey.glyphs).tag(hotkey)
                }
            }
            .onChange(of: prefs.startStopHotkey) { _, newValue in
                HotkeyManager.shared.updateShortcut(newValue)
            }

            Text(prefs.startStopHotkey.helpText)
                .font(.caption)
                .foregroundStyle(prefs.startStopHotkey == .legacyCommandShiftT ? .orange : .secondary)
        }
    }

    private var speechRecognitionSection: some View {
        Section("Speech Recognition") {
            Picker("Source Language Hint", selection: asrLanguageBinding) {
                ForEach(0..<asrLanguageCodes.count, id: \.self) { i in
                    Text(asrLanguageCodes[i].label).tag(i)
                }
            }
            .onChange(of: prefs.asrLanguage) { _, _ in
                Task { await engine.reload() }
            }
        }
    }

    private var captionAppearanceSection: some View {
        Section("Caption Appearance") {
            Picker("Layout", selection: $prefs.captionDisplayMode) {
                ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text(prefs.captionDisplayMode.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Translation Size")
                Slider(
                    value: $prefs.captionFontSize,
                    in: Preferences.captionFontSizeRange,
                    step: 1
                )
                Text("\(Int(prefs.captionFontSize)) pt")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Original Text Size")
                Slider(
                    value: $prefs.captionSourceFontSize,
                    in: Preferences.captionSourceFontSizeRange,
                    step: 1
                )
                Text("\(Int(prefs.captionSourceFontSize)) pt")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Sample original text")
                    .font(.system(size: CGFloat(prefs.captionSourceFontSize), weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Sample translation")
                    .font(.system(size: CGFloat(prefs.captionFontSize), weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
        }
    }

    private var vadSection: some View {
        Section("Voice Activity Detection") {
            Picker("Room Preset", selection: vadPresetBinding) {
                ForEach(VADPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            Text("Presets tune sensitivity and sentence commit timing for common rooms. Manual slider changes switch to Custom.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Sensitivity")
                Slider(value: vadThresholdBinding, in: 0.1...0.9, step: 0.05)
                Text(String(format: "%.2f", prefs.vadThreshold))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            Text("Lower = more sensitive (catches quieter speech)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("End-of-speech silence")
                Slider(
                    value: speechEndBinding,
                    in: 150...1500,
                    step: 50
                )
                Text("\(prefs.speechEndMs) ms")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            Text("How long to wait after speech stops before finalising")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptHistorySection: some View {
        Section("Transcript History") {
            HStack {
                Button("Open Viewer") {
                    TranscriptHistoryWindowPresenter.shared.show()
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [TranscriptHistory.shared.historyFolderURL]
                    )
                }
                Spacer()
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("Clear All History…")
                }
            }
            Text("History is stored as monthly JSONL files under Application Support.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let clearError {
                Text(clearError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var asrLanguageBinding: Binding<Int> {
        Binding(
            get: {
                asrLanguageCodes.firstIndex(where: { $0.code == prefs.asrLanguage }) ?? 0
            },
            set: { idx in
                prefs.asrLanguage = asrLanguageCodes[idx].code
            }
        )
    }

    private var vadPresetBinding: Binding<VADPreset> {
        Binding(
            get: { prefs.vadPreset },
            set: { prefs.applyVADPreset($0) }
        )
    }

    private var vadThresholdBinding: Binding<Double> {
        Binding(
            get: { prefs.vadThreshold },
            set: {
                prefs.vadThreshold = $0
                prefs.markCustomVADPreset()
            }
        )
    }

    private var speechEndBinding: Binding<Double> {
        Binding(
            get: { Double(prefs.speechEndMs) },
            set: {
                prefs.speechEndMs = Int($0)
                prefs.markCustomVADPreset()
            }
        )
    }
}
