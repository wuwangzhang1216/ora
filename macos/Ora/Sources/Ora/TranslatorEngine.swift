import Foundation
import Observation

/// Owns the full mic → VAD → ASR → LLM pipeline and exposes observable state
/// for SwiftUI. Configuration lives in `Preferences.shared`; the engine reads
/// from there on each `prepare()` call.
@MainActor
@Observable
final class TranslatorEngine {
    // MARK: - Observable state

    enum Phase: Equatable {
        case idle
        case loading(status: String, progress: Double)
        case ready
        case listening
        case error(String)
    }

    var phase: Phase = .idle
    var sourceText: String = ""
    var translationText: String = ""
    var isPartial: Bool = false
    var utteranceCount: Int = 0

    // MARK: - Config shortcut (read-only)

    /// Pulled from Preferences at prepare time; exposed so SwiftUI views can
    /// observe and display without binding to Preferences directly.
    var targetLanguage: String { Preferences.shared.targetLanguage }
    var quality: TranslatorQuality { Preferences.shared.quality }

    // MARK: - Private

    private let asrModelId = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    private var asr: ASRClient?
    private var vad: VADSegmenter?
    private var backend: MLXChatTranslator?
    private var audioSource: AudioSource?
    private var eventLoopTask: Task<Void, Never>?
    private var partialPipe: PartialPipelineUI?

    nonisolated init() {}

    // MARK: - Prepare / reload

    /// Load all three models. Safe to call multiple times — no-op if already ready.
    func prepare() async {
        if case .ready = phase { return }
        if case .listening = phase { return }
        phase = .loading(status: "Loading VAD…", progress: 0.0)

        let prefs = Preferences.shared
        let modelId = prefs.quality.modelId
        let target = prefs.targetLanguage
        let asrLang = prefs.asrLanguage
        let asrModel = asrModelId

        do {
            async let vadTask = VADSegmenter.load()
            async let asrTask = ASRClient.load(modelId: asrModel, language: asrLang)
            async let backendTask = MLXChatTranslator.load(
                modelId: modelId,
                targetLanguage: target,
                onProgress: { fraction, desc in
                    Task { @MainActor [weak self] in
                        let label = desc.isEmpty ? "Downloading translator…" : desc
                        self?.phase = .loading(status: label, progress: fraction)
                    }
                }
            )

            self.vad = try await vadTask
            phase = .loading(status: "Loading ASR…", progress: 0.33)
            self.asr = try await asrTask
            phase = .loading(status: "Loading translator…", progress: 0.66)
            self.backend = try await backendTask

            phase = .ready
        } catch {
            phase = .error(String(describing: error))
        }
    }

    /// Tear down and re-prepare. Used when quality or asr language changes.
    func reload() async {
        let wasListening: Bool
        if case .listening = phase { wasListening = true } else { wasListening = false }
        stop()
        asr = nil
        vad = nil
        backend = nil
        phase = .idle
        await prepare()
        if wasListening, case .ready = phase { await start() }
    }

    /// Lightweight update when only the target language changes — no model reload.
    func applyTargetLanguageChange() {
        backend?.targetLanguage = Preferences.shared.targetLanguage
    }

    // MARK: - Start / stop

    func start() async {
        guard case .ready = phase else { return }
        guard let vad, let asr, let backend else { return }

        let source: AudioSource?
        let sourceKind = Preferences.shared.audioSource
        switch sourceKind {
        case .microphone:
            source = MicrophoneCapture()
        case .systemAudio:
            source = await SystemAudioCapture.create()
        }
        guard let source else {
            switch sourceKind {
            case .microphone:
                phase = .error("Failed to init microphone capture")
            case .systemAudio:
                phase = .error("System audio unavailable — grant Screen Recording permission in System Settings → Privacy & Security")
            }
            return
        }
        self.audioSource = source

        let pipe = PartialPipelineUI(asr: asr, backend: backend) { [weak self] src, translated in
            Task { @MainActor [weak self] in
                self?.sourceText = src
                self?.translationText = translated
                self?.isPartial = true
            }
        }
        Task { await pipe.start() }
        self.partialPipe = pipe

        phase = .listening
        sourceText = ""
        translationText = ""
        isPartial = false

        // Snapshot user-tunable VAD thresholds from Preferences at start()
        // time so the slider in Preferences actually takes effect — new
        // values apply at the next Start Listening.
        let prefStart = Float(Preferences.shared.vadThreshold)
        let prefStop = max(0.0, prefStart - Config.vadHysteresis)
        let prefEndSilenceMs = Preferences.shared.speechEndMs

        eventLoopTask = Task.detached { [weak self, vad, asr, backend, source] in
            let audioStream = source.stream()
            let events = vad.events(
                from: audioStream,
                startThreshold: prefStart,
                stopThreshold: prefStop,
                endSilenceMs: prefEndSilenceMs
            )

            for await event in events {
                guard let self else { return }
                switch event {
                case .speechStart:
                    // Mark current content as "stale" but DON'T clear it —
                    // blanking the card for the ~800 ms until the first
                    // partial lands is more jarring than leaving the old
                    // text visible. The incoming partial will overwrite
                    // atomically via contentTransition.
                    await MainActor.run {
                        self.isPartial = true
                    }

                case .partial(let audio):
                    await pipe.submit(audio)

                case .final(let audio):
                    let segmentStart = Date()
                    await pipe.freeze()
                    let text = await asr.transcribe(audio)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count < 2 {
                        await pipe.reset()
                        continue
                    }

                    // Commit the final ASR source text, but DO NOT clear
                    // translationText — that would flash the card to an
                    // empty / placeholder state for ~300ms before the LLM's
                    // first token arrives. We let the incoming stream
                    // replace the previous partial translation atomically.
                    await MainActor.run {
                        self.sourceText = text
                        self.utteranceCount += 1
                        self.isPartial = false
                    }

                    var fullTranslation = ""
                    var gotFirstChunk = false
                    do {
                        for try await chunk in backend.translateStream(text) {
                            fullTranslation += chunk
                            let snapshot = fullTranslation
                            let isFirst = !gotFirstChunk
                            gotFirstChunk = true
                            await MainActor.run {
                                // First token of the final stream replaces
                                // the old partial text directly — no empty
                                // intermediate state.
                                _ = isFirst
                                self.translationText = snapshot
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.translationText = "[translate error: \(error)]"
                        }
                    }

                    let finalTranslation = fullTranslation
                    let finalSource = text
                    if !finalTranslation.isEmpty {
                        let endedAt = Date()
                        await MainActor.run {
                            let entry = TranscriptEntry(
                                id: UUID(),
                                startedAt: segmentStart,
                                endedAt: endedAt,
                                sourceText: finalSource,
                                translationText: finalTranslation,
                                sourceLanguageHint: Preferences.shared.asrLanguage,
                                targetLanguage: Preferences.shared.targetLanguage,
                                audioSource: Preferences.shared.audioSource.rawValue,
                                sessionId: TranscriptHistory.shared.sessionId
                            )
                            TranscriptHistory.shared.append(entry)
                        }
                    }

                    await pipe.reset()
                }
            }
        }
    }

    func stop() {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        Task { [partialPipe] in
            await partialPipe?.shutdown()
        }
        partialPipe = nil
        audioSource = nil
        if case .listening = phase {
            phase = .ready
        }
    }

    func toggle() {
        switch phase {
        case .listening:
            stop()
        case .ready:
            Task { await start() }
        case .idle, .loading, .error:
            Task {
                await prepare()
                if case .ready = phase { await start() }
            }
        }
    }
}
