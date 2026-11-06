import XCTest
@testable import Ora

final class SemanticPipelineTests: XCTestCase {
    @MainActor
    func testTranslationRecoveryClearsPreviousFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = TranslatorEngine(history: history, recognizer: RecoveryReplayRecognizer(),
            translator: RecoveringReplayTranslator(), segmenter: VADSegmenter(probe: { frame in
                frame.contains(where: { $0 > 0 }) ? 0.9 : 0.1
            }))
        let audio = [Float](repeating: 1, count: 20 * 512)
            + [Float](repeating: 0, count: 45 * 512)
            + [Float](repeating: 2, count: 20 * 512)
            + [Float](repeating: 0, count: 45 * 512)
        await engine.start(sourceOverride: SemanticPacedAudio(audio))
        var sawFailure = false
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline, history.currentSession.count < 2 {
            sawFailure = sawFailure || engine.lastTranslationError != nil
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.waitForInputCompletion()
        XCTAssertTrue(sawFailure, "the first utterance must reproduce the unavailable translator")
        XCTAssertEqual(history.currentSession.count, 2)
        XCTAssertEqual(history.currentSession.last?.translationText, "我们今天应该发布。")
        XCTAssertNil(engine.lastTranslationError, "a recovered translator must not leave a stale failure banner")
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }
    @MainActor
    func testStreamingFinalFlushIsNotReplacedByCachedPartialRecognition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-stream-flush-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let recognizer = TailBufferedReplayRecognizer()
        let engine = TranslatorEngine(history: history, recognizer: recognizer,
            translator: DelayedReplayTranslator(), segmenter: VADSegmenter(probe: { frame in
                frame.contains(where: { $0 > 0 }) ? 0.9 : 0.1
            }))
        await engine.start(sourceOverride: SemanticPacedAudio(
            [Float](repeating: 1, count: 24 * 512) + [Float](repeating: 0, count: 20 * 512)))
        await engine.waitForInputCompletion()
        let flushes = await recognizer.flushes
        XCTAssertEqual(flushes, 1, "a streaming recognizer must flush its pending acoustic tail even when the exact audio had a partial result")
        XCTAssertEqual(history.currentSession.first?.sourceText, "I can help you.")
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }
    @MainActor
    func testFinalizationReusesRecognitionOfTheExactSameAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-reuse-asr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let recognizer = CountingReplayRecognizer()
        let engine = TranslatorEngine(history: history, recognizer: recognizer,
            translator: DelayedReplayTranslator(), segmenter: VADSegmenter(probe: { frame in
                frame.contains(where: { $0 > 0 }) ? 0.9 : 0.1
            }))
        await engine.start(sourceOverride: SemanticPacedAudio(
            [Float](repeating: 1, count: 24 * 512) + [Float](repeating: 0, count: 20 * 512)))
        await engine.waitForInputCompletion()
        let calls = await recognizer.calls
        let largest = try XCTUnwrap(calls.keys.max())
        XCTAssertEqual(calls[largest], 1, "the final worker must not decode an audio buffer already recognized by the pause preview")
        XCTAssertEqual(history.currentSession.count, 1)
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }
    @MainActor
    func testFailedTranslationKeepsRecognizedSpeechAndReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-failed-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = TranslatorEngine(history: history, recognizer: PausedNegationRecognizer(),
            translator: EmptyReplayTranslator(), segmenter: VADSegmenter(probe: { frame in
                frame.contains(where: { $0 > 0 }) ? 0.9 : 0.1
            }))
        await engine.start(sourceOverride: SemanticPacedAudio([Float](repeating: 1, count: 20 * 512)))
        await engine.waitForInputCompletion()
        XCTAssertNotNil(engine.lastTranslationError)
        XCTAssertEqual(history.currentSession.count, 1)
        XCTAssertEqual(history.currentSession.first?.sourceText, "I don't think.")
        XCTAssertEqual(history.currentSession.first?.translationText, "")
        XCTAssertEqual(history.currentSession.first?.isPartial, true)
        engine.stop()
        XCTAssertEqual(history.currentSession.count, 1, "Stop cannot duplicate the saved failed utterance")
        try await history.flush(sessionID: history.sessionId)
    }
    @MainActor
    func testReplayCompletionWaitsForFinalInferenceButNotReadingClock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-replay-drain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = TranslatorEngine(history: history, recognizer: PausedNegationRecognizer(),
            translator: DelayedReplayTranslator(), segmenter: VADSegmenter(probe: { frame in
                frame.contains(where: { $0 > 0 }) ? 0.9 : 0.1
            }))
        let samples = [Float](repeating: 1, count: 20 * 512) + [Float](repeating: 0, count: 10 * 512)
        await engine.start(sourceOverride: SemanticPacedAudio(samples))
        await engine.waitForInputCompletion()
        XCTAssertEqual(history.currentSession.count, 1, "the finite source ending is not enough: final translation must also be committed")
        XCTAssertEqual(history.currentSession.first?.translationText, "我不这么认为。")
        XCTAssertTrue(engine.captions.isDraining, "inference completion and finishing the reading queue are different signals")
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }
    @MainActor
    func testActualEngineJoinsPausedNegationAndPublishesWholeTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-semantic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = TranslatorEngine(history: history, recognizer: PausedNegationRecognizer(),
            translator: PausedNegationTranslator(), segmenter: VADSegmenter(probe: { frame in
                frame.contains(where: { $0 > 0 }) ? 0.9 : 0.1
            }))
        let samples = [Float](repeating: 1, count: 20 * 512)
            + [Float](repeating: 0, count: 10 * 512)
            + [Float](repeating: 2, count: 20 * 512)
            + [Float](repeating: 0, count: 45 * 512)
        await engine.start(sourceOverride: SemanticPacedAudio(samples))
        let deadline = ContinuousClock.now + .seconds(7)
        var translations = Set<String>()
        while ContinuousClock.now < deadline {
            if let text = engine.captions.visible?.translation.display, !text.isEmpty { translations.insert(text) }
            if history.currentSession.count >= 1, !engine.captions.isDraining { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(history.currentSession.count, 1, "a 320ms pause inside the sentence must not create two final translations")
        XCTAssertEqual(history.currentSession.first?.sourceText, "I don't think we should ship today.")
        XCTAssertEqual(history.currentSession.first?.translationText, "我认为我们今天不应该发布。")
        XCTAssertFalse(translations.contains("我们今天应该发布。"), "the detached affirmative fragment must never be displayed")
        XCTAssertFalse(translations.contains("我认为"), "a raw token prefix is not a readable caption")
        XCTAssertTrue(translations.contains("我认为我们今天不应该发布。"))
        XCTAssertEqual(engine.droppedUtteranceCount, 0)
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(engine.captions.visible, "assembly timers cannot restore captions after stop")
    }
}

