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
    /// Utterances shed because ASR+translation fell behind sustained speech.
    /// Nonzero means the user lost sentences — surfaced, never silent.
    var droppedUtteranceCount: Int = 0

    // MARK: - Config shortcut (read-only)

    /// Pulled from Preferences at prepare time; exposed so SwiftUI views can
    /// observe and display without binding to Preferences directly.
    var targetLanguage: String { Preferences.shared.targetLanguage }
    var quality: TranslatorQuality { Preferences.shared.quality }
    var llmBackend: LLMBackendKind { Preferences.shared.llmBackend }

    // MARK: - Private

    private let asrModelId = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    private var asr: ASRClient?
    private var vad: VADSegmenter?
    private var backend: (any TranslationBackend)?
    private var audioSource: AudioSource?
    private var eventLoopTask: Task<Void, Never>?
    private var finalsWorkerTask: Task<Void, Never>?
    private var finalsQueue: FinalUtteranceQueue?
    private var partialPipe: PartialPipelineUI?
    /// Engine-owned rolling few-shot context (recent source → translation
    /// pairs). Lives here — not on the backends — so it survives backend
    /// reloads and every backend gets identical context behavior.
    private let translationContext = TranslationContext()

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
        let backendKind = prefs.llmBackend
        let rapidMLXURL = prefs.rapidMLXURL
        let rapidMLXModel = prefs.rapidMLXModel

        do {
            async let vadTask = VADSegmenter.load()
            async let asrTask = ASRClient.load(modelId: asrModel, language: asrLang)
            let backendTask = Task<any TranslationBackend, Error> {
                switch backendKind {
                case .mlxSwift:
                    return try await MLXChatTranslator.load(
                        modelId: modelId,
                        targetLanguage: target,
                        onProgress: { fraction, desc in
                            Task { @MainActor [weak self] in
                                let label = desc.isEmpty ? "Downloading translator…" : desc
                                self?.phase = .loading(status: label, progress: fraction)
                            }
                        }
                    )
                case .rapidMLX:
                    return try await RapidMLXTranslator.load(
                        baseURL: rapidMLXURL,
                        model: rapidMLXModel,
                        targetLanguage: target
                    )
                }
            }

            if backendKind == .rapidMLX {
                phase = .loading(status: "Connecting Rapid-MLX…", progress: 0.2)
            }

            self.vad = try await vadTask
            phase = .loading(status: "Loading ASR…", progress: 0.33)
            self.asr = try await asrTask
            switch backendKind {
            case .mlxSwift:
                phase = .loading(status: "Loading translator…", progress: 0.66)
            case .rapidMLX:
                phase = .loading(status: "Warming Rapid-MLX…", progress: 0.66)
            }
            self.backend = try await backendTask.value

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
        // Rolling few-shot context holds translations in the OLD language —
        // poisonous as examples for the new one.
        translationContext.reset()
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
        droppedUtteranceCount = 0
        // Each listening session is a fresh conversation — stale exchanges
        // from hours ago would bias terminology and register.
        translationContext.reset()

        // Snapshot user-tunable VAD thresholds from Preferences at start()
        // time so the slider in Preferences actually takes effect — new
        // values apply at the next Start Listening.
        let prefStart = Float(Preferences.shared.vadThreshold)
        let prefStop = max(0.0, prefStart - Config.vadHysteresis)
        let prefEndSilenceMs = Preferences.shared.speechEndMs

        let queue = FinalUtteranceQueue()
        self.finalsQueue = queue

        // Dispatch loop: consumes VAD events WITHOUT blocking on inference, so
        // the event buffer can never back up into shedding. Finals are handed
        // to the worker below; a slow translation no longer stalls VAD.
        eventLoopTask = Task.detached { [weak self, vad, source] in
            let audioStream = source.stream()
            let events = vad.events(
                from: audioStream,
                startThreshold: prefStart,
                stopThreshold: prefStop,
                endSilenceMs: prefEndSilenceMs
            )

            for await event in events {
                guard let self else { break }
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
                    // Freeze now (fast — just a flag) so a stale partial of
                    // THIS utterance can't paint over the final's stream;
                    // the worker waits for in-flight partial work before
                    // touching the GPU.
                    await pipe.freeze()
                    let shed = await queue.enqueue(audio)
                    if shed {
                        FileHandle.standardError.write(
                            "[engine] shed utterance under overload\n".data(using: .utf8) ?? Data()
                        )
                        await MainActor.run {
                            // Ignore a lame-duck loop from a previous session.
                            guard self.finalsQueue === queue else { return }
                            self.droppedUtteranceCount += 1
                        }
                    }
                }
            }
            await queue.finish()
        }

        // Finals worker: serially runs ASR + streamed translation per
        // utterance, decoupled from VAD event consumption.
        finalsWorkerTask = Task.detached { [weak self, asr, backend] in
            while let audio = await queue.dequeue() {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.processFinal(
                    audio: audio,
                    pipe: pipe,
                    asr: asr,
                    backend: backend
                )
                // Unfreeze partials only once the backlog is drained — while
                // more finals are queued, next-utterance partials would paint
                // out-of-order content over committed translations. The
                // generation token makes a raced reset a no-op: if a new
                // final freezes between our depth check and the reset, the
                // generations no longer match.
                let generation = await pipe.generation
                if await queue.depth == 0 {
                    await pipe.reset(ifGeneration: generation)
                }
            }
        }
    }

    /// One final utterance: ASR → commit source text → streamed translation →
    /// transcript history. Runs on the finals worker, never on the dispatch loop.
    nonisolated private func processFinal(
        audio: [Float],
        pipe: PartialPipelineUI,
        asr: ASRClient,
        backend: any TranslationBackend
    ) async {
        let segmentStart = Date()
        // The dispatch loop froze the pipe (discarding this utterance's stale
        // snapshot) at enqueue time; re-freezing here is an idempotent guard
        // against the small window where the worker's drain-time reset raced
        // a newly arriving final — WITHOUT discarding a pending snapshot,
        // which by now belongs to the next utterance. Then wait out any
        // in-flight partial ASR/translate so the final doesn't contend for
        // the GPU.
        await pipe.freeze(discardPending: false)
        await pipe.awaitQuiescence()

        let text = await asr.transcribe(audio)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            return
        }

        let targetAtStart = await MainActor.run { Preferences.shared.targetLanguage }

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
        do {
            for try await chunk in backend.translateStream(text, history: translationContext.snapshot()) {
                fullTranslation += chunk
                let snapshot = fullTranslation
                await MainActor.run {
                    // Each chunk replaces the old partial text directly —
                    // no empty intermediate state.
                    self.translationText = snapshot
                }
            }
        } catch {
            // A failed stream must not commit its truncated prefix to the
            // transcript or to the rolling context (mirrors main.py).
            if !(error is CancellationError) {
                await MainActor.run {
                    self.translationText = "[translate error: \(error)]"
                }
            }
            return
        }
        // Consumer-side cancellation (stop/reload mid-stream) ends the
        // iteration WITHOUT throwing — don't commit the half translation.
        if Task.isCancelled {
            return
        }

        let finalTranslation = fullTranslation
        let finalSource = text
        if !finalTranslation.isEmpty {
            let endedAt = Date()
            await MainActor.run {
                // Barge-in may have marked the card stale mid-stream; the
                // completed final is committed content, restyle it as such.
                self.translationText = finalTranslation
                self.isPartial = false
                // Feed the committed pair back as rolling few-shot context so
                // the next segment keeps pronouns/terminology consistent —
                // unless the target language changed while we streamed, in
                // which case this pair is in the wrong language.
                if Preferences.shared.targetLanguage == targetAtStart {
                    self.translationContext.note(source: finalSource, translation: finalTranslation)
                }
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
    }

    func stop() {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        // dequeue() is cancellation-aware, so cancel() alone releases a
        // suspended worker; the dispatch loop's queue.finish() on exit covers
        // the end-of-stream path.
        finalsWorkerTask?.cancel()
        finalsWorkerTask = nil
        finalsQueue = nil
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
