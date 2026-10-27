import AVFoundation
import XCTest
@testable import Ora

final class AudioResamplerTests: XCTestCase {
    func testNativeMicrophoneAndSystemFormatsConvertTo16kMonoWithoutAccumulatingDrift() throws {
        let system = try XCTUnwrap(AudioResampler())
        let microphone = try XCTUnwrap(AudioResampler())
        let systemBuffer = try makeBuffer(rate: 48_000, integer: false)
        let micBuffer = try makeBuffer(rate: 44_100, integer: true)
        for (resampler, buffer) in [(system, systemBuffer), (microphone, micBuffer)] {
            let samples = try XCTUnwrap(resampler.resample(buffer))
            // AVAudioConverter holds a short filter look-ahead on its first
            // call. This startup allowance must not grow with later buffers.
            XCTAssertEqual(Double(samples.count), 1_600, accuracy: 320)
            let steady = samples.dropFirst(320)
            let level = steady.reduce(0, +) / Float(steady.count)
            XCTAssertEqual(level, 0.25, accuracy: 0.02)
            var count = samples.count
            for _ in 0..<9 {
                count += try XCTUnwrap(resampler.resample(buffer)).count
            }
            XCTAssertEqual(Double(count), 16_000, accuracy: 320,
                           "conversion may buffer one filter window, never lose time per callback")
        }
    }

    func testFormatChangeWithTheSameRateAndChannelCountRebuildsConverter() throws {
        let resampler = try XCTUnwrap(AudioResampler())
        _ = try XCTUnwrap(resampler.resample(makeBuffer(rate: 48_000, integer: false)))
        let samples = try XCTUnwrap(resampler.resample(makeBuffer(rate: 48_000, integer: true)))
        XCTAssertEqual(Double(samples.count), 1_600, accuracy: 320)
        let steady = samples.dropFirst(320)
        XCTAssertEqual(steady.reduce(0, +) / Float(steady.count), 0.25, accuracy: 0.02)
    }

    private func makeBuffer(rate: Double, integer: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: integer ? .pcmFormatInt16 : .pcmFormatFloat32,
                                                sampleRate: rate, channels: 2, interleaved: integer))
        let count = AVAudioFrameCount(rate / 10)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        if integer {
            let data = try XCTUnwrap(buffer.int16ChannelData)
            for index in 0..<(Int(count) * 2) { data[0][index] = 8_192 }
        } else {
            let data = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<2 {
                for index in 0..<Int(count) { data[channel][index] = 0.25 }
            }
        }
        return buffer
    }
}