private actor TailBufferedReplayRecognizer: SpeechRecognitionBackend {
    nonisolated let isStreaming = true
    var flushes = 0
    func transcribe(_ audio: [Float]) async throws -> String { "I can help you." }
    func transcribe(_ audio: [Float], id: UUID, final: Bool) async throws -> String {
        if final { flushes += 1 }
        return final ? "I can help you." : "I can"
    }
}

private actor CountingReplayRecognizer: SpeechRecognitionBackend {
    var calls: [Int: Int] = [:]
    func transcribe(_ audio: [Float]) async throws -> String {
        calls[audio.count, default: 0] += 1
        return "Ready."
    }
}

private final class EmptyReplayTranslator: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    func translate(_ text: String) async throws -> String { "" }
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class RecoveringReplayTranslator: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    func translate(_ text: String) async throws -> String { "我们今天应该发布。" }
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if text.contains("offline") {
                continuation.finish(throwing: URLError(.cannotConnectToHost))
            } else {
                continuation.yield("我们今天应该发布。")
                continuation.finish()
            }
        }
    }
}

private struct RecoveryReplayRecognizer: SpeechRecognitionBackend {
    func transcribe(_ audio: [Float]) async throws -> String {
        audio.contains(2) ? "We should ship today." : "The service is offline."
    }
}

private final class DelayedReplayTranslator: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    func translate(_ text: String) async throws -> String { "我不这么认为。" }
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    continuation.yield("我不这么认为。")
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct PausedNegationRecognizer: SpeechRecognitionBackend {
    func transcribe(_ audio: [Float]) async throws -> String {
        if audio.contains(1), audio.contains(2) { return "I don't think we should ship today." }
        return audio.contains(1) ? "I don't think." : "We should ship today."
    }
}

private final class PausedNegationTranslator: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    func translate(_ text: String) async throws -> String { "" }
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let result = text == "I don't think we should ship today." ? "我认为我们今天不应该发布。"
                : text == "I don't think." ? "我不认为。" : "我们今天应该发布。"
            for character in result { continuation.yield(String(character)) }
            continuation.finish()
        }
    }
}

private final class SemanticPacedAudio: AudioSource, @unchecked Sendable {
    let samples: [Float]
    init(_ samples: [Float]) { self.samples = samples }
    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                for offset in stride(from: 0, to: samples.count, by: 512) {
                    do { try await Task.sleep(until: start + .seconds(Double(offset) / 16_000), clock: .continuous) }
                    catch { break }
                    continuation.yield(Array(samples[offset..<min(offset + 512, samples.count)]))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
