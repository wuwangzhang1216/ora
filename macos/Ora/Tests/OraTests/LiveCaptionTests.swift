import XCTest
@testable import Ora

final class LiveCaptionTests: XCTestCase {
    func testExactFinalJoinsInFlightTranslationWithoutPaintingFrozenPreview() async {
        let backend = ControlledCaptionBackend()
        let source = expectation(description: "source")
        source.assertForOverFulfill = false
        let log = CaptionDrawLog()
        let pipe = PartialPipeline(transcribe: { _ in "Hello world." }, backend: backend) { text, translation, _ in
            await log.append(text, translation)
            if translation == nil { source.fulfill() }
        }
        let id = UUID()
        await pipe.start()
        await pipe.submit([1], id: id)
        await fulfillment(of: [source], timeout: 3)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2], id: id)
        await fulfillment(of: [backend.requestStarted], timeout: 3)
        await pipe.freeze(finalID: id, finalSource: "hello world.")
        await pipe.freeze(discardPending: false, finalID: id, finalSource: "hello world.")
        backend.yield("你好世界。")
        backend.finish()
        await pipe.awaitQuiescence()
        let cached = await pipe.completedTranslation(id: id, source: "Hello world.")
        XCTAssertEqual(cached, "你好世界。")
        let translated = await log.translations.compactMap { $0 }
        XCTAssertTrue(translated.isEmpty, "final worker publishes the result; frozen previews cannot paint")
        await pipe.shutdown()
    }

    func testChangedFinalSourceOrLanguageCannotJoinPreview() async {
        for changedLanguage in [false, true] {
            let backend = ControlledCaptionBackend()
            let source = expectation(description: "recognized")
            source.assertForOverFulfill = false
            let pipe = PartialPipeline(transcribe: { _ in "Hello world." }, backend: backend) { _, translation, _ in
                if translation == nil { source.fulfill() }
            }
            let id = UUID()
            await pipe.start()
            await pipe.submit([1], id: id)
            await fulfillment(of: [source], timeout: 3)
            await pipe.awaitQuiescence()
            await pipe.submit([1, 2], id: id)
            await fulfillment(of: [backend.requestStarted], timeout: 3)
            if changedLanguage { backend.targetLanguage = "Japanese" }
            await pipe.freeze(finalID: id, finalSource: changedLanguage ? "Hello world." : "Hello world?")
            await pipe.awaitQuiescence()
            backend.yield("stale")
            backend.finish()
            let cached = await pipe.completedTranslation(id: id, source: "Hello world.")
            XCTAssertNil(cached)
            await pipe.shutdown()
        }
    }

    func testRepeatedPauseSnapshotDoesNotRecognizeTheSameAudioAgain() async {
        let source = expectation(description: "first recognition")
        source.assertForOverFulfill = false
        let recognizer = CountingCaptionRecognizer(), backend = ControlledCaptionBackend()
        let pipe = PartialPipeline(asr: recognizer, backend: backend,
                                   recognitionSnapshot: SpeechRecognitionSnapshot()) { _, translation, _ in
            if translation == nil { source.fulfill() }
        }
        let id = UUID()
        await pipe.start()
        await pipe.submit([1, 2, 3], id: id)
        await fulfillment(of: [source], timeout: 3)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2, 3], id: id)
        await fulfillment(of: [backend.requestStarted], timeout: 3)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1, "a pause preview can confirm the recognized text without paying for identical ASR again")
        backend.yield("你好世界。")
        backend.finish()
        await pipe.awaitQuiescence()
        await pipe.shutdown()
    }
    func testIncompleteSourceIsVisibleWithoutRequestingAGuessedTranslation() async {
        let source = expectation(description: "incomplete original displayed")
        let backend = ControlledCaptionBackend()
        backend.requestStarted.isInverted = true
        let pipe = PartialPipeline(transcribe: { _ in "I don't think." }, backend: backend) { text, translation, _ in
            XCTAssertEqual(text, "I don't think.")
            XCTAssertNil(translation)
            source.fulfill()
        }
        await pipe.start()
        await pipe.submit([1])
        await fulfillment(of: [source], timeout: 3)
        await pipe.awaitQuiescence()
        await fulfillment(of: [backend.requestStarted], timeout: 0.05)
        await pipe.shutdown()
    }

    func testRecognitionAgreementDoesNotLockAnIncompleteWord() {
        var source = LiveSourceText()
        source.update("We need a car")
        XCTAssertEqual(source.stablePrefix, "")
        source.update("We need a carpet")
        XCTAssertEqual(source.stablePrefix, "We need a ")
        XCTAssertEqual(source.tentativeSuffix, "carpet")
        source.update("We need a carpet today")
        XCTAssertEqual(source.stablePrefix, "We need a carpet")
        source.commit("We need a carpet today.")
        XCTAssertEqual(source.tentativeSuffix, "")
    }

    func testCJKAgreementAndCorrections() {
        var source = LiveSourceText()
        source.update("今天下午开会")
        source.update("今天下午开会讨论预算")
        XCTAssertEqual(source.stablePrefix, "今天下午开会")
        source.update("今天上午开会讨论预算")
        XCTAssertEqual(source.stablePrefix, "今天")
        XCTAssertEqual(source.stablePrefix + source.tentativeSuffix, source.text)
    }

    func testSourceAppearsImmediatelyAndSpeculativeTokensStayHidden() async throws {
        let sourceDrawn = expectation(description: "source available before any translated token")
        sourceDrawn.assertForOverFulfill = false
        let backend = ControlledCaptionBackend()
        let log = CaptionDrawLog()
        let utteranceID = UUID()
        let pipe = PartialPipeline(transcribe: { audio in
            audio.count == 1 ? "Hello world. We need to" : "Hello world. We need to reduce latency"
        }, backend: backend) { source, translation, id in
            XCTAssertEqual(id, utteranceID, "source and all streamed chunks must update the same utterance")
            await log.append(source, translation)
            if translation == nil { sourceDrawn.fulfill() }
        }
        await pipe.start()
        await pipe.submit([1], id: utteranceID)
        await fulfillment(of: [sourceDrawn], timeout: 3)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2], id: utteranceID)
        await fulfillment(of: [backend.requestStarted], timeout: 3)
        XCTAssertEqual(backend.receivedText(), "Hello world.", "translate completed source units without the unfinished tail")
        let beforeTokens = await log.translations
        XCTAssertTrue(beforeTokens.allSatisfy { $0 == nil })

        backend.yield("你好")
        try await Task.sleep(for: .milliseconds(30))
        let duringStream = await log.translations.compactMap { $0 }
        XCTAssertTrue(duringStream.isEmpty, "half-generated translations must stay off the card")
        backend.yield("世界。")
        backend.finish()
        await pipe.awaitQuiescence()
        let confirmed = await log.translations.compactMap { $0 }
        XCTAssertEqual(confirmed, ["你好世界。"])
        let cached = await pipe.completedTranslation(id: utteranceID, source: "Hello world.")
        XCTAssertEqual(cached, "你好世界。")
        let incompleteMatch = await pipe.completedTranslation(id: utteranceID, source: "Hello world. We need to reduce latency")
        XCTAssertNil(incompleteMatch, "a translated clause cannot stand in for the final whole utterance")
        await pipe.shutdown()
    }

    func testLiveTranslationUsesTheSameCommittedContextAsFinals() async {
        let context = TranslationContext()
        context.note(source: "The dishwasher is broken.", translation: "洗碗机坏了。")
        let backend = ControlledCaptionBackend()
        let recognized = expectation(description: "source recognized")
        recognized.assertForOverFulfill = false
        let pipe = PartialPipeline(transcribe: { _ in "Please fix it." }, backend: backend, context: context) { _, text, _ in
            if text == nil { recognized.fulfill() }
        }
        await pipe.start()
        let id = UUID()
        await pipe.submit([1], id: id)
        await fulfillment(of: [recognized], timeout: 3)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2], id: id)
        await fulfillment(of: [backend.requestStarted], timeout: 3)
        XCTAssertEqual(backend.receivedHistory(), context.snapshot())
        backend.yield("请修好它。")
        backend.finish()
        await pipe.awaitQuiescence()
        await pipe.shutdown()
    }

    func testFreezeCancelsStreamAndCannotPaintAfterReset() async {
        let backend = ControlledCaptionBackend()
        let log = CaptionDrawLog()
        let sourceDrawn = expectation(description: "source drawn")
        sourceDrawn.assertForOverFulfill = false
        let pipe = PartialPipeline(transcribe: { _ in "Hello." }, backend: backend) { source, translation, _ in
            await log.append(source, translation)
            if translation == nil { sourceDrawn.fulfill() }
        }
        await pipe.start()
        let id = UUID()
        await pipe.submit([1], id: id)
        await fulfillment(of: [sourceDrawn], timeout: 3)
        await pipe.awaitQuiescence()
        await pipe.submit([1, 2], id: id)
        await fulfillment(of: [backend.requestStarted], timeout: 3)
        let generation = await pipe.freeze()
        await pipe.awaitQuiescence()
        let count = await log.translations.count
        await pipe.reset(ifGeneration: generation)
        backend.yield("STALE")
        backend.finish()
        await pipe.awaitQuiescence()
        let after = await log.translations.count
        XCTAssertEqual(after, count)
        await pipe.shutdown()
    }

    func testShutdownRejectsInFlightRecognition() async {
        let recognitionStarted = expectation(description: "recognition started")
        let recognizer = SuspendedCaptionRecognizer()
        let log = CaptionDrawLog()
        let backend = ControlledCaptionBackend()
        let pipe = PartialPipeline(transcribe: { _ in
            await recognizer.wait(started: recognitionStarted)
        }, backend: backend) { source, translation, _ in
            await log.append(source, translation)
        }
        await pipe.start()
        await pipe.submit([1])
        await fulfillment(of: [recognitionStarted], timeout: 3)
        await pipe.shutdown()
        await recognizer.finish()
        await pipe.awaitQuiescence()
        let count = await log.translations.count
        XCTAssertEqual(count, 0)
    }
}

