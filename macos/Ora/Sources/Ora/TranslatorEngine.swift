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
    var liveSource = LiveSourceText()
    var previousTranslation = ""
    var isCaptionPreview = false
    let captions = CaptionPresenter()
    var sessionNotice: SessionNotice?
    var recognizedUtteranceID: UUID? { displayedUtteranceID }
    var utteranceCount: Int = 0
    /// Utterances shed because ASR+translation fell behind sustained speech.
    /// Nonzero means the user lost sentences — surfaced, never silent.
    var droppedUtteranceCount: Int = 0
    /// A completed capture may still contain an untranslated utterance.
    /// Keep this observable instead of treating an empty history as success.
    private(set) var lastTranslationError: String?

    // MARK: - Config shortcut (read-only)

    /// Pulled from Preferences at prepare time; exposed so SwiftUI views can
    /// observe and display without binding to Preferences directly.
    var targetLanguage: String { targetLanguageOverride ?? Preferences.shared.targetLanguage }
    var quality: TranslatorQuality { Preferences.shared.quality }
    var llmBackend: LLMBackendKind { Preferences.shared.llmBackend }

    // MARK: - Private

    private let asrModelId = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    private var asr: (any SpeechRecognitionBackend)?
    private var vad: VADSegmenter?
    private var backend: (any TranslationBackend)?
    private var audioSource: AudioSource?
    private var activeAudioSourceKind: AudioSourceKind?
    private var eventLoopTask: Task<Void, Never>?
    private var finalsWorkerTask: Task<Void, Never>?
    private var finalsQueue: FinalUtteranceQueue?
    private var partialPipe: PartialPipelineUI?
    private var speechAssembly: SpeechAssemblyCoordinator?
    private var displayedUtteranceID: UUID?
    private var latestTranslationID: UUID?
    @ObservationIgnored private var streamedTranslation: (id: UUID, text: String)?
    private var listeningSession = UUID()
    private var activeSession: ListeningSession?
    private var receiptGeneration = UUID()
    private let historyOverride: TranscriptHistory?
    private let targetLanguageOverride: String?
    private let timing: PipelineTiming?
    private var history: TranscriptHistory { historyOverride ?? .shared }
    /// Engine-owned rolling few-shot context (recent source → translation
    /// pairs). Lives here — not on the backends — so it survives backend
    /// reloads and every backend gets identical context behavior.
    private let translationContext = TranslationContext()

    nonisolated init(history: TranscriptHistory? = nil) {
        self.historyOverride = history
        self.targetLanguageOverride = nil
        self.timing = nil
    }

    /// Inject ready components for deterministic pipeline replays without
    /// model downloads or microphone/system capture.
    init(history: TranscriptHistory, recognizer: any SpeechRecognitionBackend,
         translator: any TranslationBackend, segmenter: VADSegmenter, targetLanguage: String? = nil,
         timing: PipelineTiming? = nil) {
        self.historyOverride = history
        self.targetLanguageOverride = targetLanguage
        self.timing = timing
        self.asr = recognizer
        self.backend = translator
        self.vad = segmenter
        self.phase = .ready
    }

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
        let recognitionKind = prefs.recognitionBackend
        let rapidMLXURL = prefs.rapidMLXURL
        let rapidMLXModel = prefs.rapidMLXModel
        let realRouterURL = prefs.realRouterURL
        let realRouterModel = prefs.realRouterModel

        do {
            let apiKey = (backendKind == .realRouter || recognitionKind == .realRouter)
                ? try RealRouterCredentials.load() : ""
            async let vadTask = VADSegmenter.load()
            async let asrTask: any SpeechRecognitionBackend = Self.loadRecognizer(
                kind: recognitionKind, modelId: asrModel, language: asrLang,
                baseURL: realRouterURL, apiKey: apiKey
            )
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
                case .realRouter:
                    return try await RealRouterTranslator.load(
                        baseURL: realRouterURL, model: realRouterModel,
                        apiKey: apiKey, targetLanguage: target
                    )
                }
            }

            if backendKind == .rapidMLX {
                phase = .loading(status: "Connecting Rapid-MLX…", progress: 0.2)
            }

            self.vad = try await vadTask
            phase = .loading(status: recognitionKind == .realRouter ? "Connecting speech API…" : "Loading ASR…", progress: 0.33)
            self.asr = try await asrTask
            switch backendKind {
            case .mlxSwift:
                phase = .loading(status: "Loading translator…", progress: 0.66)
            case .rapidMLX:
                phase = .loading(status: "Warming Rapid-MLX…", progress: 0.66)
            case .realRouter:
                phase = .loading(status: "Connecting RealRouter…", progress: 0.66)
            }
            self.backend = try await backendTask.value

            phase = .ready
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    nonisolated private static func loadRecognizer(kind: RecognitionBackendKind, modelId: String,
                                                   language: String?, baseURL: String,
                                                   apiKey: String) async throws -> any SpeechRecognitionBackend {
        switch kind {
        case .local: return try await ASRClient.load(modelId: modelId, language: language)
        case .nemotron: return try await NemotronASRClient.load()
        case .appleSpeech:
            guard #available(macOS 26.0, *) else {
                throw APILocalBenchmark.BenchmarkError.configuration("Apple streaming recognition requires macOS 26 or later.")
            }
            return try await AppleSpeechASRClient.load()
        case .realRouter:
            let recognizer = try RealRouterSpeechRecognizer(baseURL: baseURL, apiKey: apiKey, language: language)
            try await recognizer.checkServer()
            return recognizer
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

    /// Await a finite injected audio source and every final it produced. Live
    /// capture sources remain open until stopped; replay tools use this to
    /// avoid mistaking a temporary gap in captions for completed inference.
    func waitForInputCompletion() async {
        let dispatch = eventLoopTask, worker = finalsWorkerTask
        await dispatch?.value
        await worker?.value
    }

    func start(sourceOverride: (any AudioSource)? = nil) async {
        guard case .ready = phase else { return }
        guard activeSession == nil else { return }
        guard let vad, let asr, let backend else { return }
        clearCaptionDisplay()
        sessionNotice = nil
        receiptGeneration = UUID()
        let session = UUID()
        listeningSession = session

        let source: AudioSource?
        let sourceKind = Preferences.shared.audioSource
        if let sourceOverride {
            source = sourceOverride
        } else {
            do {
                switch sourceKind {
                case .microphone:
                    source = MicrophoneCapture()
                case .systemAudio, .meeting:
                    source = try await SystemAudioCapture.create(includeMicrophone: sourceKind == .meeting) { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self, self.listeningSession == session else { return }
                            self.stop()
                            self.phase = .error(message)
                        }
                    }
                }
            } catch {
                guard listeningSession == session, phase == .ready else { return }
                phase = .error(error.localizedDescription)
                return
            }
        }
        guard listeningSession == session, phase == .ready else { return }
        guard let source else {
            phase = .error("Failed to initialize audio capture.")
            return
        }
        self.audioSource = source
        self.activeAudioSourceKind = sourceKind

        activeSession = ListeningSession(id: session)
        history.beginSession(id: session)
        let recognitionSnapshot = SpeechRecognitionSnapshot(acceptsUnpunctuatedEnd: asr.isStreaming)
        let pipe = PartialPipelineUI(asr: asr, backend: backend, context: translationContext,
                                     recognitionSnapshot: recognitionSnapshot, timing: timing,
                                     drawPreview: { [weak self] src, translated, id in
            await MainActor.run { [weak self] in
                guard let self, self.listeningSession == session, self.phase == .listening else { return }
                // In-flight tokens are display-only. Stop/failure must not
                // persist a generated prefix or feed it into future prompts.
                if let translated { self.streamedTranslation = (id, translated) }
                self.captions.update(id: id, source: src, translation: translated)
            }
        }) { [weak self] src, translated, id in
            await MainActor.run { [weak self] in
                guard let self, self.listeningSession == session,
                      self.phase == .listening else { return }
                if translated == nil {
                    if self.displayedUtteranceID != id {
                        self.liveSource = LiveSourceText()
                    }
                    self.liveSource.update(src)
                    self.displayedUtteranceID = id
                }
                self.sourceText = src
                if let translated {
                    self.translationText = translated
                    self.latestTranslationID = id
                    self.streamedTranslation = (id, translated)
                    self.lastTranslationError = nil
                }
                self.isPartial = true
                self.captions.update(id: id, source: src,
                                     translation: translated == nil ? nil : self.translationText)
                self.notePendingTranscript(id: id, source: src,
                                           translation: translated == nil ? nil : self.translationText)
            }
        }
        await pipe.start()
        guard listeningSession == session else {
            await pipe.shutdown()
            return
        }
        self.partialPipe = pipe

        phase = .listening
        sourceText = ""
        translationText = ""
        isPartial = false
        liveSource = LiveSourceText()
        previousTranslation = ""
        displayedUtteranceID = nil
        latestTranslationID = nil
        streamedTranslation = nil
        droppedUtteranceCount = 0
        lastTranslationError = nil
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
        let assembly = SpeechAssemblyCoordinator(recognition: recognitionSnapshot,
            previewAtPause: asr.partialPolicy.minimumSamples == 0, timing: timing) { [weak self] emission in
            if let preview = emission.preview {
                await pipe.submit(preview.audio, id: preview.id, overlapSource: preview.overlapSource)
            } else if let final = emission.finalized {
                self?.timing?.note("final_queued", id: final.id, samples: final.audio.count)
                let knownSource = asr.isStreaming ? nil : final.sourceOverride
                    ?? recognitionSnapshot.transcript(id: final.id, samples: final.audio.count)
                await pipe.freeze(finalID: final.id, finalSource: knownSource)
                let shed = await queue.enqueue(final.audio, id: final.id,
                    sourceOverride: final.sourceOverride, overlapSource: final.overlapSource)
                if shed {
                    let droppedID = await queue.lastDroppedID
                    await MainActor.run { [weak self] in
                        guard let self, self.listeningSession == session else { return }
                        self.droppedUtteranceCount += 1
                        if let droppedID { self.captions.finish(id: droppedID) }
                    }
                }
            }
        }
        self.speechAssembly = assembly

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
                guard self != nil, !Task.isCancelled else { break }
                await assembly.receive(event)
            }
            if Task.isCancelled { await assembly.cancel() }
            else { await assembly.finish() }
            await queue.finish()
        }

        // Finals worker: serially runs ASR + streamed translation per
        // utterance, decoupled from VAD event consumption.
        finalsWorkerTask = Task.detached { [weak self, asr, backend] in
            while let utterance = await queue.dequeueUtterance() {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.processFinal(
                    audio: utterance.audio,
                    utteranceID: utterance.id,
                    queuedAt: utterance.queuedAt,
                    sourceOverride: utterance.sourceOverride,
                    overlapSource: utterance.overlapSource,
                    recognition: recognitionSnapshot,
                    pipe: pipe,
                    asr: asr,
                    backend: backend,
                    session: session
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
        utteranceID: UUID,
        queuedAt: ContinuousClock.Instant,
        sourceOverride: String? = nil,
        overlapSource: String? = nil,
        recognition: SpeechRecognitionSnapshot,
        pipe: PartialPipelineUI,
        asr: any SpeechRecognitionBackend,
        backend: any TranslationBackend,
        session: UUID
    ) async {
        let segmentStart = Date()
        let processingStart = ContinuousClock.now
        let span = UUID()
        timing?.note("final_start", id: utteranceID, span: span, path: "final", samples: audio.count,
                     durationMS: PipelineTiming.ms(queuedAt))
        // The dispatch loop froze the pipe (discarding this utterance's stale
        // snapshot) at enqueue time; re-freezing here is an idempotent guard
        // against the small window where the worker's drain-time reset raced
        // a newly arriving final — WITHOUT discarding a pending snapshot,
        // which by now belongs to the next utterance. Then wait out any
        // in-flight partial ASR/translate so the final doesn't contend for
        // the GPU.
        let knownSource = asr.isStreaming ? nil : sourceOverride
            ?? recognition.transcript(id: utteranceID, samples: audio.count)
        await pipe.freeze(discardPending: false, finalID: utteranceID, finalSource: knownSource)
        await pipe.awaitQuiescence()
        timing?.note("final_quiescent", id: utteranceID, span: span, path: "final",
                     durationMS: PipelineTiming.ms(processingStart))
        guard !Task.isCancelled else { return }

        let asrStart = ContinuousClock.now
        timing?.note("asr_start", id: utteranceID, span: span, path: "final", samples: audio.count)
        let text: String
        do {
            if let sourceOverride, !asr.isStreaming { text = sourceOverride }
            else if !asr.isStreaming, let cached = recognition.transcript(id: utteranceID, samples: audio.count) { text = cached }
            else { text = TranscriptOverlap.strip(try await asr.transcribe(audio, id: utteranceID, final: true), previous: overlapSource) }
        }
        catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.listeningSession == session else { return }
                // Do not silently discard speech or keep uploading after an
                // authentication/network failure. stop() saves recognized
                // unfinished text and cancels every outstanding request.
                self.stop()
                self.phase = .error("Speech recognition failed: \(error.localizedDescription)")
            }
            return
        }
        let asrDone = ContinuousClock.now
        timing?.note("asr_end", id: utteranceID, span: span, path: "final", samples: audio.count,
                     text: text, durationMS: PipelineTiming.ms(asrStart),
                     reason: sourceOverride != nil ? "override" : recognition.transcript(id: utteranceID, samples: audio.count) == text && !asr.isStreaming ? "cached" : "inference")
        guard !Task.isCancelled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            await MainActor.run {
                guard self.listeningSession == session else { return }
                self.captions.finish(id: utteranceID)
            }
            return
        }

        let targetAtStart = await MainActor.run { self.targetLanguage }

        // Commit the final ASR source text, but DO NOT clear
        // translationText — that would flash the card to an
        // empty / placeholder state for ~300ms before the LLM's
        // first token arrives. The completed response replaces
        // the previous draft atomically.
        await MainActor.run {
            guard self.listeningSession == session else { return }
            self.sourceText = text
            self.liveSource.commit(text)
            self.utteranceCount += 1
            self.isPartial = false
            self.displayedUtteranceID = utteranceID
            self.captions.update(id: utteranceID, source: text, translation: nil)
            self.notePendingTranscript(id: utteranceID, source: text, translation: nil)
        }

        var fullTranslation = await pipe.completedTranslation(id: utteranceID, source: text) ?? ""
        var finalContext = translationContext.snapshot()
        let draft = await pipe.completedDraft(id: utteranceID)
        if let draft { finalContext.append(draft) }
        // An unchanged, confirmed sentence prefix has already been translated
        // and read. Translate only the remaining speech instead of asking the
        // model to paraphrase the entire utterance and replay its old pages.
        var pendingSource = text
        var confirmedTranslation = ""
        if fullTranslation.isEmpty, let draft,
           let remainder = RecognitionTextAgreement.remainder(after: draft.source, in: text, ignoresSegmentation: false) {
            if !remainder.isEmpty {
                pendingSource = remainder
                confirmedTranslation = draft.translation
            }
        }
        var firstTokenAt: ContinuousClock.Instant?
        let visibleBeforeRequest = await MainActor.run {
            if self.streamedTranslation?.id == utteranceID { return self.streamedTranslation?.text ?? "" }
            return self.latestTranslationID == utteranceID && self.lastTranslationError == nil ? self.translationText : ""
        }
        var display = TranslationStreamDisplay(prefix: confirmedTranslation, previousText: visibleBeforeRequest)
        let translationStarted = ContinuousClock.now
        let fallbackTranslation = confirmedTranslation
        do {
            if fullTranslation.isEmpty {
                timing?.note("translation_start", id: utteranceID, span: span, path: "final", text: pendingSource)
                for try await chunk in backend.translateStream(pendingSource, history: finalContext) {
                    if firstTokenAt == nil, !chunk.isEmpty {
                        firstTokenAt = .now
                        timing?.note("translation_first_token", id: utteranceID, span: span, path: "final")
                    }
                    fullTranslation += chunk
                    try Task.checkCancellation()
                    guard await MainActor.run(body: {
                        self.listeningSession == session && self.targetLanguage == targetAtStart
                    }) else { return }
                    if let visible = display.append(chunk, elapsedMS: PipelineTiming.ms(translationStarted)) {
                        timing?.note("translation_preview", id: utteranceID, span: span, path: "final", text: visible)
                        await MainActor.run {
                            guard self.listeningSession == session, self.phase == .listening,
                                  self.targetLanguage == targetAtStart else { return }
                            self.streamedTranslation = (utteranceID, visible)
                            self.captions.update(id: utteranceID, source: text, translation: visible)
                        }
                    }
                }
            }
            guard !fullTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RealRouterError.emptyResponse
            }
            if !confirmedTranslation.isEmpty {
                let separator = fullTranslation.first?.isASCII == true || confirmedTranslation.last?.isASCII == true ? " " : ""
                fullTranslation = confirmedTranslation + separator + fullTranslation
            }
        } catch {
            // A failed stream must not commit its truncated prefix to the
            // transcript or to the rolling context (mirrors main.py).
            if !(error is CancellationError) {
                await MainActor.run {
                    guard self.listeningSession == session else { return }
                    self.translationText = "[translate error: \(error.localizedDescription)]"
                    self.streamedTranslation = nil
                    if self.llmBackend == .rapidMLX, let connection = error as? URLError,
                       [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(connection.code) {
                        self.lastTranslationError = "Cannot reach Rapid-MLX at \(Preferences.shared.rapidMLXURL). Start the local server, then reconnect."
                    } else {
                        self.lastTranslationError = error.localizedDescription
                    }
                    // Keep all recognized words available for reading even
                    // when this utterance's translation fails.
                    self.captions.update(id: utteranceID, source: text, translation: fallbackTranslation, final: true)
                    self.history.append(TranscriptEntry(id: UUID(), startedAt: segmentStart, endedAt: Date(),
                        sourceText: text, translationText: "", sourceLanguageHint: Preferences.shared.asrLanguage,
                        targetLanguage: targetAtStart,
                        audioSource: (self.activeAudioSourceKind ?? Preferences.shared.audioSource).rawValue,
                        sessionId: session, isPartial: true))
                    self.activeSession?.committed(utteranceID: utteranceID)
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
        timing?.note("translation_end", id: utteranceID, span: span, path: "final", text: fullTranslation,
                     reason: firstTokenAt == nil ? "reused" : "completed")
        let finalSource = text
        if !finalTranslation.isEmpty {
            let endedAt = Date()
            await MainActor.run {
                guard self.listeningSession == session else { return }
                // Barge-in may have marked the card stale mid-stream; the
                // completed final is committed content, restyle it as such.
                self.translationText = finalTranslation
                self.streamedTranslation = (utteranceID, finalTranslation)
                self.latestTranslationID = utteranceID
                self.lastTranslationError = nil
                self.isPartial = false
                self.previousTranslation = finalTranslation
                self.captions.update(id: utteranceID, source: finalSource, translation: finalTranslation, final: true)
                // Feed the committed pair back as rolling few-shot context so
                // the next segment keeps pronouns/terminology consistent —
                // unless the target language changed while we streamed, in
                // which case this pair is in the wrong language.
                if self.targetLanguage == targetAtStart {
                    self.translationContext.note(source: finalSource, translation: finalTranslation)
                }
                let entry = TranscriptEntry(
                    id: UUID(),
                    startedAt: segmentStart,
                    endedAt: endedAt,
                    sourceText: finalSource,
                    translationText: finalTranslation,
                    sourceLanguageHint: Preferences.shared.asrLanguage,
                    targetLanguage: self.targetLanguage,
                    audioSource: (self.activeAudioSourceKind ?? Preferences.shared.audioSource).rawValue,
                    sessionId: session
                )
                self.history.append(entry)
                self.activeSession?.committed(utteranceID: utteranceID)
            }
        } else {
            await MainActor.run {
                guard self.listeningSession == session else { return }
                self.captions.update(id: utteranceID, source: text, translation: nil, final: true)
            }
        }
        func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
            let d = from.duration(to: to).components
            return Int(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }
        // Timing only: no speech or translation text is written to this log.
        let report = "[pipeline-latency] queue_ms=\(ms(queuedAt, processingStart)) partial_wait_ms=\(ms(processingStart, asrStart)) asr_ms=\(ms(asrStart, asrDone)) first_token_ms=\(firstTokenAt.map { ms(asrDone, $0) } ?? -1) final_total_ms=\(ms(queuedAt, .now))\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    func stop() {
        let session = activeSession
        activeSession = nil
        let stoppedToken = UUID()
        listeningSession = stoppedToken
        clearCaptionDisplay()
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
        let assembly = speechAssembly
        speechAssembly = nil
        Task { await assembly?.cancel() }
        audioSource = nil
        activeAudioSourceKind = nil
        if case .listening = phase {
            phase = .ready
        }
        guard let session else { return }
        let receipt = UUID()
        receiptGeneration = receipt
        let endedAt = Date()
        let elapsed = session.clockStart.duration(to: .now).components
        let duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let unfinished = session.unfinishedEntry(endedAt: endedAt)
        let history = self.history
        if let unfinished { history.append(unfinished) }
        let summary = SessionSummary(id: session.id, duration: duration,
                                     savedLines: session.completedCount + (unfinished == nil ? 0 : 1),
                                     unfinishedLines: unfinished == nil ? 0 : 1)
        guard summary.savedLines > 0 else {
            sessionNotice = .empty(summary)
            return
        }
        sessionNotice = .saving(summary)
        Task { [weak self, history] in
            do {
                try await history.flush(sessionID: session.id)
                guard let self, self.receiptGeneration == receipt else { return }
                self.sessionNotice = .saved(summary)
            } catch {
                guard let self, self.receiptGeneration == receipt else { return }
                self.sessionNotice = .failed(summary, error.localizedDescription)
            }
        }
    }

    private func notePendingTranscript(id: UUID, source: String, translation: String?) {
        let prefs = Preferences.shared
        activeSession?.update(utteranceID: id, source: source, translation: translation,
                              target: targetLanguage, sourceLanguage: prefs.asrLanguage,
                              audioSource: (activeAudioSourceKind ?? prefs.audioSource).rawValue)
    }

    private func clearCaptionDisplay() {
        captions.reset()
        sourceText = ""
        translationText = ""
        previousTranslation = ""
        liveSource = LiveSourceText()
        isPartial = false
        displayedUtteranceID = nil
        latestTranslationID = nil
        streamedTranslation = nil
        droppedUtteranceCount = 0
    }

    func toggle() {
        guard !isCaptionPreview else { return }
        if activeSession != nil {
            stop()
            return
        }
        if phase != .listening {
            // A button/hotkey press clears immediately, including while the
            // next start is waiting for model loading or audio permission.
            clearCaptionDisplay()
            sessionNotice = nil
            receiptGeneration = UUID()
            listeningSession = UUID() // invalidate an earlier save receipt immediately
        }
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
