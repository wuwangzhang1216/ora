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
    @State private var realRouterKey = ""
    @State private var realRouterStatus: String?
    @State private var testingRealRouter = false

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
            Text(prefs.audioSource.helpText)
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

            Picker("Speech Recognition", selection: $prefs.recognitionBackend) {
                ForEach(RecognitionBackendKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: prefs.recognitionBackend) { _, _ in
                engine.stop()
                Task { await engine.reload() }
            }
            Text(prefs.recognitionBackend.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("LLM Backend", selection: $prefs.llmBackend) {
                ForEach(LLMBackendKind.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .onChange(of: prefs.llmBackend) { _, _ in
                // Switching to an upstream translator requires a fresh Start;
                // changing this setting must not upload an ongoing local call.
                if prefs.llmBackend == .realRouter { engine.stop() }
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
            } else if prefs.llmBackend == .rapidMLX {
                TextField("Rapid-MLX URL", text: $prefs.rapidMLXURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $prefs.rapidMLXModel)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Reconnect Translator") {
                        Task { await engine.reload() }
                    }
                    switch engine.phase {
                    case .ready, .listening:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .loading:
                        Text("Preparing…").foregroundStyle(.secondary)
                    case .error(let message):
                        Text("Not ready").foregroundStyle(.red).help(message)
                    case .idle:
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("Start Rapid-MLX separately, then reconnect. Example: rapid-mlx serve qwen3.5-4b --served-model-name default --port 8000 --no-thinking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if prefs.llmBackend == .realRouter || prefs.recognitionBackend == .realRouter {
                realRouterSettings
            }
        }
    }

    private var realRouterSettings: some View {
        Group {
            TextField("Server URL", text: $prefs.realRouterURL)
                .textFieldStyle(.roundedBorder)
                .disabled(testingRealRouter)
            if prefs.llmBackend == .realRouter {
                TextField("Translation Model", text: $prefs.realRouterModel)
                    .textFieldStyle(.roundedBorder)
                    .disabled(testingRealRouter)
            }
            SecureField("API Key (blank to reuse saved key)", text: $realRouterKey)
                .textFieldStyle(.roundedBorder)
                .disabled(testingRealRouter)
            Text("Keys are saved in macOS Keychain. Test stops listening and uses a synthetic English speech sample for API recognition, then tests API translation if enabled. It never records your microphone or uploads your history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(testingRealRouter ? "Testing…" : "Save & Test APIs") {
                testRealRouter()
            }
            .disabled(testingRealRouter)
            if let realRouterStatus {
                Text(realRouterStatus)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
    }

    private func testRealRouter() {
        engine.stop()
        testingRealRouter = true
        realRouterStatus = nil
        let url = prefs.realRouterURL, model = prefs.realRouterModel, target = prefs.targetLanguage
        let testSpeech = prefs.recognitionBackend == .realRouter
        let testTranslation = prefs.llmBackend == .realRouter
        Task { @MainActor in
            defer { testingRealRouter = false }
            do {
                if !realRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try RealRouterCredentials.save(realRouterKey)
                    realRouterKey = ""
                }
                let key = try RealRouterCredentials.load()
                let translator = testTranslation ? try await RealRouterTranslator.load(
                    baseURL: url, model: model, apiKey: key, targetLanguage: target
                ) : nil
                var source = RealRouterSpeechProbe.sentence
                var report: [String] = []
                if testSpeech {
                    let audio = try await RealRouterSpeechProbe.audio()
                    let recognizer = try RealRouterSpeechRecognizer(baseURL: url, apiKey: key, language: "en")
                    let start = Date()
                    source = try await recognizer.transcribe(audio)
                    guard !source.isEmpty else { throw RealRouterError.invalidTranscription }
                    report.append(String(format: "Speech API %.2fs · %@", Date().timeIntervalSince(start), source))
                }
                if let translator {
                    let start = Date()
                    var firstToken: TimeInterval?
                    var result = ""
                    for try await token in translator.translateStream(source, history: []) {
                        if firstToken == nil, !token.isEmpty { firstToken = Date().timeIntervalSince(start) }
                        result += token
                    }
                    report.append(String(format: "Translation first text %.2fs · total %.2fs\n%@",
                        firstToken ?? 0, Date().timeIntervalSince(start), result))
                }
                realRouterStatus = "Connected\n" + report.joined(separator: "\n")
                if prefs.llmBackend == .realRouter || prefs.recognitionBackend == .realRouter { await engine.reload() }
            } catch {
                realRouterStatus = error.localizedDescription
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
