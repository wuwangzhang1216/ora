import Foundation

/// Background worker that processes the latest partial audio snapshot into a
/// non-streaming translation, then invokes a `drawPartial` closure with the
/// source text and translation. Drops stale work whenever a newer snapshot
/// arrives — mirrors the Python impl.
///
/// The UI-facing variant is aliased as `PartialPipelineUI` for clarity at
/// call sites in TranslatorEngine.
actor PartialPipeline {
    typealias DrawCallback = @Sendable (_ source: String, _ translated: String) -> Void

    private let asr: ASRClient
    private let backend: any TranslationBackend
    private let drawPartial: DrawCallback

    private var latest: [Float]?
    private var frozen = false
    private var lastText = ""
    private var workerTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var processing = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(asr: ASRClient, backend: any TranslationBackend, drawPartial: @escaping DrawCallback) {
        self.asr = asr
        self.backend = backend
        self.drawPartial = drawPartial
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
                await self.processOne()
            }
        }
    }

    func submit(_ audio: [Float]) {
        // While frozen this only stores the snapshot (it belongs to the next
        // utterance); reset() re-wakes the worker so it isn't lost.
        latest = audio
        if !frozen {
            wakeContinuation?.yield(())
        }
    }

    /// Stop accepting new partial work immediately. Any snapshot captured so
    /// far belongs to the utterance being finalized and is discarded; work
    /// already in flight keeps running — call `awaitQuiescence()` before
    /// competing for the GPU.
    func freeze() {
        frozen = true
        latest = nil
    }

    /// Wait until no partial ASR/translate is in flight. Separate from
    /// `freeze()` so the (fast) dispatch loop can freeze without blocking on
    /// seconds-long inference; only the finals worker pays the wait.
    func awaitQuiescence() async {
        while processing {
            await withCheckedContinuation { quiescenceWaiters.append($0) }
        }
    }

    func reset() {
        frozen = false
        lastText = ""
        // A snapshot submitted while frozen belongs to the next utterance —
        // resume it now instead of waiting for the next 0.6s partial tick.
        if latest != nil {
            wakeContinuation?.yield(())
        }
    }

    func shutdown() {
        wakeContinuation?.finish()
        workerTask?.cancel()
    }

    private func processOne() async {
        guard !frozen, let audio = latest else { return }
        latest = nil

        processing = true
        defer {
            processing = false
            let waiters = quiescenceWaiters
            quiescenceWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        let text = await asr.transcribe(audio)
        guard !frozen, !text.isEmpty, text != lastText else { return }
        lastText = text

        do {
            let translated = try await backend.translate(text)
            guard !frozen else { return }
            drawPartial(text, translated)
        } catch {
            // Silent failure for partials — next audio update will retry.
        }
    }
}

/// Alias used by TranslatorEngine so the UI vs CLI intent is explicit.
typealias PartialPipelineUI = PartialPipeline
