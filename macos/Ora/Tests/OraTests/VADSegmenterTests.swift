import XCTest
@testable import Ora

/// Endpointing state-machine tests with a scripted probability probe — no
/// CoreML weights involved. This is the logic that regressed in the 0.6.2
/// long-session freeze; keep it covered.
final class VADSegmenterTests: XCTestCase {
    private let frame = Config.vadFrameSamples

    /// Runs the segmenter over scripted per-frame speech probabilities and
    /// collects all events until the stream ends.
    private func run(
        probs: [Float],
        endSilenceMs: Int = 500
    ) async -> [VADEvent] {
        final class Counter: @unchecked Sendable {
            var i = 0
        }
        let counter = Counter()
        let scripted = probs
        let segmenter = VADSegmenter(probe: { _ in
            defer { counter.i += 1 }
            return scripted[min(counter.i, scripted.count - 1)]
        })

        let audio = AsyncStream<[Float]> { continuation in
            for _ in 0..<probs.count {
                continuation.yield([Float](repeating: 0, count: self.frame))
            }
            continuation.finish()
        }

        var events: [VADEvent] = []
        // partialIntervalS = 0 makes partial emission depend only on growth,
        // so the test is deterministic regardless of wall-clock speed.
        for await event in segmenter.events(
            from: audio,
            startThreshold: 0.5,
            stopThreshold: 0.35,
            endSilenceMs: endSilenceMs,
            partialIntervalS: 0
        ) {
            events.append(event)
        }
        return events
    }

    func testFullUtteranceEmitsStartPartialsAndFinal() async {
        let leadSilence = 5
        let speech = 20
        let endSilenceMs = 500
        let tailSilence = endSilenceMs / Config.vadFrameMs + 1
        let probs =
            [Float](repeating: 0.1, count: leadSilence)
            + [Float](repeating: 0.9, count: speech)
            + [Float](repeating: 0.1, count: tailSilence)

        let events = await run(probs: probs, endSilenceMs: endSilenceMs)

        var sawStart = 0
        var partialCounts: [Int] = []
        var finalCounts: [Int] = []
        for event in events {
            switch event {
            case .speechStart: sawStart += 1
            case .partial(let audio): partialCounts.append(audio.count / frame)
            case .final(let audio): finalCounts.append(audio.count / frame)
            }
        }

        XCTAssertEqual(sawStart, 1)
        XCTAssertEqual(finalCounts.count, 1, "exactly one final for one utterance")
        XCTAssertFalse(partialCounts.isEmpty, "long utterance must emit rolling partials")
        XCTAssertEqual(partialCounts, partialCounts.sorted(), "partials only grow")

        // Final = pre-roll retained at trigger + every frame until the
        // end-silence window fills.
        let preRollFrames = max(1, Config.preRollMs / Config.vadFrameMs)
        let endSilenceFrames = max(1, endSilenceMs / Config.vadFrameMs)
        let voicedAtTrigger = min(leadSilence + Config.speechStartFrames, preRollFrames)
        let expectedFinalFrames = voicedAtTrigger + (speech - Config.speechStartFrames) + endSilenceFrames
        XCTAssertEqual(finalCounts[0], expectedFinalFrames)
    }

    func testShortBurstBelowMinUtteranceIsDropped() async {
        // Trigger start (3 voiced frames) then fall silent immediately: total
        // voiced stays under minUtteranceMs, so no final may be emitted.
        let probs =
            [Float](repeating: 0.9, count: Config.speechStartFrames)
            + [Float](repeating: 0.1, count: 30)

        let events = await run(probs: probs)

        var sawStart = 0
        var sawFinal = 0
        for event in events {
            if case .speechStart = event { sawStart += 1 }
            if case .final = event { sawFinal += 1 }
        }
        XCTAssertEqual(sawStart, 1)
        XCTAssertEqual(sawFinal, 0, "sub-minimum utterances are rejected")
    }

    func testHysteresisKeepsUtteranceAliveBetweenThresholds() async {
        // Probabilities hovering between stop (0.35) and start (0.5) while
        // triggered must count as continued speech, not silence.
        let endSilenceMs = 500
        let tailSilence = endSilenceMs / Config.vadFrameMs + 1
        let probs =
            [Float](repeating: 0.9, count: 10)
            + [Float](repeating: 0.42, count: 30)   // between thresholds
            + [Float](repeating: 0.1, count: tailSilence)

        let events = await run(probs: probs, endSilenceMs: endSilenceMs)

        var finals = 0
        for event in events {
            if case .final = event { finals += 1 }
        }
        XCTAssertEqual(finals, 1, "mid-band probabilities must not split the utterance")
    }
}
