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

    init(asr: ASRClient, backend: any TranslationBackend, drawPartial: @escaping DrawCallback) {
        self.asr = asr
        self.backend = backend
        self.drawPartial = drawPartial
    }

    func start() {
        let wake = AsyncStream<Void> { continuation in
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
        latest = audio
        wakeContinuation?.yield(())
    }

    /// Stop accepting new partials and wait for any in-flight work to finish.
    func freeze() async {
        frozen = true
        await Task.yield()
    }

    func reset() {
        frozen = false
        lastText = ""
        latest = nil
    }

    func shutdown() {
        wakeContinuation?.finish()
        workerTask?.cancel()
    }

    private func processOne() async {
        guard !frozen, let audio = latest else { return }
        latest = nil

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
