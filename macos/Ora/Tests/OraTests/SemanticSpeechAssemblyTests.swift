import XCTest
@testable import Ora

final class SemanticSpeechAssemblyTests: XCTestCase {
    func testCompletedSpeechDoesNotPayAnotherHalfSecondHold() {
        var assembly = SemanticSpeechAssembly()
        let recognition = SpeechRecognitionSnapshot()
        _ = assembly.pause([1, 2], now: 0)
        recognition.note(id: assembly.id!, samples: 2, text: "The meeting starts at nine.")
        XCTAssertFalse(assembly.poll(now: 0.30, recognition: recognition).isEmpty,
                       "VAD already waited for silence; confirmed complete speech must not add another long hold")
    }

    func testContinuousSpeechRetiresConfirmedAudioBeforeRecognitionWindowGrows() throws {
        var assembly = SemanticSpeechAssembly()
        let recognition = SpeechRecognitionSnapshot()
        _ = assembly.partial([Float](repeating: 1, count: 3 * Config.sampleRate))
        let id = try XCTUnwrap(assembly.id)
        recognition.note(id: id, samples: 3 * Config.sampleRate, text: "First sentence.")
        recognition.note(id: id, samples: 7 * Config.sampleRate, text: "First sentence. The next sentence continues")
        let output = assembly.pause([Float](repeating: 1, count: 8 * Config.sampleRate), now: 8, recognition: recognition)
        let committed = try XCTUnwrap(output.compactMap(\.finalized).first,
            "confirmed old speech must be retired during continuous speaking instead of being re-decoded for 45 seconds")
        XCTAssertEqual(committed.sourceOverride, "First sentence.")
        XCTAssertEqual(committed.audio.count, 3 * Config.sampleRate)
        XCTAssertEqual(output.last?.preview?.audio.count, 6 * Config.sampleRate)
    }

    func testRollingBoundaryCannotRewindPastAlreadyPublishedWords() {
        let recognition = SpeechRecognitionSnapshot(), id = UUID()
        recognition.note(id: id, samples: 3 * Config.sampleRate, text: "First sentence.")
        recognition.note(id: id, samples: 7 * Config.sampleRate, text: "First sentence. The next sentence, continues")
        recognition.noteTranslation(id: id, source: "First sentence. The next sentence,")
        XCTAssertNil(recognition.safeBoundary(id: id, minimumSamples: 1, maximumSamples: 8 * Config.sampleRate),
                     "retiring old audio must not replay a continuation the viewer has already received")
    }
    func testThinkingPauseDoesNotDetachTheFollowingNegatedClause() {
        var assembly = SemanticSpeechAssembly()
        let recognition = SpeechRecognitionSnapshot()
        _ = assembly.pause([1, 2, 0], now: 0)
        let id = assembly.id!
        recognition.note(id: id, samples: 3, text: "I don't think.")
        XCTAssertTrue(assembly.poll(now: 1.3, recognition: recognition).isEmpty)
        XCTAssertTrue(assembly.start(now: 1.8, recognition: recognition).isEmpty)
        XCTAssertEqual(assembly.id, id)
        _ = assembly.pause([3, 4, 0], now: 2)
        recognition.note(id: id, samples: 6, text: "I don't think we should ship today.")
        XCTAssertEqual(assembly.poll(now: 2.5, recognition: recognition).count, 1)
    }

