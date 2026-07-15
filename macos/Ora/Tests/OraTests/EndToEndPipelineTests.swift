import AVFoundation
import XCTest
@testable import Ora

/// Full-cascade integration tests against the REAL models (Silero VAD CoreML,
/// Qwen3-ASR-1.7B MLX 8-bit, Qwen3.5-2B MLX 4-bit) on synthesized speech.
/// Skipped automatically when the models are not already in the local
/// Hugging Face cache, so CI without weights stays green.
final class EndToEndPipelineTests: XCTestCase {
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

        let pipe = PartialPipeline(asr: asr, backend: translator) { source, _ in
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
