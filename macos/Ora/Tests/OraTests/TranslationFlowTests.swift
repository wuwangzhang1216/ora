import XCTest
@testable import Ora

final class TranslationFlowTests: XCTestCase {
    func testRevisedWordingCanStreamAfterCatchingUpWithThePreviousResponse() {
        var display = TranslationStreamDisplay(previousText: "她随即用自己的喜爱之情教导女儿去爱那片土地。")
        XCTAssertNil(display.append("她通过自己的热爱", elapsedMS: 0))
        XCTAssertEqual(display.append("来教导女儿去爱那片土地，并为她开启新的未来", elapsedMS: 100),
                       "她通过自己的热爱来教导女儿去爱那片土地，并为她开启新的未来")
    }

    func testNextRequestCannotReplaceExistingTranslationWithItsShortOpening() {
        let previous = "团队会在明天上午交付完整报告"
        var display = TranslationStreamDisplay(previousText: previous)
        XCTAssertNil(display.append("团队会在明天上午", elapsedMS: 0),
                     "replaying the beginning of a growing sentence looks like typing the same subtitle again")
        XCTAssertEqual(display.append("交付完整报告并", elapsedMS: 100), previous + "并")
        var correction = TranslationStreamDisplay(previousText: previous)
        XCTAssertNil(correction.append("团队不会在明天", elapsedMS: 0))
        XCTAssertEqual(correction.append("上午交付完整报告", elapsedMS: 100), "团队不会在明天上午交付完整报告")
        var word = TranslationStreamDisplay(previousText: "The team will bring a car.")
        XCTAssertNil(word.append("The team will bring a carp", elapsedMS: 0))
        XCTAssertEqual(word.append("et ", elapsedMS: 100), "The team will bring a carpet")
    }

