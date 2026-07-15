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

    /// Cap on how long the finals worker will wait for in-flight partial
    /// inference — a hung partial (stalled server, runaway generation) must
    /// not stall final captions forever. Mirrors main.py's wait_quiescent.
    static let quiescenceTimeout: Duration = .seconds(10)

    private let asr: ASRClient
    private let backend: any TranslationBackend
    private let drawPartial: DrawCallback

    private var latest: [Float]?
    private var frozen = false
    /// Bumped on every freeze. reset(ifGeneration:) uses it to no-op when a
    /// newer freeze (= a newer final) arrived after the caller decided to
    /// reset, so a late reset can never unfreeze someone else's freeze.
    private var freezeGeneration = 0
    private var lastText = ""
    private var workerTask: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var processing = false

    private final class QuiescenceWaiter {
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var quiescenceWaiters: [QuiescenceWaiter] = []

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

    /// Stop accepting new partial work immediately (fast — just a flag).
    /// `discardPending` drops the stored snapshot: true at final-dispatch time
    /// (the snapshot belongs to the utterance being finalized), false for the
    /// worker's defensive re-freeze (the snapshot belongs to the NEXT
    /// utterance and must survive until reset re-wakes it).
    /// Returns the new freeze generation for use with reset(ifGeneration:).
    @discardableResult
    func freeze(discardPending: Bool = true) -> Int {
        frozen = true
        if discardPending {
            latest = nil
        }
        freezeGeneration += 1
        return freezeGeneration
    }

    var generation: Int { freezeGeneration }

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
        quiescenceWaiters.removeAll { $0 === waiter }
        c.resume()
    }

    /// Unfreeze — but only if no newer freeze happened since `expected` was
    /// observed. Re-wakes the worker if a next-utterance snapshot is pending.
    func reset(ifGeneration expected: Int) {
        guard freezeGeneration == expected else { return }
        frozen = false
        lastText = ""
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
            for waiter in waiters {
                if let c = waiter.continuation {
                    waiter.continuation = nil
                    c.resume()
                }
            }
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
