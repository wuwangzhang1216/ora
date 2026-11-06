import XCTest
@testable import Ora

final class StreamingRecognitionTests: XCTestCase {
    func testAppleRangeRevisionReplacesTheTailAndKeepsEarlierFinalText() {
        var text = SpeechResultText()
        text.update(start: 0, end: 1, text: "The meeting starts.")
        text.update(start: 1, end: 2, text: "Please bring a")
        text.update(start: 1, end: 3, text: "Please bring the report.")
        XCTAssertEqual(text.text, "The meeting starts. Please bring the report.")
        text.update(start: 3, end: 4, text: "Thank you.")
        XCTAssertEqual(text.text, "The meeting starts. Please bring the report. Thank you.")
    }

    func testVolatileRecognitionNeedsAgreementBeforeItsTailIsPreviewed() throws {
        var translation = StableTranslation()
        XCTAssertNil(translation.plan(for: "The team will deliver the complete report tomorrow morning", preview: true))
        let preview = try XCTUnwrap(translation.plan(for: "The team will deliver the complete report tomorrow morning before lunch", preview: true))
        XCTAssertTrue(preview.provisional)
        XCTAssertEqual(preview.text, "The team will deliver the complete report tomorrow")
    }
    func testStreamingEndpointDoesNotWaitForPunctuationButProtectsHangingNegation() {
        let snapshot = SpeechRecognitionSnapshot(acceptsUnpunctuatedEnd: true)
        let id = UUID()
        snapshot.note(id: id, samples: 100, text: "The supper will be given tomorrow")
        XCTAssertTrue(snapshot.complete(id: id, samples: 100))
        XCTAssertFalse(snapshot.needsContinuation(id: id, samples: 100))
        snapshot.note(id: id, samples: 200, text: "I don't think")
        XCTAssertFalse(snapshot.complete(id: id, samples: 200))
        XCTAssertTrue(snapshot.needsContinuation(id: id, samples: 200))
        let offline = SpeechRecognitionSnapshot()
        offline.note(id: id, samples: 100, text: "The supper will be given tomorrow")
        XCTAssertFalse(offline.complete(id: id, samples: 100), "the existing Qwen endpoint policy must remain unchanged")
    }
    func testGrowingAndRepeatedSnapshotsFeedEachSampleOnlyOnce() {
        var cursor = StreamingRecognitionCursor()
        let id = UUID()
        let first = cursor.consume([1, 2], id: id)
        XCTAssertTrue(first.restart)
        XCTAssertEqual(first.delta, [1, 2])
        let repeated = cursor.consume([1, 2], id: id)
        XCTAssertFalse(repeated.restart)
        XCTAssertTrue(repeated.delta.isEmpty)
        let tail = cursor.consume([1, 2, 3], id: id)
        XCTAssertFalse(tail.restart)
        XCTAssertEqual(tail.delta, [3])
    }

    func testNewUtteranceAndShorterBufferRestartAcousticState() {
        var cursor = StreamingRecognitionCursor()
        let firstID = UUID(), secondID = UUID()
        _ = cursor.consume([1, 2, 3], id: firstID)
        let next = cursor.consume([4, 5], id: secondID)
        XCTAssertTrue(next.restart)
        XCTAssertEqual(next.delta, [4, 5])
        let truncated = cursor.consume([4], id: secondID)
        XCTAssertTrue(truncated.restart)
        XCTAssertEqual(truncated.delta, [4])
    }

    func testCommittedStreamingSentenceDoesNotWaitForSecondRecognition() throws {
        var translation = StableTranslation()
        let first = try XCTUnwrap(translation.plan(for: "The meeting starts at nine.", confirmed: true))
        XCTAssertEqual(first.text, "The meeting starts at nine.")
        _ = translation.commit(first, translation: "会议九点开始。")
        XCTAssertNil(translation.plan(for: "The meeting starts at nine.", confirmed: true))
        let next = try XCTUnwrap(translation.plan(for: "The meeting starts at nine. Please join us.", confirmed: true))
        XCTAssertEqual(next.text, "Please join us.")
        XCTAssertEqual(next.preceding?.translation, "会议九点开始。")
    }

    func testStreamingTailCanAppearBeforePunctuationWithoutFreezingItsTranslation() throws {
        var translation = StableTranslation()
        XCTAssertNil(translation.plan(for: "I would like to pay my electricity", confirmed: true), "do not show dangling five-word fragments such as 'I would like to pay my'")
        let preview = try XCTUnwrap(translation.plan(for: "I would like to pay my electricity bill using", confirmed: true))
        XCTAssertTrue(preview.provisional)
        XCTAssertEqual(preview.text, "I would like to pay my electricity bill")
        XCTAssertEqual(translation.commit(preview, translation: "我想支付电费。"), "我想支付电费。")
        XCTAssertEqual(translation.source, "", "a speculative tail must not become permanent context")
        XCTAssertEqual(translation.published, "")
        XCTAssertNil(translation.translation(for: preview.source))
        XCTAssertNil(translation.plan(for: "I would like to pay my electricity bill using", confirmed: true))
        let final = try XCTUnwrap(translation.plan(for: "I would like to pay my electricity bill using my card.", confirmed: true))
        XCTAssertFalse(final.provisional)
        XCTAssertNil(final.preceding)
        XCTAssertEqual(translation.commit(final, translation: "我想用银行卡支付电费。"), "我想用银行卡支付电费。")
    }
}
