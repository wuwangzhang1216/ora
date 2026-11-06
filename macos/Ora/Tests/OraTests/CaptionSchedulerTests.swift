import AppKit
import CoreText
import XCTest
@testable import Ora

final class CaptionSchedulerTests: XCTestCase {
    func testLiveOverlayImmediatelyShowsNewestReadyUtterance() {
        var scheduler = CaptionScheduler()
        scheduler.followsLiveSpeech = true
        let first = UUID(), next = UUID()
        scheduler.update(id: first, source: "first", translation: "上一段还没有到阅读时限。", final: true, now: 0)
        scheduler.update(id: next, source: "next", translation: "现在正在说的新内容。", final: false, now: 0.1)
        XCTAssertEqual(scheduler.visible?.utteranceID, next)
        XCTAssertEqual(scheduler.queuedUtteranceCount, 0)
        scheduler.update(id: first, source: "late old final", translation: "旧内容最终修正。", final: true, now: 0.2)
        XCTAssertEqual(scheduler.visible?.utteranceID, next, "late finals cannot pull the live overlay backwards")
    }

    func testLiveOverlayBoundsOneLongUtteranceToLatestWindow() {
        var scheduler = CaptionScheduler()
        scheduler.followsLiveSpeech = true
        scheduler.typography.width = 180
        let id = UUID(), old = String(repeating: "这是一段较早的内容。", count: 20)
        let full = old + "这是现在说的重点。"
        scheduler.update(id: id, source: "", translation: full, final: false, now: 0)
        XCTAssertTrue(scheduler.visible!.translation.display.replacingOccurrences(of: "\n", with: "").contains("现在说的重点"))
        XCTAssertLessThanOrEqual(scheduler.visible!.translation.display.split(separator: "\n").count, 2)
        XCTAssertGreaterThan(scheduler.catchUpCount, 0)
    }

    func testLiveOverlayAcceptsShorterCorrectedSnapshotAfterCatchUp() {
        var scheduler = CaptionScheduler()
        scheduler.followsLiveSpeech = true
        let id = UUID()
        scheduler.update(id: id, source: "", translation: String(repeating: "较早的长段内容。", count: 30), final: false, now: 0)
        scheduler.update(id: id, source: "", translation: "这是修正后的当前译文。", final: false, now: 0.1)
        XCTAssertEqual(scheduler.visible?.translation.raw, "这是修正后的当前译文。")
    }

    func testLiveSourceContinuesAfterACompletedSentenceBeforeNextTranslation() {
        var scheduler = CaptionScheduler()
        scheduler.followsLiveSpeech = true
        let id = UUID()
        scheduler.update(id: id, source: "Hello world.", translation: "你好。", final: false, now: 0)
        scheduler.update(id: id, source: "Hello world. We are still speaking", translation: nil, final: false, now: 0.1)
        XCTAssertTrue(scheduler.visible!.source.display.contains("still speaking"),
            "recognized new words must be visible even before their translation completes")
    }

    func testLiveSourceFromNextUtteranceAppearsWhileItsTranslationIsPending() {
        var scheduler = CaptionScheduler()
        scheduler.followsLiveSpeech = true
        let first = UUID(), next = UUID()
        scheduler.update(id: first, source: "Earlier speech.", translation: "上一句译文。", final: true, now: 0)
        scheduler.update(id: next, source: "New speech is being captured", translation: nil, final: false, now: 0.1)
        XCTAssertTrue(scheduler.visible!.source.display.contains("New speech"))
        XCTAssertTrue(scheduler.visible!.translation.display.contains("上一句译文"))
        scheduler.advance(now: 2)
        scheduler.update(id: next, source: "New speech is being captured", translation: "新的讲话正在被捕获。", final: false, now: 2.1)
        XCTAssertEqual(scheduler.visible?.utteranceID, next)
    }

