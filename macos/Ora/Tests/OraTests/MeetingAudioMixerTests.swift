import XCTest
@testable import Ora

final class MeetingAudioMixerTests: XCTestCase {
    func testBothSidesOfConversationReachTheSegmentationPipeline() async {
        var mixer = MeetingAudioMixer()
        mixer.append(Array(repeating: 0.8, count: 8_000), from: .system, at: 100)
        mixer.append(Array(repeating: -0.8, count: 8_000), from: .microphone, at: 100.9)
        let frames = mixer.render(until: 102)
        let source = AsyncStream<[Float]> { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
        let vad = VADSegmenter(probe: { audio in
            audio.contains { abs($0) > 0.2 } ? 0.9 : 0.1
        })
        var utterances: [[Float]] = []
        for await event in vad.events(from: source, endSilenceMs: 300, partialIntervalS: 0) {
            if case .final(let audio) = event { utterances.append(audio) }
        }
        XCTAssertEqual(utterances.count, 2, "both participants must produce an utterance")
        if utterances.count == 2 {
            XCTAssertTrue(utterances[0].contains { $0 > 0.3 })
            XCTAssertTrue(utterances[1].contains { $0 < -0.3 })
        }
    }

    func testEarlierFirstBufferCanArriveDuringStartupJitterWindow() {
        var mixer = MeetingAudioMixer(sampleRate: 100, frameSamples: 10, capacity: 200)
        mixer.append(Array(repeating: 0.4, count: 10), from: .microphone, at: 100.1)
        mixer.append(Array(repeating: 0.8, count: 10), from: .system, at: 100)
        let audio = mixer.render(until: 100.2).flatMap { $0 }
        XCTAssertEqual(audio.count, 20)
        XCTAssertEqual(audio.first, 0.4)
        XCTAssertEqual(audio.last, 0.2)
    }

    func testBothInputsShareOneTimelineDespiteDifferentCallbackSizesAndOrder() {
        var mixer = MeetingAudioMixer(sampleRate: 100, frameSamples: 10, capacity: 200)
        mixer.append(Array(repeating: 0.8, count: 100), from: .system, at: 100)
        mixer.append(Array(repeating: 0.4, count: 50), from: .microphone, at: 100.5)
        mixer.append(Array(repeating: 0.2, count: 50), from: .microphone, at: 100)
        let audio = mixer.render(until: 101).flatMap { $0 }
        XCTAssertEqual(audio.count, 100, "one second from two inputs must stay one second")
        XCTAssertEqual(audio[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(audio[49], 0.5, accuracy: 0.0001)
        XCTAssertEqual(audio[50], 0.6, accuracy: 0.0001)
        XCTAssertEqual(audio[99], 0.6, accuracy: 0.0001)
        XCTAssertTrue(mixer.render(until: 101).isEmpty)
    }

    func testTurnTakingAndSilentSourceDoNotLoseEitherSideOrStall() {
        var mixer = MeetingAudioMixer(sampleRate: 100, frameSamples: 10, capacity: 200)
        mixer.append(Array(repeating: 0.8, count: 30), from: .system, at: 0)
        mixer.append(Array(repeating: -0.6, count: 30), from: .microphone, at: 0.5)
        let audio = mixer.render(until: 1).flatMap { $0 }
        XCTAssertEqual(audio.count, 100)
        XCTAssertEqual(audio[29], 0.4, accuracy: 0.0001)
        XCTAssertEqual(audio[30], 0)
        XCTAssertEqual(audio[49], 0)
        XCTAssertEqual(audio[50], -0.3, accuracy: 0.0001)
        XCTAssertEqual(audio[79], -0.3, accuracy: 0.0001)
        XCTAssertEqual(audio[80], 0)
    }

    func testLateBuffersCannotReplayConsumedSpeech() {
        var mixer = MeetingAudioMixer(sampleRate: 100, frameSamples: 10, capacity: 200)
        mixer.append(Array(repeating: 1, count: 20), from: .system, at: 0)
        XCTAssertEqual(mixer.render(until: 0.2).count, 2)
        mixer.append(Array(repeating: 0.8, count: 30), from: .microphone, at: 0.1)
        let audio = mixer.render(until: 0.4).flatMap { $0 }
        XCTAssertEqual(audio.count, 20)
        XCTAssertTrue(audio.allSatisfy { abs($0 - 0.4) < 0.0001 })
    }

    func testJitterDeadlineRetainsUnrenderedSamplesAndProtectsHeadroom() {
        var mixer = MeetingAudioMixer(sampleRate: 100, frameSamples: 10, capacity: 200)
        mixer.append(Array(repeating: 1, count: 20), from: .system, at: 0)
        XCTAssertTrue(mixer.render(until: 0.09).isEmpty)
        mixer.append(Array(repeating: 1, count: 20), from: .microphone, at: 0)
        XCTAssertTrue(mixer.render(until: 0.2).flatMap { $0 }.allSatisfy { $0 == 1 })
    }

    func testLongStallIsBoundedAndRingCannotReplayOldSamples() {
        var mixer = MeetingAudioMixer(sampleRate: 100, frameSamples: 10, capacity: 100)
        mixer.append(Array(repeating: 1, count: 1000), from: .system, at: 0)
        let audio = mixer.render(until: 10).flatMap { $0 }
        XCTAssertEqual(audio.count, 100)
        XCTAssertTrue(audio.allSatisfy { $0 == 0 })
        mixer.append(Array(repeating: 0.4, count: 10), from: .microphone, at: 10)
        XCTAssertEqual(mixer.render(until: 10.1).first?.first, 0.2)
    }
}
