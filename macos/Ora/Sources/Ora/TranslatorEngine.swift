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
    private var activeAudioSourceKind: AudioSourceKind?
    private var eventLoopTask: Task<Void, Never>?
    private var finalsWorkerTask: Task<Void, Never>?
    private var finalsQueue: FinalUtteranceQueue?
    private var partialPipe: PartialPipelineUI?
    private var partialRevision = CaptionRevision(previous: "")
    private var displayedUtteranceID: UUID?
    private var latestTranslationID: UUID?
    private var listeningSession = UUID()
    private var activeSession: ListeningSession?
    private var receiptGeneration = UUID()
    private let historyOverride: TranscriptHistory?
    private var history: TranscriptHistory { historyOverride ?? .shared }
    /// Engine-owned rolling few-shot context (recent source → translation
    /// pairs). Lives here — not on the backends — so it survives backend
    /// reloads and every backend gets identical context behavior.
    private let translationContext = TranslationContext()

    nonisolated init(history: TranscriptHistory? = nil) { self.historyOverride = history }

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
        let pipe = PartialPipelineUI(asr: asr, backend: backend, context: translationContext) { [weak self] src, translated, id in
            await MainActor.run { [weak self] in
                guard let self, self.listeningSession == session,
                      self.phase == .listening else { return }
                if translated == nil {
                    if self.displayedUtteranceID != id {
                        self.liveSource = LiveSourceText()
                    }
                    self.partialRevision = CaptionRevision(previous: self.latestTranslationID == id ? self.translationText : "")
                    self.liveSource.update(src)
                    self.displayedUtteranceID = id
                }
                self.sourceText = src
                if let translated {
                    self.translationText = self.partialRevision.update(translated)
                    self.latestTranslationID = id
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

            var utteranceID = UUID()
            for await event in events {
                guard let self else { break }
                switch event {
                case .speechStart:
                    // Keep the last readable caption until recognition
                    // arrives. A new utterance starts with isPartial=false,
                    // so its first token won't wait to catch up to the length
                    // of the previous sentence.
                    utteranceID = UUID()

                case .partial(let audio):
                    await pipe.submit(audio, id: utteranceID)

                case .final(let audio):
                    // Freeze now (fast — just a flag) so a stale partial of
                    // THIS utterance can't paint over the final's stream;
                    // the worker waits for in-flight partial work before
                    // touching the GPU.
                    await pipe.freeze()
                    let shed = await queue.enqueue(audio, id: utteranceID)
                    if shed {
                        let droppedID = await queue.lastDroppedID
                        FileHandle.standardError.write(
                            "[engine] shed utterance under overload\n".data(using: .utf8) ?? Data()
                        )
                        await MainActor.run {
                            // Ignore a lame-duck loop from a previous session.
                            guard self.finalsQueue === queue else { return }
                            self.droppedUtteranceCount += 1
                            if let droppedID { self.captions.finish(id: droppedID) }
                        }
                    }
                }
            }
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
        pipe: PartialPipelineUI,
        asr: ASRClient,
        backend: any TranslationBackend,
        session: UUID
    ) async {
        let segmentStart = Date()
        let processingStart = ContinuousClock.now
        // The dispatch loop froze the pipe (discarding this utterance's stale
        // snapshot) at enqueue time; re-freezing here is an idempotent guard
        // against the small window where the worker's drain-time reset raced
        // a newly arriving final — WITHOUT discarding a pending snapshot,
        // which by now belongs to the next utterance. Then wait out any
        // in-flight partial ASR/translate so the final doesn't contend for
        // the GPU.
        await pipe.freeze(discardPending: false)
        await pipe.awaitQuiescence()
        guard !Task.isCancelled else { return }

        let asrStart = ContinuousClock.now
        let text = await asr.transcribe(audio)
        let asrDone = ContinuousClock.now
        guard !Task.isCancelled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            await MainActor.run {
                guard self.listeningSession == session else { return }
                self.captions.finish(id: utteranceID)
            }
            return
        }

        let targetAtStart = await MainActor.run { Preferences.shared.targetLanguage }

        // Commit the final ASR source text, but DO NOT clear
        // translationText — that would flash the card to an
        // empty / placeholder state for ~300ms before the LLM's
        // first token arrives. We let the incoming stream
        // replace the previous partial translation atomically.
        var revision = await MainActor.run {
            let revision = CaptionRevision(previous: self.latestTranslationID == utteranceID ? self.translationText : "")
            guard self.listeningSession == session else { return revision }
            self.sourceText = text
            self.liveSource.commit(text)
            self.utteranceCount += 1
            self.isPartial = false
            self.displayedUtteranceID = utteranceID
            self.captions.update(id: utteranceID, source: text, translation: nil)
            self.notePendingTranscript(id: utteranceID, source: text, translation: nil)
            return revision
        }

        var fullTranslation = ""
        var firstTokenAt: ContinuousClock.Instant?
        do {
            for try await chunk in backend.translateStream(text, history: translationContext.snapshot()) {
                if firstTokenAt == nil, !chunk.isEmpty { firstTokenAt = .now }
                fullTranslation += chunk
                let snapshot = revision.update(fullTranslation)
                await MainActor.run {
                    guard self.listeningSession == session else { return }
                    // Each chunk replaces the old partial text directly —
                    // no empty intermediate state.
                    self.translationText = snapshot
                    self.latestTranslationID = utteranceID
                    self.captions.update(id: utteranceID, source: text, translation: snapshot)
                    self.notePendingTranscript(id: utteranceID, source: text, translation: snapshot)
                }
            }
        } catch {
            // A failed stream must not commit its truncated prefix to the
            // transcript or to the rolling context (mirrors main.py).
            if !(error is CancellationError) {
                await MainActor.run {
                    guard self.listeningSession == session else { return }
                    self.translationText = "[translate error: \(error)]"
                    // Keep all recognized words available for reading even
                    // when this utterance's translation fails.
                    self.captions.update(id: utteranceID, source: text, translation: nil, final: true)
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
                guard self.listeningSession == session else { return }
                // Barge-in may have marked the card stale mid-stream; the
                // completed final is committed content, restyle it as such.
                self.translationText = finalTranslation
                self.latestTranslationID = utteranceID
                self.isPartial = false
                self.previousTranslation = finalTranslation
                self.captions.update(id: utteranceID, source: finalSource, translation: finalTranslation, final: true)
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
                              target: prefs.targetLanguage, sourceLanguage: prefs.asrLanguage,
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
        partialRevision = CaptionRevision(previous: "")
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