    func testTranslationRollsOneLineAndKeepsPreviousLineReadable() {
        var scheduler = CaptionScheduler()
        scheduler.typography.width = 180
        let full = String(repeating: "我们需要及时看到下一段字幕并且保留上一行作为阅读上下文。", count: 3)
        scheduler.update(id: UUID(), source: "", translation: full, final: true, now: 0)
        let first = scheduler.current!.translation
        XCTAssertEqual(first.display.split(separator: "\n").count, 1)
        XCTAssertLessThan(scheduler.nextDeadline!, 3, "one readable line should advance before a full two-line page")
        let advancedAt = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: advancedAt)
        let next = scheduler.current!.translation
        scheduler.update(id: scheduler.current!.utteranceID, source: "", translation: full,
                         final: true, now: advancedAt + 0.1)
        XCTAssertLessThanOrEqual(scheduler.current!.translation.display.split(separator: "\n").count, 2,
            "refreshing a held line cannot duplicate its context")
        XCTAssertTrue(next.display.hasPrefix(first.display + "\n"), "keep the previous line on screen while introducing the next")
        XCTAssertTrue(next.display.hasSuffix(next.raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        var consumed = first.raw + next.raw
        while scheduler.isDraining {
            scheduler.advance(now: scheduler.nextDeadline! + 0.01)
            if let cue = scheduler.current { consumed += cue.translation.raw }
        }
        XCTAssertEqual(consumed, full, "rolling must neither drop nor replay source text")
    }

    func testContinuationPagesPackShortSentencesWithoutAddingOneMinimumDwellEach() {
        var scheduler = CaptionScheduler()
        let id = UUID(), next = UUID()
        let full = "这段字幕需要完整阅读。坦诚。我向来如此。"
        scheduler.update(id: id, source: "", translation: full, final: true, now: 0)
        XCTAssertEqual(scheduler.current?.translation.raw, "这段字幕需要完整阅读。")
        scheduler.update(id: next, source: "", translation: "接下来一句。", final: true, now: 0.1)
        let now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        XCTAssertEqual(scheduler.current?.translation.raw, "坦诚。我向来如此。",
            "two tiny sentences that fit together must not consume separate 1.2s pages")
        let allowance = max(1.2, CaptionPaginator.readingUnits("坦诚。我向来如此。") + 0.35)
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, now + allowance)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertEqual(scheduler.current?.utteranceID, next)
    }
    func testOriginalLanguageTailCannotBlockTheNextReadyTranslation() {
        var scheduler = CaptionScheduler()
        let first = UUID(), next = UUID()
        scheduler.update(id: first, source: String(repeating: "verbose original words ", count: 20),
                         translation: "上一句译文。", final: true, now: 0)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertEqual(scheduler.current?.utteranceID, first)
        XCTAssertEqual(scheduler.current?.translation.raw, "")
        scheduler.update(id: next, source: "Next.", translation: "新一句已经准备好了。", final: true, now: 1.3)
        XCTAssertEqual(scheduler.current?.utteranceID, next,
                       "new translated subtitles cannot wait for the old original-language pages")
    }