    func testAcousticLengthSlicesDoNotForceAMidSentenceSemanticBoundary() {
        var assembly = SemanticSpeechAssembly()
        let recognition = SpeechRecognitionSnapshot()
        let slice = [Float](repeating: 0.1, count: 15 * Config.sampleRate)
        _ = assembly.start(now: 0, recognition: recognition)
        let id = assembly.id!
        for time in [15.0, 30.0] {
            let output = assembly.pause(slice, now: time)
            XCTAssertFalse(output.contains { if case .final = $0 { return true }; return false })
            _ = assembly.start(now: time + 0.1, recognition: recognition)
            XCTAssertEqual(assembly.id, id)
        }
        _ = assembly.partial([Float](repeating: 0.1, count: 8 * Config.sampleRate))
        guard case .final(let audio, let finalID) = assembly.flush().first else { return XCTFail("missing complete long sentence") }
        XCTAssertEqual(finalID, id)
        XCTAssertEqual(audio.count, 38 * Config.sampleRate)
    }
    func testFinishWaitsForTimerFinalBeforeClosingDownstream() async throws {
        let recognition = SpeechRecognitionSnapshot()
        let began = expectation(description: "timer final started")
        let gate = AssemblyEmissionGate()
        let coordinator = SpeechAssemblyCoordinator(recognition: recognition) { emission in
            if let preview = emission.preview { recognition.note(id: preview.id, samples: preview.audio.count, text: "Done.") }
            if emission.finalized != nil { await gate.suspend(began) }
        }
        await coordinator.receive(.final([1]))
        await fulfillment(of: [began], timeout: 3)
        let finish = Task { await coordinator.finish(); await gate.finish() }
        try await Task.sleep(for: .milliseconds(30))
        let premature = await gate.finished
        XCTAssertFalse(premature, "end-of-stream must not close the final queue while a timer final is in flight")
        await gate.release()
        await finish.value
        let completed = await gate.finished
        XCTAssertTrue(completed)
    }
    func testMidSentencePauseKeepsAudioAndUtteranceIdentity() {
        let recognition = SpeechRecognitionSnapshot()
        var assembly = SemanticSpeechAssembly()
        _ = assembly.start(now: 0, recognition: recognition)
        let id = assembly.id!
        _ = assembly.pause([1, 2, 0], now: 0)
        recognition.note(id: id, samples: 3, text: "I don't think.")
        XCTAssertTrue(assembly.poll(now: 0.6, recognition: recognition).isEmpty)
        XCTAssertTrue(assembly.start(now: 0.65, recognition: recognition).isEmpty)
        XCTAssertEqual(assembly.id, id)
        _ = assembly.pause([3, 4, 0], now: 1)
        recognition.note(id: id, samples: 6, text: "I don't think we should ship today.")
        let output = assembly.poll(now: 1.46, recognition: recognition)
        guard case .final(let audio, let finalID) = output.first else { return XCTFail("expected joined final") }
        XCTAssertEqual(audio, [1, 2, 0, 3, 4, 0])
        XCTAssertEqual(finalID, id)
        XCTAssertNil(assembly.id)
        XCTAssertTrue(assembly.poll(now: 4, recognition: recognition).isEmpty)
    }

    func testLongWindowCutsOnlyAtAConfirmedSentenceAndCarriesAudio() throws {
        var assembly = SemanticSpeechAssembly()
        let recognition = SpeechRecognitionSnapshot()
        _ = assembly.partial([Float](repeating: 1, count: 30 * Config.sampleRate))
        let id = try XCTUnwrap(assembly.id)
        recognition.note(id: id, samples: 30 * Config.sampleRate, text: "First sentence. Second sentence.")
        recognition.note(id: id, samples: 44 * Config.sampleRate, text: "First sentence. Second sentence. Third sentence continues")
        let audio = [Float](repeating: 1, count: 60 * Config.sampleRate)
        let emissions = assembly.pause(audio, now: 60, recognition: recognition)
        let committed = try XCTUnwrap(emissions.compactMap(\.finalized).first)
        XCTAssertEqual(committed.id, id)
        XCTAssertEqual(committed.sourceOverride, "First sentence. Second sentence.")
        XCTAssertEqual(committed.audio.count, 30 * Config.sampleRate)
        let carried = try XCTUnwrap(emissions.last?.preview)
        XCTAssertNotEqual(carried.id, id)
        XCTAssertEqual(carried.overlapSource, committed.sourceOverride)
        XCTAssertEqual(carried.audio.count, 31 * Config.sampleRate)
        XCTAssertEqual(committed.audio.count + carried.audio.count - Config.sampleRate, audio.count)
        _ = assembly.start(now: 60.1, recognition: recognition)
        _ = assembly.partial([Float](repeating: 2, count: Config.sampleRate))
        let final = try XCTUnwrap(assembly.flush().first?.finalized)
        XCTAssertEqual(final.audio.count, 32 * Config.sampleRate)
        XCTAssertEqual(final.overlapSource, committed.sourceOverride)
    }

    func testRevisedOrDifferentUtteranceCannotSupplySafeBoundary() {
        let recognition = SpeechRecognitionSnapshot(), id = UUID()
        recognition.note(id: id, samples: 10 * Config.sampleRate, text: "We should ship.")
        recognition.note(id: id, samples: 20 * Config.sampleRate, text: "We should not ship. Next")
        XCTAssertNil(recognition.safeBoundary(id: id, minimumSamples: 1, maximumSamples: 30 * Config.sampleRate))
        recognition.note(id: UUID(), samples: 30 * Config.sampleRate, text: "We should ship. Next")
        XCTAssertNil(recognition.safeBoundary(id: id, minimumSamples: 1, maximumSamples: 40 * Config.sampleRate))
    }

