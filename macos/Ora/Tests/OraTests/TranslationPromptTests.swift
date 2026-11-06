import XCTest
@testable import Ora

final class TranslationPromptTests: XCTestCase {
    func testChineseTargetDoesNotInviteOppositeLanguageForMixedSpeech() {
        let speech = "我的专业是 ISM, Information Systems Management。"
        let messages = buildTranslationMessages(targetLanguage: "Chinese", text: speech)
        XCTAssertTrue(messages.first?.content.contains("Required output language: Chinese") == true)
        XCTAssertEqual(messages.last?.content, speech)
        XCTAssertFalse(buildTranslationMessages(targetLanguage: "English", text: speech).first?.content.contains("Required output language: Chinese") == true)
        XCTAssertFalse(buildTranslationMessages(targetLanguage: "Chinese", text: "Please assist.").first?.content.contains("Required output language: Chinese") == true)
    }
    func testUtteranceHasNoSyntheticSourceLabel() {
        let messages = buildTranslationMessages(targetLanguage: "Chinese", text: "This is a fork.")
        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        XCTAssertEqual(messages.last?.content, "This is a fork.")
        XCTAssertTrue(messages.first?.content.contains("Chinese") == true)
        XCTAssertFalse(messages.contains { $0.content.contains("Source:") })
    }

    func testContextIsSeparateConversationTurns() {
        let history = [TranslationExchange(source: "Good morning.", translation: "早上好。")]
        let messages = buildTranslationMessages(targetLanguage: "Chinese", text: "Good evening.", history: history)
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[1].content, "Good morning.")
        XCTAssertEqual(messages[2].content, "早上好。")
        XCTAssertEqual(messages[3].content, "Good evening.")
    }

    func testLiteralSourceLabelsInSpeechArePreserved() {
        let speech = "Source: Wikipedia. 来源：维基百科。"
        let messages = buildTranslationMessages(targetLanguage: "Chinese", text: speech)
        XCTAssertEqual(messages.last?.content, speech)
    }
}

final class TranslationContextTests: XCTestCase {
    func testKeepsOnlyMostRecentExchanges() {
        let ctx = TranslationContext()
        for i in 1...(TranslationContext.maxExchanges + 3) {
            ctx.note(source: "s\(i)", translation: "t\(i)")
        }
        let snapshot = ctx.snapshot()
        XCTAssertEqual(snapshot.count, TranslationContext.maxExchanges)
        XCTAssertEqual(snapshot.first?.source, "s4")
        XCTAssertEqual(snapshot.last?.source, "s\(TranslationContext.maxExchanges + 3)")
    }

    func testSkipsOversizedAndEmptyPairs() {
        let ctx = TranslationContext()
        ctx.note(source: String(repeating: "长", count: TranslationContext.maxExchangeChars), translation: "too big")
        ctx.note(source: "  ", translation: "whitespace source")
        ctx.note(source: "ok", translation: "")
        XCTAssertTrue(ctx.snapshot().isEmpty)
        ctx.note(source: "你好", translation: "hello")
        XCTAssertEqual(ctx.snapshot().count, 1)
    }

    func testTrimsWhitespaceAndReset() {
        let ctx = TranslationContext()
        ctx.note(source: " 你好 \n", translation: " hello ")
        XCTAssertEqual(ctx.snapshot(), [TranslationExchange(source: "你好", translation: "hello")])
        ctx.reset()
        XCTAssertTrue(ctx.snapshot().isEmpty)
    }
}
