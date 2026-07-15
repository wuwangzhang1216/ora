import XCTest
@testable import Ora

final class TranslationPromptTests: XCTestCase {
    func testPromptWithoutHistoryMatchesLegacyShape() {
        let p = buildTranslationPrompt(targetLanguage: "English", text: "你好世界")
        XCTAssertEqual(
            p,
            "Translate to English. Output only the translation.\n\nSource: 你好世界\nEnglish: "
        )
    }

    func testPromptWithHistoryInterleavesPairsBeforeNewSource() {
        let history = [
            TranslationExchange(source: "早上好", translation: "Good morning"),
            TranslationExchange(source: "我叫小王", translation: "My name is Xiao Wang"),
        ]
        let p = buildTranslationPrompt(targetLanguage: "English", text: "很高兴认识你", history: history)
        let expected =
            "Translate to English. Output only the translation.\n\n"
            + "Source: 早上好\nEnglish: Good morning\n\n"
            + "Source: 我叫小王\nEnglish: My name is Xiao Wang\n\n"
            + "Source: 很高兴认识你\nEnglish: "
        XCTAssertEqual(p, expected)
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