    func testDeduplicationAppliesOnlyToCarriedAudio() {
        XCTAssertEqual(TranscriptOverlap.strip("Face buried in his hands.", previous: "He remained thus, his face"), "buried in his hands.")
        XCTAssertEqual(TranscriptOverlap.strip("The door. Then he left.", previous: "He closed the door."), "Then he left.")
        XCTAssertEqual(TranscriptOverlap.strip("Face buried in his hands.", previous: nil), "Face buried in his hands.")
        XCTAssertEqual(TranscriptOverlap.strip("然后继续。", previous: "已经完成。"), "然后继续。")
        XCTAssertEqual(TranscriptOverlap.strip("测试。下一句。", previous: "完成测试。"), "下一句。")
        XCTAssertEqual(TranscriptOverlap.strip("好好读完。", previous: "这样很好。"), "好好读完。")
    }

    func testBriefPauseDoesNotCommitEvenAPunctuatedPartial() {
        let recognition = SpeechRecognitionSnapshot()
        var assembly = SemanticSpeechAssembly()
        _ = assembly.pause([1], now: 0)
        let id = assembly.id!
        recognition.note(id: id, samples: 1, text: "We will ship today.")
        XCTAssertTrue(assembly.start(now: 0.2, recognition: recognition).isEmpty)
        XCTAssertEqual(assembly.id, id, "a quick unless/if continuation belongs to the same utterance")
    }

    func testCompletedSentenceSeparatesAfterMinimumHold() {
        let recognition = SpeechRecognitionSnapshot()
        var assembly = SemanticSpeechAssembly()
        _ = assembly.pause([1, 2], now: 0)
        let id = assembly.id!
        recognition.note(id: id, samples: 2, text: "The meeting starts tomorrow.")
        XCTAssertEqual(assembly.start(now: 0.5, recognition: recognition).count, 1)
        XCTAssertNotEqual(assembly.id, id)
    }

    func testStaleRecognitionCannotCommitNewAudio() {
        let recognition = SpeechRecognitionSnapshot()
        var assembly = SemanticSpeechAssembly()
        _ = assembly.partial([1])
        let id = assembly.id!
        recognition.note(id: id, samples: 1, text: "This is complete.")
        _ = assembly.pause([1, 2], now: 0)
        XCTAssertTrue(assembly.poll(now: 0.3, recognition: recognition).isEmpty)
        XCTAssertEqual(assembly.poll(now: 0.46, recognition: recognition).count, 1,
                       "unknown/incomplete speech still has a bounded finalization delay")
    }

    func testAudioLimitAndEndOfStreamFlushExactlyOnce() {
        var assembly = SemanticSpeechAssembly(maximumSamples: 3)
        let output = assembly.pause([1, 2, 3], now: 0)
        XCTAssertEqual(output.count, 2, "preview and bounded final")
        XCTAssertTrue(assembly.flush().isEmpty)
        _ = assembly.partial([4, 5])
        XCTAssertEqual(assembly.flush().count, 1)
        XCTAssertTrue(assembly.flush().isEmpty)
    }

    func testIncompleteEnglishAndChineseAreNotEarlyEndpoints() {
        for fragment in ["I don't think.", "We need to.", "If the tests pass.", "The budget is.", "因为。", "我们需要。", "我觉得。", "Please wait..."] {
            XCTAssertFalse(SentenceBoundary.isComplete(fragment), fragment)
        }
        for sentence in ["We should not ship today.", "If tests pass, we will ship.", "预算是一万五千美元，不是五万美元。", "请不要把任务标记为完成。", "What is the budget?"] {
            XCTAssertTrue(SentenceBoundary.isComplete(sentence), sentence)
        }
    }

    func testDecimalPointsAndTitlesDoNotCreateACompleteUnit() {
        XCTAssertFalse(SentenceBoundary.hasCompleteUnit("The price is 3.14 and"))
        XCTAssertFalse(SentenceBoundary.hasCompleteUnit("Dr. Chen and"))
        XCTAssertTrue(SentenceBoundary.hasCompleteUnit("Dr. Chen approved it. Next"))
        XCTAssertEqual(SentenceBoundary.completePrefix("The meeting starts tomorrow. We need to"), "The meeting starts tomorrow.")
        XCTAssertEqual(SentenceBoundary.completePrefix("I don't think. We should ship today."), "", "a detached fragment must not become an affirmative caption")
    }
}

