import Foundation

/// Serial worker for the latest audio snapshot. Recognition appears first;
/// agreed unfinished speech can produce revisable translation previews, while
/// completed units alone become reusable translation checkpoints.
///
/// The UI-facing variant is aliased as `PartialPipelineUI` for clarity at
/// call sites in TranslatorEngine.
actor PartialPipeline {
    // nil means recognition only; keep the last readable translation visible.
    typealias DrawCallback = @Sendable (_ source: String, _ translated: String?, _ utteranceID: UUID) async -> Void

    /// Cap on how long the finals worker will wait for in-flight partial
    /// inference — a hung partial (stalled server, runaway generation) must
    /// not stall final captions forever. Mirrors main.py's wait_quiescent.
    static let quiescenceTimeout: Duration = .seconds(10)

    private let transcribe: @Sendable ([Float], UUID) async throws -> String
    private let confirmedRecognition: Bool
    private var recognitionThrottle: RecognitionPartialThrottle
    private let backend: any TranslationBackend
    private let context: TranslationContext?
    private let recognitionSnapshot: SpeechRecognitionSnapshot?
    private let drawPartial: DrawCallback
    private let drawPreview: DrawCallback?
    private let timing: PipelineTiming?
    private var translationID: UUID?
    private var translationLanguage = ""
    private var stableTranslation = StableTranslation()

    private var latest: CapturedUtterance?
    private var frozen = false
    /// Bumped on every freeze. reset(ifGeneration:) uses it to no-op when a
    /// newer freeze (= a newer final) arrived after the caller decided to
    /// reset, so a late reset can never unfreeze someone else's freeze.
    private var freezeGeneration = 0
    private var workerTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var processing = false
    private var activeTranslation: (span: UUID, id: UUID, source: String, language: String, provisional: Bool)?
    private var joinedTranslation: UUID?
    private var lastPreviewAt: ContinuousClock.Instant?

    private final class QuiescenceWaiter {
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var quiescenceWaiters: [QuiescenceWaiter] = []

    init(asr: any SpeechRecognitionBackend, backend: any TranslationBackend, context: TranslationContext? = nil,
         recognitionSnapshot: SpeechRecognitionSnapshot? = nil, timing: PipelineTiming? = nil,
         drawPreview: DrawCallback? = nil,
         drawPartial: @escaping DrawCallback) {
        self.transcribe = { try await asr.transcribe($0, id: $1, final: false) }
        self.confirmedRecognition = asr.commitsPartialTokens
        self.recognitionThrottle = RecognitionPartialThrottle(policy: asr.partialPolicy)
        self.backend = backend
        self.context = context
        self.recognitionSnapshot = recognitionSnapshot
        self.drawPartial = drawPartial
        self.drawPreview = drawPreview
        self.timing = timing
    }

    /// Same pipeline with an injected recognizer for deterministic timing tests.
    init(transcribe: @escaping @Sendable ([Float]) async throws -> String,
         backend: any TranslationBackend, context: TranslationContext? = nil,
         recognitionSnapshot: SpeechRecognitionSnapshot? = nil,
         recognitionPolicy: RecognitionPartialPolicy = .local, drawPreview: DrawCallback? = nil,
         drawPartial: @escaping DrawCallback) {
        self.transcribe = { audio, _ in try await transcribe(audio) }
        self.confirmedRecognition = false
        self.recognitionThrottle = RecognitionPartialThrottle(policy: recognitionPolicy)
        self.backend = backend
        self.context = context
        self.recognitionSnapshot = recognitionSnapshot
        self.drawPartial = drawPartial
        self.drawPreview = drawPreview
        self.timing = nil
    }

    func start() {
        // Pure wake signal — processOne() always reads the latest snapshot, so
        // coalescing redundant wakeups to a single pending token is correct and
        // avoids spinning through stale signals when submits outpace the worker.
        let wake = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.wakeContinuation = continuation
        }
        workerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in wake {
                if Task.isCancelled { return }
                await self.runNext()
            }
        }
    }

    private func runNext() async {
        let task = Task { await self.processOne() }
        inferenceTask = task
        await task.value
        inferenceTask = nil
    }

    func submit(_ audio: [Float], id: UUID = UUID(), overlapSource: String? = nil) {
        // While frozen this only stores the snapshot (it belongs to the next
        // utterance); reset() re-wakes the worker so it isn't lost.
        latest = CapturedUtterance(id: id, audio: audio, overlapSource: overlapSource)
        timing?.note("partial_submitted", id: id, path: "partial", samples: audio.count,
                     reason: frozen ? "frozen" : "ready")
        if !frozen {
            wakeContinuation?.yield(())
        }
    }

    /// Stop accepting new partial work immediately (fast — just a flag).
    /// `discardPending` drops the stored snapshot: true at final-dispatch time
    /// (the snapshot belongs to the utterance being finalized), false for the
    /// worker's defensive re-freeze (the snapshot belongs to the NEXT
    /// utterance and must survive until reset re-wakes it).
    /// Returns the new freeze generation for use with reset(ifGeneration:).
    @discardableResult
    func freeze(discardPending: Bool = true, finalID: UUID? = nil, finalSource: String? = nil) -> Int {
        frozen = true
        if discardPending {
            latest = nil
        }
        freezeGeneration += 1
        // An exact final can use the request already generating its answer.
        // Never join a guessed prefix, a changed boundary, or another language.
        if let active = activeTranslation, let finalID, let finalSource,
           active.id == finalID, !active.provisional,
           active.language == backend.targetLanguage,
           RecognitionTextAgreement.equivalent(active.source, finalSource, ignoresSegmentation: false) {
            if joinedTranslation != active.span {
                timing?.note("translation_joined", id: finalID, span: active.span, path: "partial")
            }
            joinedTranslation = active.span
        } else {
            joinedTranslation = nil
            inferenceTask?.cancel()
        }
        return freezeGeneration
    }

    var generation: Int { freezeGeneration }

    func completedTranslation(id: UUID, source: String) -> String? {
        guard translationID == id, translationLanguage == backend.targetLanguage,
              let translated = stableTranslation.translation(for: source), !translated.isEmpty else { return nil }
        return translated
    }

    func completedDraft(id: UUID) -> TranslationExchange? {
        guard translationID == id, translationLanguage == backend.targetLanguage,
              !stableTranslation.source.isEmpty, !stableTranslation.published.isEmpty else { return nil }
        return TranslationExchange(source: stableTranslation.source, translation: stableTranslation.published)
    }

    /// Wait until no partial ASR/translate is in flight (bounded by
    /// `quiescenceTimeout`). Separate from `freeze()` so the (fast) dispatch
    /// loop never blocks on inference; only the finals worker pays the wait.
    func awaitQuiescence() async {
        let deadline = ContinuousClock.now + Self.quiescenceTimeout
        while processing {
            if ContinuousClock.now >= deadline { return }
            let waiter = QuiescenceWaiter()
            quiescenceWaiters.append(waiter)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiter.continuation = c
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    await self?.expire(waiter)
                }
            }
        }
    }

    /// Timeout path: release one waiter even though work is still in flight.
    private func expire(_ waiter: QuiescenceWaiter) {
        guard let c = waiter.continuation else { return }
        waiter.continuation = nil
        joinedTranslation = nil
        inferenceTask?.cancel()
        quiescenceWaiters.removeAll { $0 === waiter }
        c.resume()
    }

    /// Unfreeze — but only if no newer freeze happened since `expected` was
    /// observed. Re-wakes the worker if a next-utterance snapshot is pending.
    func reset(ifGeneration expected: Int) {
        guard freezeGeneration == expected else { return }
        frozen = false
        if latest != nil {
            wakeContinuation?.yield(())
        }
    }

    func shutdown() {
        frozen = true
        freezeGeneration += 1
        latest = nil
        joinedTranslation = nil
        inferenceTask?.cancel()
        wakeContinuation?.finish()
        workerTask?.cancel()
    }

    private func processOne() async {
        guard !frozen, let utterance = latest else { return }
        latest = nil
        guard recognitionThrottle.allow(id: utterance.id, sampleCount: utterance.audio.count) else { return }
        let generationAtStart = freezeGeneration
        let span = UUID()
        timing?.note("partial_start", id: utterance.id, span: span, path: "partial", samples: utterance.audio.count,
                     durationMS: PipelineTiming.ms(utterance.queuedAt))

        processing = true
        let startedAt = ContinuousClock.now
        var asrDoneAt: ContinuousClock.Instant?
        var firstTokenAt: ContinuousClock.Instant?
        var outcome = "superseded"
        defer {
            if activeTranslation?.span == span { activeTranslation = nil }
            if joinedTranslation == span { joinedTranslation = nil }
            timing?.note("partial_end", id: utterance.id, span: span, path: "partial",
                         durationMS: PipelineTiming.ms(startedAt), reason: Task.isCancelled ? "cancelled" : outcome)
            let endedAt = ContinuousClock.now
            func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
                let d = start.duration(to: end).components
                return Int(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
            }
            // Slow-path diagnostics only; never log recognized speech.
            if ms(startedAt, endedAt) >= 750 {
                let asrMS = asrDoneAt.map { ms(startedAt, $0) } ?? -1
                let firstMS = firstTokenAt.flatMap { first in asrDoneAt.map { ms($0, first) } } ?? -1
                let status = Task.isCancelled ? "cancelled" : outcome
                let report = "[partial-latency] asr_ms=\(asrMS) first_token_ms=\(firstMS) total_ms=\(ms(startedAt, endedAt)) status=\(status)\n"
                FileHandle.standardError.write(Data(report.utf8))
            }
            processing = false
            let waiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            for waiter in waiters {
                if let c = waiter.continuation {
                    waiter.continuation = nil
                    c.resume()
                }
            }
        }

        let text: String
        let recognitionStarted = ContinuousClock.now
        timing?.note("asr_start", id: utterance.id, span: span, path: "partial", samples: utterance.audio.count)
        do {
            if let cached = recognitionSnapshot?.transcript(id: utterance.id, samples: utterance.audio.count) {
                text = cached
            } else {
                text = TranscriptOverlap.strip(try await transcribe(utterance.audio, utterance.id), previous: utterance.overlapSource)
            }
        }
        catch {
            outcome = Task.isCancelled ? "cancelled" : "recognition_failed"
            return // final recognition reports failures; later partials remain rate-limited
        }
        asrDoneAt = .now
        timing?.note("asr_end", id: utterance.id, span: span, path: "partial", samples: utterance.audio.count,
                     text: text, durationMS: PipelineTiming.ms(recognitionStarted))
        // A synchronous ASR call may finish after finalization cancels the
        // preview. Retain its exact-audio result for the final worker, while
        // still rejecting stale UI/translation updates below.
        if !text.isEmpty {
            recognitionSnapshot?.note(id: utterance.id, samples: utterance.audio.count, text: text)
        }
        guard !Task.isCancelled, !frozen, freezeGeneration == generationAtStart,
              !text.isEmpty else { return }
        await drawPartial(text, nil, utterance.id)
        guard !Task.isCancelled, !frozen, freezeGeneration == generationAtStart else { return }
        if translationID != utterance.id || translationLanguage != backend.targetLanguage {
            translationID = utterance.id
            translationLanguage = backend.targetLanguage
            stableTranslation = StableTranslation()
            lastPreviewAt = nil
        }
        guard let plan = stableTranslation.plan(for: text, confirmed: confirmedRecognition, preview: true) else {
            timing?.note("translation_gate_hold", id: utterance.id, span: span, path: "partial", text: text,
                         reason: "agreement_or_boundary")
            outcome = "awaiting_stable_phrase"
            return
        }
        if plan.provisional, let lastPreviewAt, lastPreviewAt.duration(to: .now) < .milliseconds(700) {
            outcome = "coalesced_preview"
            return
        }
        var translationHistory = context?.snapshot() ?? []
        if let preceding = plan.preceding { translationHistory.append(preceding) }

        do {
            var translated = ""
            var display = TranslationStreamDisplay(prefix: plan.preceding?.translation ?? "",
                                                   previousText: stableTranslation.displayed)
            let language = backend.targetLanguage
            if plan.provisional { lastPreviewAt = .now }
            activeTranslation = (span, utterance.id, plan.source, backend.targetLanguage, plan.provisional)
            timing?.note("translation_start", id: utterance.id, span: span, path: "partial", text: plan.text,
                         reason: plan.provisional ? "preview" : "confirmed_unit")
            for try await chunk in backend.translateStream(plan.text, history: translationHistory) {
                guard !Task.isCancelled,
                      backend.targetLanguage == language,
                      joinedTranslation == span || (!frozen && freezeGeneration == generationAtStart) else { return }
                if firstTokenAt == nil, !chunk.isEmpty {
                    firstTokenAt = .now
                    timing?.note("translation_first_token", id: utterance.id, span: span, path: "partial")
                }
                translated += chunk
                if let visible = display.append(chunk, elapsedMS: PipelineTiming.ms(startedAt)), let drawPreview {
                    timing?.note("translation_preview", id: utterance.id, span: span, path: "partial", text: visible)
                    await drawPreview(text, visible, utterance.id)
                }
            }
            guard !Task.isCancelled,
                  backend.targetLanguage == language,
                  joinedTranslation == span || (!frozen && freezeGeneration == generationAtStart) else { return }
            if !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let stable = stableTranslation.commit(plan, translation: translated)
                timing?.note("translation_end", id: utterance.id, span: span, path: "partial", text: stable,
                             reason: "completed")
                if !plan.provisional {
                    recognitionSnapshot?.noteTranslation(id: utterance.id, source: plan.source)
                }
                if !frozen, freezeGeneration == generationAtStart {
                    await drawPartial(text, stable, utterance.id)
                }
            }
            outcome = "completed"
        } catch {
            outcome = "failed"
            if !frozen, freezeGeneration == generationAtStart {
                await drawPreview?(text, stableTranslation.displayed, utterance.id)
            }
            // A later source update can retry. Never checkpoint a failed stream.
        }
    }
}

/// Alias used by TranslatorEngine so the UI vs CLI intent is explicit.
typealias PartialPipelineUI = PartialPipeline