private actor CountingCaptionRecognizer: SpeechRecognitionBackend {
    var calls = 0
    func transcribe(_ audio: [Float]) async throws -> String { calls += 1; return "Hello world." }
}

private actor CaptionDrawLog {
    var translations: [String?] = []
    func append(_ source: String, _ translation: String?) { translations.append(translation) }
}

private actor SuspendedCaptionRecognizer {
    private var continuation: CheckedContinuation<String, Never>?
    func wait(started: XCTestExpectation) async -> String {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish() { continuation?.resume(returning: "Old session"); continuation = nil }
}

private final class ControlledCaptionBackend: TranslationBackend, @unchecked Sendable {
    var targetLanguage = "Chinese"
    let requestStarted = XCTestExpectation(description: "translation stream requested")
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var history: [TranslationExchange] = []
    private var text = ""

    func receivedHistory() -> [TranslationExchange] { lock.withLock { history } }
    func receivedText() -> String { lock.withLock { text } }

    func translate(_ text: String) async throws -> String {
        XCTFail("Live captions must use streaming translation")
        return ""
    }

    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        lock.withLock { continuation = pair.continuation; self.history = history; self.text = text }
        requestStarted.fulfill()
        return pair.stream
    }

    func yield(_ text: String) { lock.withLock { _ = continuation?.yield(text) } }
    func finish() { lock.withLock { continuation?.finish() } }
}