    func testProvisionalTranslationDoesNotBlockRetiringConfirmedAudio() async throws {
        let snapshot = SpeechRecognitionSnapshot(), id = UUID(), log = FlowPreviewLog()
        let first = "The team completed the initial review."
        let full = first + " The team will deliver the complete report tomorrow morning before lunch"
        let pipe = PartialPipeline(transcribe: { $0.count < 60_000 ? first : full },
            backend: FlowImmediateTranslator(), recognitionSnapshot: snapshot) { text, translation, _ in
                if translation == nil { await log.append(text) }
            }
        await pipe.start()
        for (index, size) in [48_000, 48_000, 96_000, 112_000].enumerated() {
            await pipe.submit([Float](repeating: 1, count: size), id: id)
            let deadline = ContinuousClock.now + .seconds(2)
            while await log.values.count <= index, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            await pipe.awaitQuiescence()
        }
        let draft = await pipe.completedDraft(id: id)
        XCTAssertEqual(draft?.source, first)
        XCTAssertNotNil(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 112_000),
                        "a speculative translated tail cannot prevent retiring the earlier complete audio window")
        await pipe.shutdown()
    }

    func testStreamUpdatesCoalesceTokensWithoutSplittingEnglishWords() {
        var display = TranslationStreamDisplay()
        XCTAssertNil(display.append("The team wi", elapsedMS: 0))
        XCTAssertEqual(display.append("ll deliver ", elapsedMS: 10), "The team will deliver")
        XCTAssertNil(display.append("the report ", elapsedMS: 30))
        XCTAssertEqual(display.append("tomorrow ", elapsedMS: 100), "The team will deliver the report tomorrow")
    }

    func testCancelledProvisionalStreamCannotPaintLateTokensOrBecomeACheckpoint() async {
        let backend = FlowControlledTranslator()
        let recognized = expectation(description: "recognized")
        recognized.assertForOverFulfill = false
        let painted = expectation(description: "streamed preview")
        painted.assertForOverFulfill = false
        let log = FlowPreviewLog()
        let pipe = PartialPipeline(asr: FlowLocalRecognizer(), backend: backend,
            drawPreview: { _, translation, _ in
                await log.append(translation ?? "")
                painted.fulfill()
            }) { _, translation, _ in if translation == nil { recognized.fulfill() } }
        let id = UUID()
        await pipe.start()
        await pipe.submit([1], id: id)
        await fulfillment(of: [recognized], timeout: 2)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2], id: id)
        await fulfillment(of: [backend.started], timeout: 2)
        backend.yield("团队会在明天上午")
        await fulfillment(of: [painted], timeout: 2)
        await pipe.freeze(finalID: id, finalSource: "A corrected sentence.")
        await pipe.awaitQuiescence()
        let count = await log.values.count
        backend.yield("过期的输出。")
        backend.finish()
        try? await Task.sleep(for: .milliseconds(30))
        let after = await log.values.count
        let draft = await pipe.completedDraft(id: id)
        XCTAssertEqual(after, count)
        XCTAssertNil(draft, "a generated or cancelled provisional tail is not a confirmed checkpoint")
        await pipe.shutdown()
    }

    func testLocalRecognitionCanTranslateAgreedWordsBeforePunctuation() async {
        let backend = FlowControlledTranslator()
        let recognized = expectation(description: "first source")
        recognized.assertForOverFulfill = false
        let pipe = PartialPipeline(asr: FlowLocalRecognizer(), backend: backend) { _, translation, _ in
            if translation == nil { recognized.fulfill() }
        }
        let id = UUID()
        await pipe.start()
        await pipe.submit([1], id: id)
        await fulfillment(of: [recognized], timeout: 2)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2], id: id)
        await fulfillment(of: [backend.started], timeout: 2)
        backend.finish()
        await pipe.awaitQuiescence()
        await pipe.shutdown()
    }

    @MainActor
    func testFinalTranslationIsVisibleBeforeStreamEnds() async throws {
        let (engine, history, directory, backend) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        await engine.start(sourceOverride: FlowAudio())
        await fulfillment(of: [backend.started], timeout: 3)
        backend.yield("团队会在明天上午")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(engine.captions.visible?.translation.display.contains("团队会在明天上午") == true,
                      "readable output must be visible while the stream remains open")
        XCTAssertTrue(history.currentSession.isEmpty, "streamed previews are not final history")
        backend.yield("交付完整报告。")
        backend.finish()
        await engine.waitForInputCompletion()
        XCTAssertEqual(history.currentSession.first?.translationText, "团队会在明天上午交付完整报告。")
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }

    @MainActor
    func testFailedStreamRemovesPreviewAndDoesNotSaveTruncatedTranslation() async throws {
        let (engine, history, directory, backend) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        await engine.start(sourceOverride: FlowAudio())
        await fulfillment(of: [backend.started], timeout: 3)
        backend.yield("团队会在明天上午")
        try await Task.sleep(for: .milliseconds(100))
        backend.finish(error: URLError(.networkConnectionLost))
        await engine.waitForInputCompletion()
        XCTAssertEqual(history.currentSession.first?.translationText, "")
        XCTAssertTrue(engine.captions.visible?.translation.display.isEmpty ?? true,
                      "a failed stream cannot leave its unfinished guess on screen")
        XCTAssertNotNil(engine.lastTranslationError)
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }

    @MainActor
    func testStopDuringStreamSavesSourceWithoutGeneratedPrefix() async throws {
        let (engine, history, directory, backend) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        await engine.start(sourceOverride: FlowAudio())
        await fulfillment(of: [backend.started], timeout: 3)
        backend.yield("团队会在明天上午")
        try await Task.sleep(for: .milliseconds(100))
        engine.stop()
        backend.yield("过期输出不能回来。")
        backend.finish()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(engine.captions.visible)
        XCTAssertEqual(history.currentSession.count, 1)
        XCTAssertEqual(history.currentSession.first?.translationText, "")
        XCTAssertFalse(history.currentSession.first?.sourceText.isEmpty ?? true)
        try await history.flush(sessionID: history.sessionId)
    }

    @MainActor
    private func makeEngine() -> (TranslatorEngine, TranscriptHistory, URL, FlowControlledTranslator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-flow-\(UUID())")
        let history = TranscriptHistory(directory: directory)
        let backend = FlowControlledTranslator()
        let engine = TranslatorEngine(history: history, recognizer: FlowFinalRecognizer(), translator: backend,
            segmenter: VADSegmenter(probe: { frame in frame.contains(1) ? 0.9 : 0.1 }))
        return (engine, history, directory, backend)
    }
}

private struct FlowLocalRecognizer: SpeechRecognitionBackend {
    func transcribe(_ audio: [Float]) async throws -> String {
        "The team will deliver the complete report tomorrow morning before lunch"
    }
}

private struct FlowFinalRecognizer: SpeechRecognitionBackend {
    var isStreaming: Bool { true }
    func transcribe(_ audio: [Float]) async throws -> String { "The team will deliver the complete report tomorrow morning." }
    func transcribe(_ audio: [Float], id: UUID, final: Bool) async throws -> String {
        final ? try await transcribe(audio) : ""
    }
}

private final class FlowAudio: AudioSource, @unchecked Sendable {
    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let task = Task {
                for _ in 0..<20 {
                    guard !Task.isCancelled else { break }
                    continuation.yield([Float](repeating: 1, count: 512))
                    try? await Task.sleep(for: .milliseconds(32))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class FlowControlledTranslator: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    let started = XCTestExpectation(description: "translation started")
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func translate(_ text: String) async throws -> String { "" }
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            started.fulfill()
        }
    }
    func yield(_ text: String) { _ = lock.withLock { continuation?.yield(text) } }
    func finish(error: Error? = nil) {
        lock.withLock { continuation?.finish(throwing: error); continuation = nil }
    }
}

private actor FlowPreviewLog {
    var values: [String] = []
    func append(_ text: String) { values.append(text) }
}

private final class FlowImmediateTranslator: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    func translate(_ text: String) async throws -> String { "这是已经完整生成的译文。" }
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("这是已经完整生成的译文。"); $0.finish() }
    }
}
