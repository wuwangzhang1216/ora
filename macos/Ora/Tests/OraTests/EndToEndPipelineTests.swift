import AVFoundation
import XCTest
@testable import Ora

/// Full-cascade integration tests against the REAL models (Silero VAD CoreML,
/// Qwen3-ASR-1.7B MLX 8-bit, Qwen3.5-2B MLX 4-bit) on synthesized speech.
/// Skipped automatically when the models are not already in the local
/// Hugging Face cache, so CI without weights stays green.
final class EndToEndPipelineTests: XCTestCase {
    /// Exercise the actual engine, including VAD pauses, finalization freezes,
    /// live partials, and caption presentation, at microphone playback speed.
    /// Uses generated speech and a temporary transcript store, never capture.
    @MainActor
    func testRealTimeEngineDoesNotBlockNextSpeechAfterPause() async throws {
        try requireModels()
        try XCTSkipUnless(Self.cached("mlx-community/Qwen3.5-9B-MLX-4bit"), "9B weights must already be cached")
        // XCTest has its own defaults domain; explicitly exercise the user's
        // 9B Chinese translation configuration rather than the 2B default.
        let preferences = Preferences.shared
        let oldQuality = preferences.quality, oldTarget = preferences.targetLanguage
        let oldLanguage = preferences.asrLanguage
        preferences.quality = .extraHigh
        preferences.targetLanguage = "Chinese"
        preferences.asrLanguage = "en"
        defer {
            preferences.quality = oldQuality
            preferences.targetLanguage = oldTarget
            preferences.asrLanguage = oldLanguage
        }
        let first = try synthesizeSpeech("Today we will review our project budget and discuss the release schedule and the responsibilities of each team.")
        let second = try synthesizeSpeech("Blue notebooks are ready for tomorrow.")
        let secondStartsAt = Double(first.count) / Double(Config.sampleRate)
        let audio = first + second
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-engine-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = TranslatorEngine(history: history)
        await engine.prepare()
        XCTAssertEqual(engine.phase, .ready)
        let started = ContinuousClock.now
        await engine.start(sourceOverride: PacedSpeechFixture(audio: audio))
        XCTAssertEqual(engine.phase, .listening)
        var nextSourceAt: Double?
        var firstUtteranceID: UUID?
        let deadline = started + .seconds(Double(audio.count) / Double(Config.sampleRate) + 15)
        while ContinuousClock.now < deadline {
            let d = started.duration(to: .now).components
            let elapsed = Double(d.seconds) + Double(d.attoseconds) / 1e18
            if elapsed < secondStartsAt {
                firstUtteranceID = engine.recognizedUtteranceID
            } else if nextSourceAt == nil, let id = engine.recognizedUtteranceID,
                      id != firstUtteranceID, !engine.sourceText.isEmpty {
                nextSourceAt = elapsed
            }
            if nextSourceAt != nil, history.currentSession.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let nextSourceDelay = nextSourceAt.map { $0 - secondStartsAt }
        let report = "[engine-replay] next_source_after_speech_start_s=\(nextSourceDelay ?? -1) finalized_lines=\(history.currentSession.count)\n"
            + "[engine-replay] synthetic_sources=\(history.currentSession.map(\.sourceText))\n"
        FileHandle.standardError.write(Data(report.utf8))
        XCTAssertNotNil(nextSourceDelay, "the next utterance must become visible")
        if let nextSourceDelay { XCTAssertLessThan(nextSourceDelay, 2.5, "the previous final must not indefinitely freeze new speech") }
        let sessionID = history.sessionId
        engine.stop()
        try await history.flush(sessionID: sessionID)
    }

    @MainActor
    func testSixtySecondEngineReplayDoesNotReturnToOldCues() async throws {
        try requireModels()
        try XCTSkipUnless(Self.cached("mlx-community/Qwen3.5-9B-MLX-4bit"), "9B weights must already be cached")
        let preferences = Preferences.shared
        let oldQuality = preferences.quality, oldTarget = preferences.targetLanguage
        let oldLanguage = preferences.asrLanguage
        preferences.quality = .extraHigh
        preferences.targetLanguage = "Chinese"
        preferences.asrLanguage = "en"
        defer {
            preferences.quality = oldQuality
            preferences.targetLanguage = oldTarget
            preferences.asrLanguage = oldLanguage
        }
        let topics = ["budget", "schedule", "design", "testing", "shipping", "training", "support", "security", "research", "feedback", "planning", "launch"]
        var audio = [Float]()
        for topic in topics {
            audio += try synthesizeSpeech("Let us discuss our \(topic) today. We should review the details carefully before making the final decision.")
        }
        let duration = Double(audio.count) / Double(Config.sampleRate)
        XCTAssertGreaterThan(duration, 60)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-long-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = TranslatorEngine(history: history)
        await engine.prepare()
        XCTAssertEqual(engine.phase, .ready)
        await engine.start(sourceOverride: PacedSpeechFixture(audio: audio))
        let began = ContinuousClock.now
        let deadline = began + .seconds(duration + 15)
        var lastUtterance: UUID?, lastCue: UUID?
        var seenUtterances = Set<UUID>(), seenCues = Set<UUID>()
        var sourcePages: [UUID: Set<String>] = [:]
        var pagesAfterFortySeconds = 0
        var maximumQueue = 0
        while ContinuousClock.now < deadline {
            if let cue = engine.captions.visible, cue.id != lastCue {
                if cue.utteranceID != lastUtterance {
                    XCTAssertFalse(seenUtterances.contains(cue.utteranceID), "cannot return to a previous utterance")
                    seenUtterances.insert(cue.utteranceID)
                    lastUtterance = cue.utteranceID
                }
                XCTAssertFalse(seenCues.contains(cue.id), "cannot return to a previous cue")
                seenCues.insert(cue.id)
                let text = cue.source.display
                if text.count > 12, !cue.source.raw.isEmpty, !cue.isCorrection {
                    XCTAssertFalse(sourcePages[cue.utteranceID, default: []].contains(text), "cannot replay a read source page: \(text)")
                    sourcePages[cue.utteranceID, default: []].insert(text)
                }
                lastCue = cue.id
                if ContinuousClock.now > began + .seconds(40) { pagesAfterFortySeconds += 1 }
            }
            maximumQueue = max(maximumQueue, engine.captions.queuedCount)
            if ContinuousClock.now > began + .seconds(duration + 2), !engine.captions.isDraining { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(pagesAfterFortySeconds, 5, "must verify active caption updates beyond 40 seconds")
        XCTAssertGreaterThan(history.currentSession.count, 8)
        XCTAssertFalse(engine.captions.isDraining, "captions must catch up after speech ends")
        XCTAssertEqual(engine.droppedUtteranceCount, 0)
        FileHandle.standardError.write(Data("[long-engine-replay] audio_s=\(duration) cues=\(seenCues.count) cues_after_40s=\(pagesAfterFortySeconds) finals=\(history.currentSession.count) max_caption_queue=\(maximumQueue)\n".utf8))
        let sessionID = history.sessionId
        engine.stop()
        try await history.flush(sessionID: sessionID)
    }

    private static let hubCache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub")

    private static func cached(_ repo: String) -> Bool {
        FileManager.default.fileExists(
            atPath: hubCache.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--")).path
        )
    }

    private func requireModels() throws {
        // Opt-in: MLX needs a Metal shader library that plain `swift test`
        // does not build (see speech-swift's scripts/build_mlx_metallib.sh,
        // or copy mlx-swift_Cmlx.bundle from a built app into the .xctest
        // bundle). Without it MLX aborts the whole test process rather than
        // failing a test, so these only run when explicitly requested:
        //   ORA_E2E=1 swift test --filter EndToEndPipelineTests
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ORA_E2E"] == "1",
            "set ORA_E2E=1 (with a Metal lib in place) to run real-model e2e tests"
        )
        try XCTSkipUnless(
            Self.cached("aufklarer/Silero-VAD-v5-CoreML")
                && Self.cached("aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
                && Self.cached("mlx-community/Qwen3.5-2B-MLX-4bit"),
            "real-model e2e test requires cached weights"
        )
    }

    /// Synthesize a spoken English sentence with the macOS TTS and return it
    /// as 16 kHz mono Float32 samples with a second of trailing silence.
    private func synthesizeSpeech(_ sentence: String) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("ora-e2e-\(UUID().uuidString).aiff")
        let wav = dir.appendingPathComponent("ora-e2e-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: wav)
        }

        func run(_ tool: String, _ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw XCTSkip("\(tool) failed (status \(p.terminationStatus)) — cannot synthesize test speech")
            }
        }
        try run("/usr/bin/say", ["-v", "Albert", "-o", aiff.path, sentence])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])