    func testQueuedTranslationStartsAfterPrimaryTextWithoutExtraOriginalOnlyPages() {
        var scheduler = CaptionScheduler()
        let first = UUID(), next = UUID()
        scheduler.update(id: first, source: String(repeating: "verbose original words ", count: 20),
                         translation: "上一句译文。", final: true, now: 0)
        let deadline = scheduler.nextDeadline!
        scheduler.update(id: next, source: "Next.", translation: "下一句。", final: true, now: 0.1)
        XCTAssertEqual(scheduler.current?.utteranceID, first)
        scheduler.advance(now: deadline + 0.01)
        XCTAssertEqual(scheduler.current?.utteranceID, next)
    }
    func testHeldTranslationCannotCollapseBackToItsFirstSentence() {
        var scheduler = CaptionScheduler()
        let id = UUID(), source = String(repeating: "source text ", count: 30)
        scheduler.update(id: id, source: source, translation: "第一句话。", final: false, now: 0)
        scheduler.update(id: id, source: source, translation: "第一句话。第二句话。", final: true, now: 0.1)
        let visible = scheduler.current!.translation.display
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertEqual(scheduler.current?.translation.raw, "")
        XCTAssertEqual(scheduler.current?.translation.display, visible,
                       "holding context for longer source text cannot rewind the translated subtitle")
    }
    func testReadyContinuationAppearsInTheAvailableSecondLineWithoutWaitingForOldPage() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        let first = "我们现在开始讨论今天的项目安排，"
        let next = "接下来检查预算。"
        scheduler.update(id: id, source: "", translation: first, final: false, now: 0)
        let original = scheduler.current!
        let oldDeadline = scheduler.nextDeadline
        scheduler.update(id: id, source: "", translation: first + next, final: false, now: 0.5)
        XCTAssertEqual(scheduler.current?.id, original.id, "continuations should grow the existing caption")
        XCTAssertTrue(scheduler.current?.translation.raw.contains(next) == true,
                      "ready translated words must use available lines instead of waiting seconds in a hidden queue")
        XCTAssertTrue(scheduler.current?.translation.raw.hasPrefix(first) == true)
        if let oldDeadline, let newDeadline = scheduler.nextDeadline {
            XCTAssertLessThanOrEqual(newDeadline, oldDeadline + CaptionPaginator.readingUnits(next) + 0.01,
                                     "appending new words must not restart reading the old words")
        }
    }

    func testFinalRewordingCannotHideAnAlreadyVisibleContinuation() {
        var scheduler = CaptionScheduler()
        let id = UUID(), first = "我想用我的卡支付电费。"
        scheduler.update(id: id, source: "", translation: first, final: false, now: 0)
        scheduler.update(id: id, source: "", translation: first + "可以请您帮我吗？", final: false, now: 0.5)
        XCTAssertTrue(scheduler.current?.translation.raw.contains("可以请您帮我吗") == true)
        scheduler.update(id: id, source: "", translation: first + "您能帮我一下吗？", final: true, now: 0.8)
        XCTAssertTrue(scheduler.current?.translation.raw.contains("您能帮我一下吗") == true,
                      "finalization must not collapse a full caption back to its old first sentence")
    }
    func testEnglishRemainsVisibleAcrossExtraTranslationPages() {
        var scheduler = CaptionScheduler()
        let source = "Classify material properties and geometry."
        let translation = "先检查物体。对材质属性和几何形状进行分类。最后确认分类结果。"
        scheduler.update(id: UUID(), source: source, translation: translation, final: true, now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { !$0.source.display.isEmpty }, "English must remain visible while its translation continues")
        XCTAssertEqual(cues.map(\.source.raw).joined(), source, "holding context must not consume English twice")
        XCTAssertEqual(cues.map(\.translation.raw).joined(), translation)
    }

    func testTranslationRemainsVisibleWhileLongSourceFinishes() {
        var scheduler = CaptionScheduler()
        scheduler.update(id: UUID(), source: "First sentence. Second sentence. Third sentence.", translation: "精简译文。", final: true, now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertTrue(cues.allSatisfy { !$0.translation.display.isEmpty }, "must not flash blank or Translating after translation completed")
        XCTAssertEqual(cues.map(\.translation.raw).joined(), "精简译文。")
    }

    func testHeldSourceCannotLeakIntoTheNextUtterance() {
        var scheduler = CaptionScheduler()
        scheduler.update(id: UUID(), source: "Previous speaker.", translation: "上一句。还有译文。", final: true, now: 0)
        var now = 0.0
        _ = drain(&scheduler, now: &now)
        scheduler.update(id: UUID(), source: "", translation: "新的一句。", final: true, now: now)
        XCTAssertTrue(scheduler.current?.source.display.isEmpty == true)
    }

    func testQueuedSegmentsKeepEnoughTimeToRead() {
        var scheduler = CaptionScheduler()
        scheduler.update(id: UUID(), source: "A long sentence.", translation: "这是一句阅读时间足够长但不能挡住后面新字幕的中文翻译。", final: true, now: 0)
        scheduler.update(id: UUID(), source: "Next.", translation: "下一句。", final: true, now: 0.1)
        let effort = CaptionPaginator.readingUnits(scheduler.current!.translation.raw)
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, effort, "queue pressure must not speed past reading time")
    }

    func testLiveTranslationIsNotHeldForLongSourceReadingTime() {
        var scheduler = CaptionScheduler()
        let first = UUID(), next = UUID()
        scheduler.update(id: first,
                         source: "During this meeting we will carefully review every detail of the proposed project budget and schedule.",
                         translation: "好的。", final: true, now: 0)
        scheduler.update(id: next, source: "Next.", translation: "下一句。", final: true, now: 0.1)
        let deadline = scheduler.nextDeadline!
        print("[caption-pacing] first cue deadline=\(deadline)s")
        XCTAssertLessThanOrEqual(deadline, 2.4, "a short translation must not wait for a long source paragraph")
        var now = 0.1
        for _ in 0..<10 where scheduler.current?.utteranceID == first {
            now = scheduler.nextDeadline! + 0.01
            scheduler.advance(now: now)
        }
        XCTAssertEqual(scheduler.current?.utteranceID, next)
        print("[caption-pacing] next utterance visible at=\(now)s")
        XCTAssertLessThan(now, 2.5, "source-only trailing pages must not accumulate seconds of artificial lag")
    }

    func testSourceRevisionsCannotPostponeAStableTranslationPage() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Original source.", translation: "这个译文保持稳定。", final: false, now: 0)
        scheduler.update(id: UUID(), source: "", translation: "后面的句子。", final: true, now: 0.1)
        let initialDeadline = scheduler.nextDeadline!
        for n in 1...5 {
            scheduler.update(id: id, source: "Source revision \(n).", translation: "这个译文保持稳定。", final: false, now: Double(n) * 0.4)
            if let deadline = scheduler.nextDeadline {
                XCTAssertEqual(deadline, initialDeadline)
            } else {
                XCTAssertNil(scheduler.current, "a fully read live cue may await finalization, never restart its reading clock")
            }
        }
        XCTAssertLessThanOrEqual(initialDeadline, 2)
    }

    func testLateVisibleCorrectionGetsTimeForItsChangedWords() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Google benefits.", translation: "Google will not only offer generous compensation.", final: false, now: 5.7)
        scheduler.update(id: UUID(), source: "Next.", translation: "Next.", final: true, now: 5.8)
        scheduler.update(id: id, source: "Google recruits talent.", translation: "Google not only recruits top talent with generous compensation.", final: false, now: 9.7)
        let effort = CaptionPaginator.readingUnits("not only recruits top talent with")
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 9.7 + effort)
        let deadline = scheduler.nextDeadline!
        scheduler.update(id: id, source: "A later source wording revision.", translation: "Google not only recruits top talent with generous compensation.", final: false, now: 10.5)
        XCTAssertEqual(scheduler.nextDeadline!, deadline)
    }

    func testMinorRewordingCannotRestartReadingTheWholeCaption() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "", translation: "我们现在开始讨论今天的项目安排。", final: false, now: 0)
        let deadline = max(1.2, CaptionPaginator.readingUnits(scheduler.current!.translation.raw) + 0.35)
        scheduler.update(id: id, source: "", translation: "我们现在开始讨论明天的项目安排。", final: true, now: 1.5)
        XCTAssertLessThanOrEqual(scheduler.nextDeadline!, deadline + 0.01)
        XCTAssertTrue(scheduler.current?.translation.raw.contains("明天") == true)
    }

    func testModelWaitIsNotChargedToFirstTranslatedCueReadingTime() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Hello. Next sentence.", translation: nil, final: false, now: 0)
        scheduler.update(id: id, source: "Hello. Next sentence.", translation: "你好。下一句。", final: true, now: 5)
        XCTAssertEqual(scheduler.current?.translation.raw, "你好。")
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 5.75)
    }
    private func pages(_ text: String, size: CGFloat = 22, width: CGFloat = 560) -> [CaptionSlice] {
        let font = CaptionTypography(translationSize: size).translationFont
        var remaining = text
        var result: [CaptionSlice] = []
        while !remaining.isEmpty, result.count < 1000 {
            let page = CaptionPaginator.page(remaining, font: font, width: width, final: true)
            XCTAssertFalse(page.raw.isEmpty)
            XCTAssertLessThanOrEqual(page.display.components(separatedBy: "\n").count, 2,
                                     "size=\(size) width=\(width) raw=\(page.raw.debugDescription) display=\(page.display.debugDescription)")
            for line in page.display.components(separatedBy: "\n") {
                let attributed = NSAttributedString(string: line, attributes: [.font: font])
                let measured = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
                XCTAssertLessThanOrEqual(measured, Double(width), line)
            }
            result.append(page)
            remaining = String(remaining.dropFirst(page.raw.count))
        }
        XCTAssertEqual(result.map(\.raw).joined(), text, "every original character must survive pagination")
        XCTAssertEqual(result.map(\.display).joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace },
                       "the rendered pages, not just hidden buffers, must contain every word")
        return result
    }

    private func drain(_ scheduler: inout CaptionScheduler, now: inout TimeInterval) -> [ScheduledCaption] {
        var result: [ScheduledCaption] = []
        while let cue = scheduler.current, result.count < 1000 {
            result.append(cue)
            guard let deadline = scheduler.nextDeadline else {
                XCTFail("finalized captions must drain without new audio")
                break
            }
            now = max(now, deadline) + 0.01
            scheduler.advance(now: now)
        }
        XCTAssertFalse(scheduler.isDraining)
        return result
    }

    func testSentenceAndClauseBoundaries() {
        let text = "欢迎参加会议。今天我们讨论预算，接下来确认项目安排。"
        let result = pages(text)
        XCTAssertEqual(result.first?.raw, "欢迎参加会议。")
        XCTAssertEqual(result.last?.raw, "今天我们讨论预算，接下来确认项目安排。")
    }

    func testLongCJKLatinAndEmojiNeverDisappearAtAnySupportedSize() {
        let samples = [
            String(repeating: "连续讲话也应该全部显示而不能隐藏文字", count: 12),
            String(repeating: "Every word in this long meeting needs enough time to be read ", count: 12),
            String(repeating: "👨‍👩‍👧‍👦 开会讨论 🇨🇦 cafe\u{301} 和预算 👩🏽‍💻 ", count: 16),
            "https://example.com/" + String(repeating: "averylongunbrokentoken", count: 20)
        ]
        for size: CGFloat in [14, 22, 40] {
            for width: CGFloat in [392, 560] {
                for text in samples { _ = pages(text, size: size, width: width) }
            }
        }
    }

    func testDecimalsAndAbbreviationsAreNotSentenceEnds() {
        let text = "Dr. Chen reviewed version 3.14 and approved it. Next comes testing."
        let result = pages(text, width: 1000)
        XCTAssertEqual(result.first?.raw, "Dr. Chen reviewed version 3.14 and approved it. ")
    }

    func testQuoteStaysWithItsSentence() {
        XCTAssertEqual(pages("他说：“今天开始。”然后讨论预算。").first?.raw, "他说：“今天开始。”")
    }

    func testFIFOAndLosslessBilingualReading() {
        var scheduler = CaptionScheduler()
        var now = 0.0
        let a = UUID(), b = UUID()
        let sourceA = "Welcome to the meeting. Today we review the budget, then discuss the next steps."
        let targetA = "欢迎参加会议。今天我们审查预算，然后讨论下一步的项目安排。"
        let sourceB = String(repeating: "Please keep every word visible even when a speaker does not pause ", count: 6)
        let targetB = String(repeating: "即使讲话的人一直不停顿也要把每一个字完整显示出来", count: 6)
        scheduler.update(id: a, source: sourceA, translation: targetA, final: true, now: now)
        scheduler.update(id: b, source: sourceB, translation: targetB, final: true, now: now)
        let cues = drain(&scheduler, now: &now)
        for (id, source, translation) in [(a, sourceA, targetA), (b, sourceB, targetB)] {
            let group = cues.filter { $0.utteranceID == id }
            XCTAssertEqual(group.map(\.source.raw).joined(), source)
            XCTAssertEqual(group.map(\.translation.raw).joined(), translation)
        }
        let ids = cues.map(\.utteranceID)
        XCTAssertFalse(ids.drop(while: { $0 == a }).contains(a), "later input must not overtake unread cues")
        XCTAssertEqual(scheduler.visible, cues.last)
    }

    func testNewResultCannotOverwriteCurrentReadingBeforeDeadline() {
        var scheduler = CaptionScheduler()
        let a = UUID()
        scheduler.update(id: a, source: "First sentence.", translation: "第一句话。", final: true, now: 0)
        let first = scheduler.current
        scheduler.update(id: UUID(), source: "Second sentence.", translation: "第二句话。", final: true, now: 0.1)
        XCTAssertEqual(scheduler.current, first)
        XCTAssertEqual(scheduler.queuedUtteranceCount, 1)
        scheduler.advance(now: 0.3)
        XCTAssertEqual(scheduler.current, first)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertNotEqual(scheduler.current?.utteranceID, a)
    }

    func testStreamedPrefixDoesNotReplayWhenFinalArrives() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        var now = 0.0
        scheduler.update(id: id, source: "Hello. Next step.", translation: "你好。下一步。", final: false, now: now)
        let read = scheduler.current!
        now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        scheduler.update(id: id, source: "Hello. Next step.", translation: "你好。下一步。", final: true, now: now)
        let cues = [read] + drain(&scheduler, now: &now)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), "你好。下一步。")
        XCTAssertEqual(cues.map(\.source.raw).joined(), "Hello. Next step.")
    }

    func testSixtySecondsOfRevisedCaptionsNeverReplayReadSentences() {
        var scheduler = CaptionScheduler()
        var now = 0.0
        var displayed = [String]()
        for index in 0..<20 {
            let id = UUID()
            let source = "Hello. Task \(index). Finished \(index)."
            let translation = "你好。第\(index)项。完成\(index)项。"
            scheduler.update(id: id, source: source, translation: translation, final: false, now: now)
            let read = scheduler.current!.translation.raw
            displayed.append(read)
            now = scheduler.nextDeadline! + 0.01
            scheduler.advance(now: now)
            let currentID = scheduler.current?.id
            scheduler.update(id: id, source: source, translation: "您好。第\(index)项。完成\(index)项。", final: false, now: now + 0.1)
            XCTAssertEqual(scheduler.current?.source.raw, "Task \(index). ", "a revision must never rewind to Hello")
            XCTAssertFalse(scheduler.current?.translation.raw.contains("你好。") == true)
            XCTAssertFalse(scheduler.current?.translation.raw.contains("您好。") == true)
            XCTAssertEqual(scheduler.current?.id, currentID, "the visible cue must not jump backwards")
            scheduler.update(id: id, source: source, translation: "你好。第\(index)项。完成\(index)项。", final: true, now: now + 0.2)
            let rest = drain(&scheduler, now: &now)
            XCTAssertEqual(read + rest.map(\.translation.raw).joined(), translation,
                           "packing short continuations must neither replay nor lose any translated words")
            displayed += rest.map(\.translation.raw)
            now += 1
        }
        XCTAssertGreaterThan(now, 60, "exercise a stream longer than the reported 40s onset")
        XCTAssertEqual(displayed.joined().components(separatedBy: "你好。").count - 1, 20)
        XCTAssertFalse(displayed.joined().contains("您好。"), "reworded greetings were already read")
        for index in 0..<20 {
            XCTAssertEqual(displayed.joined().components(separatedBy: "第\(index)项。").count - 1, 1)
            XCTAssertEqual(displayed.joined().components(separatedBy: "完成\(index)项。").count - 1, 1)
        }
    }

    func testLiveRewordingDoesNotLeaveNextCueWaitingUntilFinalization() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Hello. How are you?", translation: "你好。", final: false, now: 0)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        XCTAssertEqual(scheduler.current?.source.raw, "How are you?")
        XCTAssertEqual(scheduler.current?.translation.raw, "")
        // A new rolling ASR translation revises an ALREADY READ prefix.
        // It must reach the display before the VAD segment finally ends.
        scheduler.update(id: id, source: "Hello. How are you?", translation: "您好。你好吗？", final: false, now: 1)
        XCTAssertFalse(scheduler.current?.translation.raw.isEmpty ?? true,
                       "completed revised text must not be held until silence / the 15s VAD limit")
        XCTAssertEqual(scheduler.current?.translation.raw, "你好吗？")
        XCTAssertEqual(scheduler.current?.source.raw, "How are you?", "never rewind the paired source")
        scheduler.update(id: id, source: "Hello. How are you?", translation: "您好。你好吗？", final: true, now: 1.1)
        var now = 1.1
        let remaining = drain(&scheduler, now: &now)
        XCTAssertEqual(remaining.map(\.source.raw).joined(), "How are you?")
        XCTAssertEqual(remaining.map(\.translation.raw).joined(), "你好吗？")
    }

    func testReplacementTokenPrefixDoesNotRewindReadCaptionPrematurely() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "Hello. How are you?", translation: "你好。", final: false, now: 0)
        scheduler.advance(now: scheduler.nextDeadline! + 0.01)
        let previous = scheduler.current
        scheduler.update(id: id, source: "Hello. How are you?", translation: "您", final: false, now: 1)
        XCTAssertEqual(scheduler.current?.source, previous?.source)
        XCTAssertEqual(scheduler.current?.translation, previous?.translation)
    }

    func testFinalRewordingDoesNotReplayReadTextOrDelayTheNextSentence() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "One. Two.", translation: "第一。第二。", final: false, now: 0)
        var now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        scheduler.update(id: id, source: "One. Three.", translation: "修正第一。第三。", final: true, now: now)
        XCTAssertTrue(scheduler.current?.isCorrection == true)
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), "第三。")
        XCTAssertEqual(cues.map(\.source.raw).joined(), "Three.")
        XCTAssertTrue(cues.allSatisfy(\.isCorrection))
    }

    func testFinalizationReleasesAnAlreadyReadLiveHead() {
        var scheduler = CaptionScheduler()
        let a = UUID(), b = UUID()
        scheduler.update(id: a, source: "One.", translation: "第一。", final: false, now: 0)
        scheduler.update(id: b, source: "Two.", translation: "第二。", final: true, now: 0)
        var now = scheduler.nextDeadline! + 0.01
        scheduler.advance(now: now)
        XCTAssertNil(scheduler.current)
        scheduler.update(id: a, source: "One.", translation: "第一。", final: true, now: now)
        XCTAssertEqual(scheduler.current?.utteranceID, b)
        _ = drain(&scheduler, now: &now)
        scheduler.update(id: a, source: "One.", translation: "第一。", final: true, now: now)
        XCTAssertFalse(scheduler.isDraining, "a duplicate completion cannot replay an old sentence")
    }

    func testSourceFirstWaitsForTranslationAndPauseDrainsSourceOnly() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        let source = "First sentence. Second sentence. Third sentence."
        scheduler.update(id: id, source: source, translation: nil, final: false, now: 0)
        XCTAssertEqual(scheduler.current?.source.raw, "First sentence. ")
        XCTAssertNil(scheduler.nextDeadline)
        scheduler.finishPending(now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.map(\.source.raw).joined(), source)
    }

    func testLargerFontsAndHiddenSourceDoNotDropTextOrAddBlankPages() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        let source = String(repeating: "A very long source with many words ", count: 10)
        let translation = "精简译文。"
        scheduler.update(id: id, source: source, translation: translation, final: true, now: 0)
        scheduler.reflow(CaptionTypography(width: 392, translationSize: 40, showsSource: false), now: 0.5)
        var now = 0.5
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.map(\.source.raw).joined(), source)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), translation)
    }

    func testReadingTimeGrowsWithTextAndLateTokensGetTimeToRead() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "", translation: "你好", final: false, now: 0)
        scheduler.update(id: id, source: "", translation: "你好，欢迎参加今天的项目预算审查会议。", final: true, now: 5)
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 5.25)
        scheduler.advance(now: 5.1)
        XCTAssertNotNil(scheduler.current)
    }

    func testRewordedVisibleCueGetsFreshReadingTime() {
        var scheduler = CaptionScheduler()
        let id = UUID()
        scheduler.update(id: id, source: "", translation: "原来的说法。", final: false, now: 0)
        scheduler.update(id: id, source: "", translation: "最终修正之后这句话需要重新给读者留足阅读时间。", final: true, now: 10)
        XCTAssertGreaterThanOrEqual(scheduler.nextDeadline!, 10.75)
        XCTAssertLessThanOrEqual(scheduler.nextDeadline!, 16)
        scheduler.advance(now: 11)
        XCTAssertNotNil(scheduler.current)
    }

    func testFinishingAbandonedLiveSegmentUnblocksFollowingCaptions() {
        var scheduler = CaptionScheduler()
        let a = UUID(), b = UUID()
        scheduler.update(id: a, source: "Unfinished recognition.", translation: nil, final: false, now: 0)
        scheduler.update(id: b, source: "Next.", translation: "下一句。", final: true, now: 0)
        scheduler.finish(id: a, now: 0)
        var now = 0.0
        let cues = drain(&scheduler, now: &now)
        XCTAssertEqual(cues.first?.source.raw, "Unfinished recognition.")
        XCTAssertEqual(cues.last?.translation.raw, "下一句。")
    }

    func testFontChangeAfterDrainRepaginatesRetainedTextWithoutCropping() {
        var scheduler = CaptionScheduler()
        let text = "这段完整字幕需要在字号变大以后依然能够完整显示"
        scheduler.update(id: UUID(), source: "", translation: text, final: true, now: 0)
        var now = 0.0
        _ = drain(&scheduler, now: &now)
        scheduler.reflow(CaptionTypography(width: 392, translationSize: 40), now: now)
        let cues = drain(&scheduler, now: &now)
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertEqual(cues.map(\.translation.raw).joined(), text)
    }

    @MainActor
    func testPresenterTimerAdvancesWithoutNewInput() async throws {
        let presenter = CaptionPresenter()
        presenter.update(id: UUID(), source: "", translation: "第一句。第二句。", final: true)
        XCTAssertEqual(presenter.visible?.translation.raw, "第一句。第二句。")
        XCTAssertTrue(presenter.isDraining)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(presenter.visible?.translation.raw, "第一句。第二句。",
            "keep the last live window visible after its timer drains")
        XCTAssertFalse(presenter.isDraining)
        presenter.reset()
        XCTAssertNil(presenter.visible)
    }
}
