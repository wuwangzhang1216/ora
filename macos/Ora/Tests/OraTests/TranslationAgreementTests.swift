import XCTest
@testable import Ora

final class TranslationAgreementTests: XCTestCase {
    func testEarlierNumberFormattingCannotHoldNewlyAgreedSpeech() throws {
        var state = StableTranslation()
        _ = state.plan(for: "The launch is next Friday at two thirty in the afternoon and the security team will review the authentication flow tomorrow morning", preview: true)
        let plan = try XCTUnwrap(state.plan(for: "The launch is next Friday at 2:30 in the afternoon and the security team will review the authentication flow tomorrow morning before lunch", preview: true))
        XCTAssertTrue(plan.provisional)
        XCTAssertTrue(plan.text.contains("2:30"), "retain the latest recognition instead of normalizing or guessing a number")
        XCTAssertTrue(plan.text.contains("security team will review"))
    }

    func testAlignedPreviewUsesTheLatestNegationRatherThanTheOldHypothesis() throws {
        var state = StableTranslation()
        _ = state.plan(for: "The team will release next Friday after the security review and the migration guide have both been checked", preview: true)
        let plan = try XCTUnwrap(state.plan(for: "The team will not release next Friday after the security review and the migration guide have both been checked by reviewers", preview: true))
        XCTAssertTrue(plan.provisional)
        XCTAssertTrue(plan.text.contains("will not release"))
        XCTAssertTrue(state.source.isEmpty)
    }