        let file = try AVAudioFile(forReading: wav)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw XCTSkip("could not allocate audio buffer")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw XCTSkip("no float channel data")
        }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        samples.append(contentsOf: [Float](repeating: 0, count: Config.sampleRate))  // 1s trailing silence
        return samples
    }

    /// The whole cascade: synthesized speech → Silero VAD segmentation →
    /// Qwen3-ASR transcription → Qwen3.5 streamed translation (with and
    /// without rolling few-shot context).
    func testFullCascadeOnSynthesizedSpeech() async throws {
        try requireModels()
        let sentence = "Hello, how are you doing today? This is a test of the translation pipeline."
        let samples = try synthesizeSpeech(sentence)

        // 1. VAD segmentation (real Silero CoreML)
        let segmenter = try await VADSegmenter.load()
        let audio = AsyncStream<[Float]> { continuation in
            var index = 0
            let chunk = 1024
            while index < samples.count {
                let end = min(index + chunk, samples.count)
                continuation.yield(Array(samples[index..<end]))
                index = end
            }
            continuation.finish()
        }
        var finals: [[Float]] = []
        var sawStart = false
        for await event in segmenter.events(from: audio) {
            switch event {
            case .speechStart: sawStart = true
            case .partial: break
            case .final(let f): finals.append(f)
            }
        }
        XCTAssertTrue(sawStart, "VAD must detect speech in synthesized audio")
        XCTAssertFalse(finals.isEmpty, "VAD must emit at least one final utterance")
        let utterance = finals.max(by: { $0.count < $1.count })!
        XCTAssertGreaterThan(Double(utterance.count) / Double(Config.sampleRate), 1.0,
                             "main utterance should be over a second of audio")

        // 2. ASR (real Qwen3-ASR-1.7B MLX 8-bit, auto language)
        let asr = try await ASRClient.load(modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", language: nil)
        let transcript = await asr.transcribe(utterance).lowercased()
        XCTAssertFalse(transcript.isEmpty, "ASR returned empty text")
        XCTAssertTrue(
            transcript.contains("test") || transcript.contains("translation") || transcript.contains("hello"),
            "ASR transcript should contain expected words, got: \(transcript)"
        )

        // 3. Translation (real Qwen3.5-2B MLX 4-bit), no context
        let translator = try await MLXChatTranslator.load(
            modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
            targetLanguage: "Chinese"
        )
        func containsHan(_ s: String) -> Bool {
            s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        var streamed = ""
        for try await chunk in translator.translateStream(transcript, history: []) {
            streamed += chunk
        }
        XCTAssertTrue(containsHan(streamed), "translation should contain Chinese, got: \(streamed)")

        // 4. Translation WITH rolling few-shot context (exercises the
        //    history prompt path end to end)
        let history = [TranslationExchange(source: "Good morning.", translation: "早上好。")]
        var contextual = ""
        for try await chunk in translator.translateStream("Good evening, my friend.", history: history) {
            contextual += chunk
        }
        XCTAssertTrue(containsHan(contextual), "contextual translation should contain Chinese, got: \(contextual)")

        // 5. Non-streaming partial path through the generation gate
        let partial = try await translator.translate("Thank you very much.")
        XCTAssertTrue(containsHan(partial), "partial translation should contain Chinese, got: \(partial)")

        FileHandle.standardError.write(
            "[e2e] asr=\(transcript)\n[e2e] final=\(streamed)\n[e2e] contextual=\(contextual)\n[e2e] partial=\(partial)\n"
                .data(using: .utf8) ?? Data()
        )
    }

    // NOTE: a draft-model speculative-decoding e2e test lived here briefly and
    // caught that the feature can never work with Qwen3.5 (hybrid model,
    // non-trimmable MambaCache on linear layers → KVCacheError at first
    // generation). The feature was removed; see Config.swift.

    func testTranslationDoesNotEchoSourceLabelsOrHistory() async throws {
        try requireModels()
        let modelID = ProcessInfo.processInfo.environment["ORA_E2E_TRANSLATOR_MODEL"]
            ?? "mlx-community/Qwen3.5-2B-MLX-4bit"
        try XCTSkipUnless(Self.cached(modelID), "translator weights must already be cached")
        let translator = try await MLXChatTranslator.load(modelId: modelID, targetLanguage: "Chinese")
        let fork = "This is a fork that my dishwasher failed to clean."
        let partial = try await translator.translate(fork)
        XCTAssertFalse(partial.contains("来源") || partial.contains("Source:"), partial)
        XCTAssertTrue(partial.contains("叉"), partial)
        let history = [TranslationExchange(source: "Good morning.", translation: "早上好。")]
        for text in [fork, "Good evening, my friend."] {
            var output = ""
            var updates = 0
            for try await chunk in translator.translateStream(text, history: history) {
                output += chunk
                updates += 1
                XCTAssertFalse(output.contains("来源") || output.contains("Source:"), output)
            }
            XCTAssertGreaterThan(updates, 1, "translation must still stream")
            XCTAssertFalse(output.contains("早上好"), "must not repeat previous translation: \(output)")
            XCTAssertTrue(text == fork ? output.contains("叉") : output.contains("晚上"), output)
            FileHandle.standardError.write(Data("[translation-label-regression] \(text) => \(output)\n".utf8))
        }
        let literal = try await translator.translate("The source of this information is Wikipedia.")
        XCTAssertTrue(literal.contains("来源") || literal.contains("来自"), "legitimate source meaning must survive: \(literal)")
    }

    func testLiveCaptionStreamingWithRealModels() async throws {
        try requireModels()
        let modelID = ProcessInfo.processInfo.environment["ORA_E2E_TRANSLATOR_MODEL"]
            ?? "mlx-community/Qwen3.5-2B-MLX-4bit"
        try XCTSkipUnless(Self.cached(modelID), "requested translator must already be cached")
        let samples = try synthesizeSpeech("Welcome to our meeting. Today we will review the budget and discuss the next steps for our project.")
        let asr = try await ASRClient.load(modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", language: "en")
        let translator = try await MLXChatTranslator.load(
            modelId: modelID, targetLanguage: "Chinese"
        )
        actor Timeline {
            var events: [(Double, String, String?)] = []
            let start = ContinuousClock.now
            func append(_ source: String, _ translation: String?) {
                let duration = start.duration(to: .now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                events.append((seconds, source, translation))
            }
        }
        let timeline = Timeline()
        let sourceReady = expectation(description: "real ASR displayed")
        sourceReady.assertForOverFulfill = false
        let firstToken = expectation(description: "stable real translation")
        let pipe = PartialPipeline(asr: asr, backend: translator) { source, translation, _ in
            await timeline.append(source, translation)
            if translation == nil { sourceReady.fulfill() }
            // Only the first non-empty translation fires this expectation.
            let events = await timeline.events
            if translation != nil, events.filter({ $0.2 != nil }).count == 1 { firstToken.fulfill() }
        }
        await pipe.start()
        let liveID = UUID()
        await pipe.submit(samples, id: liveID)
        await fulfillment(of: [sourceReady], timeout: 90)
        await pipe.awaitQuiescence()
        // A later snapshot confirms source agreement. The same completed
        // translation is reused instead of displaying raw generated tokens.
        await pipe.submit(samples + [Float](repeating: 0, count: 1600), id: liveID)
        await fulfillment(of: [firstToken], timeout: 90)
        await pipe.awaitQuiescence()
        let events = await timeline.events
        XCTAssertNil(events.first?.2)
        let chunks = events.compactMap { $0.2 }
        XCTAssertGreaterThanOrEqual(chunks.count, 1, "must display a stable completed clause")
        XCTAssertTrue(chunks.last?.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } == true)
        XCTAssertTrue(events.first?.1.lowercased().contains("meeting") == true)
        // Run the actual streamed model output through the presentation
        // layer, then let its virtual reading clock drain without more audio.
        var captions = CaptionScheduler()
        let utteranceID = UUID()
        for event in events {
            captions.update(id: utteranceID, source: event.1, translation: event.2, final: false, now: 0)
        }
        captions.update(id: utteranceID, source: events.last?.1 ?? "", translation: chunks.last, final: true, now: 0)
        var renderedSource = ""
        var renderedTranslation = ""
        var cueCount = 0
        while let cue = captions.current, cueCount < 100 {
            renderedSource += cue.source.raw
            renderedTranslation += cue.translation.raw
            cueCount += 1
            guard let deadline = captions.nextDeadline else { break }
            captions.advance(now: deadline + 0.01)
        }
        XCTAssertFalse(captions.isDraining)
        XCTAssertEqual(renderedSource, events.last?.1)
        XCTAssertEqual(renderedTranslation, chunks.last)
        let firstTranslation = events.first { $0.2 != nil }?.0 ?? -1
        let report = "[live-caption-e2e] model=\(modelID) source=\(events.first?.0 ?? -1)s firstTranslation=\(firstTranslation)s complete=\(events.last?.0 ?? -1)s updates=\(chunks.count)\n"
            + "[live-caption-e2e] sourceText=\(events.first?.1 ?? "") translation=\(chunks.last ?? "")\n"
        FileHandle.standardError.write(Data(report.utf8))
        await pipe.shutdown()
    }

    /// Freeze semantics with real inference in flight: after freeze() +
    /// awaitQuiescence() no partial may draw, and a snapshot submitted while
    /// frozen survives to be processed after reset.
    func testPartialPipelineFreezeWithRealModels() async throws {
        try requireModels()
        let samples = try synthesizeSpeech("The quick brown fox jumps over the lazy dog.")

        let asr = try await ASRClient.load(modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", language: nil)
        let translator = try await MLXChatTranslator.load(
            modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
            targetLanguage: "Chinese"
        )

        final class DrawLog: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [String] = []
            func append(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
        }
        let log = DrawLog()

        let pipe = PartialPipeline(asr: asr, backend: translator) { source, _, _ in
            log.append(source)
        }
        await pipe.start()

        // Submit real audio, let the worker start, then freeze mid-flight.
        await pipe.submit(samples)
        try await Task.sleep(nanoseconds: 200_000_000)   // let processOne begin
        await pipe.freeze()                              // discards pending, blocks draws
        await pipe.awaitQuiescence()
        let drawsAtQuiescence = log.count

        // Nothing may draw after quiescence while frozen.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(log.count, drawsAtQuiescence, "no partial may draw after freeze+quiescence")

        // A snapshot submitted while frozen must survive and process after reset.
        await pipe.submit(samples)
        let generation = await pipe.generation
        await pipe.reset(ifGeneration: generation)
        let deadline = ContinuousClock.now + .seconds(30)
        while log.count == drawsAtQuiescence, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertGreaterThan(log.count, drawsAtQuiescence,
                             "snapshot submitted while frozen must be processed after reset")

        await pipe.shutdown()
    }
}

private final class PacedSpeechFixture: AudioSource, @unchecked Sendable {
    let audio: [Float]
    init(audio: [Float]) { self.audio = audio }

    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let task = Task.detached { [audio] in
                let start = ContinuousClock.now
                var offset = 0
                while offset < audio.count, !Task.isCancelled {
                    let end = min(offset + Config.vadFrameSamples, audio.count)
                    continuation.yield(Array(audio[offset..<end]))
                    offset = end
                    do {
                        try await Task.sleep(until: start + .seconds(Double(end) / Double(Config.sampleRate)), clock: .continuous)
                    } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
