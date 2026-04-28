import AVFoundation
import Foundation

/// Converts arbitrary-format AVAudioPCMBuffer input into 16 kHz mono Float32
/// `[Float]` chunks ready for the VAD/ASR pipeline. Shared by both the
/// microphone path (`MicrophoneCapture`) and the system audio path
/// (`SystemAudioCapture`) so the resampling math lives in exactly one place.
final class AudioResampler {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init?() {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Config.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.targetFormat = fmt
    }

    /// Resample `buffer` into a flat `[Float]` at 16 kHz mono. Returns nil on
    /// conversion failure. Reuses the underlying `AVAudioConverter` as long as
    /// the input format is unchanged.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let inFormat = buffer.format

        if converter == nil
            || converter?.inputFormat.sampleRate != inFormat.sampleRate
            || converter?.inputFormat.channelCount != inFormat.channelCount
        {
            guard let conv = AVAudioConverter(from: inFormat, to: targetFormat) else {
                return nil
            }
            converter = conv
        }
        guard let conv = converter else { return nil }

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return nil }

        var error: NSError?
        var consumed = false
        conv.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }

        guard let channels = outBuffer.floatChannelData else { return nil }
        let count = Int(outBuffer.frameLength)
        if count == 0 { return [] }
        return Array(UnsafeBufferPointer(start: channels[0], count: count))
    }
}