    func testAudioEndpointCanAlignAcrossEarlierRecognitionRevisions() throws {
        let snapshot = SpeechRecognitionSnapshot(), id = UUID()
        let first = "The launch is at two thirty while the security team will review the authentication flow."
        let latest = "The launch is at 2:30 while the security team will review the authentication flow."
        snapshot.note(id: id, samples: 48_000, text: first)
        snapshot.noteTranslation(id: id, source: first)
        snapshot.note(id: id, samples: 96_000, text: latest + " The support team reviews the migration guide.")
        let boundary = try XCTUnwrap(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 96_000))
        XCTAssertEqual(boundary.text, latest)
    }

    func testAmbiguousRepeatedEndpointCannotBeUsedAsAnAlignmentShortcut() {
        let snapshot = SpeechRecognitionSnapshot(), id = UUID()
        let first = "At two thirty the security team will review the authentication flow."
        snapshot.note(id: id, samples: 48_000, text: first)
        snapshot.note(id: id, samples: 96_000,
            text: "At 2:30 the security team will review the authentication flow. The security team will review the authentication flow.")
        XCTAssertNil(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 96_000))
    }

    func testPunctuationRevisionsDoNotHideAgreedWordsInAnUnfinishedTail() throws {
        var state = StableTranslation()
        _ = state.plan(for: "The team completed the initial review, and the client wants us to launch next Friday morning", preview: true)
        let plan = try XCTUnwrap(state.plan(for: "The team completed the initial review. And the client wants us to launch next Friday morning after lunch", preview: true))
        XCTAssertTrue(plan.provisional)
        XCTAssertTrue(plan.text.lowercased().contains("client wants us to launch"))
        XCTAssertTrue(state.source.isEmpty, "word agreement cannot turn unconfirmed punctuation into a checkpoint")
    }

    func testAudioRetirementConfirmsTheEndpointRatherThanEveryEarlierComma() throws {
        let snapshot = SpeechRecognitionSnapshot(), id = UUID()
        let first = "The release is ready, but we should keep the current version running."
        snapshot.note(id: id, samples: 48_000, text: first)
        snapshot.noteTranslation(id: id, source: first)
        let corrected = "the release is ready; but we should keep the current version running."
        snapshot.note(id: id, samples: 96_000, text: corrected + " The security review continues.")
        let boundary = try XCTUnwrap(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 96_000))
        XCTAssertEqual(boundary.text, corrected, "use the latest punctuation for the confirmed spoken prefix")
    }

    func testLongerPreviewCannotTriggerRetranslationOfAnEarlierCommaClause() throws {
        var state = StableTranslation()
        let clause = "Although the engineering team has prepared the release,"
        let first = try XCTUnwrap(state.plan(for: clause, confirmed: true))
        _ = state.commit(first, translation: "尽管工程团队已准备好版本，")
        let longer = clause + " the sales team would like us to launch it next Friday afternoon"
        let preview = try XCTUnwrap(state.plan(for: longer, confirmed: true))
        XCTAssertTrue(preview.text.contains("sales team"))
        _ = state.commit(preview, translation: "尽管工程团队已准备好版本，销售团队希望下周五发布。")
        XCTAssertNil(state.plan(for: longer + " and", confirmed: true),
                     "an old comma prefix cannot replace a newer, longer preview")
        XCTAssertEqual(state.displayed, "尽管工程团队已准备好版本，销售团队希望下周五发布。")
    }

    func testCommaPreviewDoesNotFreezeMeaningBeforeFullSentenceArrives() throws {
        var state = StableTranslation()
        let clause = "The English forwarded to the French baskets of flowers,"
        _ = state.plan(for: clause + " of which")
        let preview = try XCTUnwrap(state.plan(for: clause + " of which they"))
        XCTAssertTrue(preview.provisional)
        _ = state.commit(preview, translation: "英语向法语递送了花篮，")
        XCTAssertTrue(state.source.isEmpty, "a comma clause must not become permanent translation context")
        let full = clause + " of which they had made a plentiful provision to greet the arrival of the young princess."
        _ = state.plan(for: full, preview: true)
        let final = try XCTUnwrap(state.plan(for: full, preview: true))
        XCTAssertFalse(final.provisional)
        XCTAssertEqual(final.text, full, "later context must be able to correct The English / the French to people")
        XCTAssertNil(final.preceding)
        XCTAssertEqual(state.commit(final, translation: "英国人向法国人赠送了花篮，以迎接年轻公主的到来。"),
                       "英国人向法国人赠送了花篮，以迎接年轻公主的到来。")
    }

    func testChangedSentenceBoundaryCanPreviewTheWholeUnfinishedSentence() throws {
        var state = StableTranslation()
        let first = "She made her forget France."
        _ = state.plan(for: first)
        _ = state.commit(try XCTUnwrap(state.plan(for: first)), translation: "她让她忘记了法国。")
        let next = "She made her forget France, she taught her daughter through her own warm affection"
        _ = state.plan(for: next, preview: true)
        let preview = try XCTUnwrap(state.plan(for: next + " that love", preview: true))
        XCTAssertTrue(preview.provisional)
        XCTAssertNil(preview.preceding, "a revised sentence is translated as a whole, not as a detached suffix")
        XCTAssertTrue(preview.text.hasPrefix("She made her forget France,"))
        XCTAssertEqual(state.commit(preview, translation: "她用自己的喜爱之情教导女儿。"), "她用自己的喜爱之情教导女儿。",
                       "the old translation must not be prepended to its replacement")
    }

    func testChinesePreviewDoesNotRequireWhitespaceOrPunctuation() throws {
        var state = StableTranslation()
        let text = "我们今天需要讨论新产品的发布计划以及下周的测试安排"
        XCTAssertNil(state.plan(for: text, preview: true))
        let plan = try XCTUnwrap(state.plan(for: text + "还有预算", preview: true))
        XCTAssertTrue(plan.provisional)
        _ = state.commit(plan, translation: "Today we need to discuss the release plan.")
        XCTAssertTrue(state.source.isEmpty)
        XCTAssertNil(state.translation(for: plan.source))
    }

    func testProvisionalRequestsWaitForMeaningfulSourceGrowthButNotCorrections() throws {
        var state = StableTranslation()
        let first = "The team will deliver the complete report tomorrow morning before lunch"
        _ = state.plan(for: first, preview: true)
        let plan = try XCTUnwrap(state.plan(for: first, preview: true))
        _ = state.commit(plan, translation: "团队会在明天交付报告。")
        XCTAssertNil(state.plan(for: first + " and", preview: true))
        XCTAssertNil(state.plan(for: first + " and then", preview: true), "one new confirmed word should not restart a full translation")
        let correction = "The team will not deliver the complete report tomorrow morning before lunch"
        _ = state.plan(for: correction, preview: true)
        XCTAssertNotNil(state.plan(for: correction, preview: true), "a confirmed negation correction must bypass growth coalescing")
    }

    func testCaseAndSpacingChangesReuseCompletedTranslationButQuestionChangesDoNot() throws {
        var state = StableTranslation()
        let text = "The meeting starts at nine."
        _ = state.plan(for: text)
        _ = state.commit(try XCTUnwrap(state.plan(for: text)), translation: "会议九点开始。")
        XCTAssertEqual(state.translation(for: "the  meeting starts at nine."), "会议九点开始。")
        XCTAssertNil(state.translation(for: "The meeting starts at nine?"))
    }
    func testCaseRevisionsDoNotPreventRetiringAConfirmedAudioPrefix() throws {
        let snapshot = SpeechRecognitionSnapshot()
        let id = UUID()
        let first = "Congratulations were poured in upon the princess everywhere during her journey."
        snapshot.note(id: id, samples: 48_000, text: first)
        snapshot.noteTranslation(id: id, source: first.lowercased())
        snapshot.note(id: id, samples: 96_000,
            text: first.lowercased() + " she seemed like a queen.")
        let boundary = try XCTUnwrap(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 96_000))
        XCTAssertEqual(boundary.samples, 48_000)
        XCTAssertEqual(boundary.text, first.lowercased())
    }

    func testCorrectedSentenceBoundaryCannotRetireAnUnfinishedThought() {
        let snapshot = SpeechRecognitionSnapshot(), id = UUID()
        let fragment = "The release is ready but we should keep."
        snapshot.note(id: id, samples: 48_000, text: fragment)
        snapshot.noteTranslation(id: id, source: fragment)
        snapshot.note(id: id, samples: 96_000,
                      text: "The release is ready but we should keep the current version running for existing customers.")
        XCTAssertNil(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 96_000),
                     "word agreement cannot validate an earlier sentence boundary that the latest recognition removed")
    }

    func testAcousticPrefixCannotBeRetiredAcrossAChangedNegation() {
        let snapshot = SpeechRecognitionSnapshot()
        let id = UUID()
        snapshot.note(id: id, samples: 48_000, text: "We should ship fifteen units today.")
        snapshot.note(id: id, samples: 96_000, text: "We should not ship fifteen units today. Please wait.")
        XCTAssertNil(snapshot.safeBoundary(id: id, minimumSamples: 32_000, maximumSamples: 96_000))
    }
    func testCaseChangesInRecognizedPrefixDoNotHoldTheNextSentence() throws {
        var state = StableTranslation()
        let first = "Congratulations were poured in upon the princess everywhere during her journey."
        _ = state.plan(for: first)
        _ = state.commit(try XCTUnwrap(state.plan(for: first)), translation: "公主一路受到祝贺。")
        let a = "congratulations were poured in upon the princess everywhere during her journey. She seemed like a queen."
        let b = "Congratulations were poured in upon the princess everywhere during her journey. She seemed like a queen."
        XCTAssertNil(state.plan(for: a))
        let next = try XCTUnwrap(state.plan(for: b), "case oscillation at the beginning must not erase agreement on new words at the end")
        XCTAssertEqual(next.text, "She seemed like a queen.")
        XCTAssertEqual(next.preceding?.translation, "公主一路受到祝贺。")
    }

    func testSentenceBoundaryCorrectionKeepsTheWholeSentenceAsTranslationInput() throws {
        var state = StableTranslation()
        let first = "The English forwarded to the French baskets of flowers."
        _ = state.plan(for: first)
        _ = state.commit(try XCTUnwrap(state.plan(for: first)), translation: "英国人给法国人送去了花篮。")
        let next = "The English forwarded to the French baskets of flowers, of which they had made a plentiful provision."
        XCTAssertNil(state.plan(for: next))
        let plan = try XCTUnwrap(state.plan(for: next))
        XCTAssertEqual(plan.text, next, "a revised sentence boundary must not leave the model translating a detached fragment")
        XCTAssertNil(plan.preceding)
    }

    func testShorterCaseVariantCannotRollBackTheCommittedSource() throws {
        var state = StableTranslation()
        let source = "The team completed the review. The client approved the release."
        _ = state.plan(for: source)
        _ = state.commit(try XCTUnwrap(state.plan(for: source)), translation: "团队完成审核，客户批准发布。")
        XCTAssertNil(state.plan(for: "the team completed the review."))
        XCTAssertNil(state.plan(for: "the team completed the review."))
        XCTAssertEqual(state.source, source)
        XCTAssertEqual(state.published, "团队完成审核，客户批准发布。")
    }

    func testNegationDecimalAndAcronymCorrectionsStillRequireARealNewTranslation() throws {
        for (before, after) in [
            ("We will ship 15 units tomorrow.", "We will not ship 1.5 units tomorrow."),
            ("We will ship 15 units tomorrow.", "We will ship 1.5 units tomorrow."),
            ("The balance is $5.", "The balance is -$5."),
            ("The US approved the plan.", "The us approved the plan."),
            ("电费是一百五十元。", "电费是一百零五元。")
        ] {
            var state = StableTranslation()
            _ = state.plan(for: before)
            _ = state.commit(try XCTUnwrap(state.plan(for: before)), translation: "旧译文")
            XCTAssertNil(state.plan(for: after))
            let changed = try XCTUnwrap(state.plan(for: after))
            XCTAssertEqual(changed.text, after)
            XCTAssertNil(changed.preceding)
        }
    }
}