private actor AssemblyEmissionGate {
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend(_ began: XCTestExpectation) async {
        await withCheckedContinuation { continuation = $0; began.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
    func finish() { finished = true }
}

final class StableTranslationTests: XCTestCase {
    func testLongSentencePublishesAConfirmedReadableClauseBeforeItsPeriod() throws {
        var state = StableTranslation()
        let clause = "Although the engineering team has already prepared the new release,"
        XCTAssertNil(state.plan(for: clause + " the sales team"))
        let plan = try XCTUnwrap(state.plan(for: clause + " the sales team wants"))
        XCTAssertEqual(plan.text, clause)
        XCTAssertEqual(state.commit(plan, translation: "尽管工程团队已经准备好了新版本，"), "尽管工程团队已经准备好了新版本，")
    }

    func testShortFragmentsAndCommaSeparatedAmountsStayPending() {
        for text in ["I don't think, we should", "We need to, review", "The approved project budget is 15,000 dollars and"] {
            var state = StableTranslation()
            XCTAssertNil(state.plan(for: text))
            XCTAssertNil(state.plan(for: text + " continue"))
        }
    }
    func testTranslatesOnlyNewAgreedCompleteSourceUnits() throws {
        var state = StableTranslation()
        XCTAssertNil(state.plan(for: "Hello world. We need to"))
        let first = try XCTUnwrap(state.plan(for: "Hello world. We need to reduce"))
        XCTAssertEqual(first.text, "Hello world.")
        XCTAssertNil(first.preceding)
        XCTAssertEqual(state.commit(first, translation: "你好世界。"), "你好世界。")
        XCTAssertNil(state.plan(for: "Hello world. We need to reduce latency."))
        let next = try XCTUnwrap(state.plan(for: "Hello world. We need to reduce latency. Next"))
        XCTAssertEqual(next.text, "We need to reduce latency.")
        XCTAssertEqual(next.preceding?.translation, "你好世界。")
        XCTAssertEqual(state.commit(next, translation: "我们需要降低延迟。"), "你好世界。我们需要降低延迟。")
        XCTAssertNil(state.plan(for: "Hello world. We need to reduce latency. Next"))
    }

    func testCorrectionsCanReplaceAnEarlierDraftMeaning() throws {
        var state = StableTranslation()
        XCTAssertNil(state.plan(for: "We should ship."))
        let first = try XCTUnwrap(state.plan(for: "We should ship."))
        _ = state.commit(first, translation: "我们应该发布。")
        XCTAssertNil(state.plan(for: "We should not ship."))
        let correction = try XCTUnwrap(state.plan(for: "We should not ship."))
        XCTAssertNil(correction.preceding)
        XCTAssertEqual(state.commit(correction, translation: "我们不应该发布。"), "我们不应该发布。")
        XCTAssertNil(state.translation(for: "We should ship."), "a rewritten source invalidates earlier prefix translations")
    }

    func testConfirmedSentenceCutCanReuseAnEarlierTranslationCheckpoint() throws {
        var state = StableTranslation()
        _ = state.plan(for: "First sentence.")
        let first = try XCTUnwrap(state.plan(for: "First sentence. Next"))
        _ = state.commit(first, translation: "第一句。")
        _ = state.plan(for: "First sentence. Second sentence.")
        let second = try XCTUnwrap(state.plan(for: "First sentence. Second sentence. Next"))
        _ = state.commit(second, translation: "第二句。")
        XCTAssertEqual(state.translation(for: "First sentence."), "第一句。")
        XCTAssertEqual(state.translation(for: "First sentence. Second sentence."), "第一句。第二句。")
    }

    func testNumbersAndUnfinishedWordsAreNotCompleteUnits() throws {
        var state = StableTranslation()
        XCTAssertNil(state.plan(for: "The budget is 15,"))
        XCTAssertNil(state.plan(for: "The budget is 15,000 dollars."))
        let plan = try XCTUnwrap(state.plan(for: "The budget is 15,000 dollars. Next"))
        XCTAssertEqual(plan.text, "The budget is 15,000 dollars.")
    }

    func testNewUtteranceRequiresItsOwnRecognitionAgreement() throws {
        var first = StableTranslation()
        _ = first.plan(for: "旧的一句话。")
        let plan = try XCTUnwrap(first.plan(for: "旧的一句话。后续"))
        _ = first.commit(plan, translation: "Old sentence.")
        var next = StableTranslation()
        XCTAssertNil(next.plan(for: "新的一句话。"))
        XCTAssertTrue(next.published.isEmpty)
    }
}
