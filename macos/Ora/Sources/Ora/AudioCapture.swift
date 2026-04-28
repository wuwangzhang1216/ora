import AVFoundation
import Foundation

/// Captures microphone audio via AVAudioEngine and yields resampled 16 kHz
/// mono Float32 chunks via `AudioResampler`. Mirrors the Python sounddevice
/// callback pattern. One of the two `AudioSource` implementations; the other
/// is `SystemAudioCapture`.
final class MicrophoneCapture: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler: AudioResampler

    init?() {
        guard let resampler = AudioResampler() else { return nil }
        self.resampler = resampler
    }

    /// Start recording. Yields resampled 16 kHz float32 chunks until the task
    /// is cancelled.
    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [resampler] buffer, _ in
                guard let samples = resampler.resample(buffer), !samples.isEmpty else { return }
                continuation.yield(samples)
            }

            do {
                try engine.start()
            } catch {
                FileHandle.standardError.write(
                    "[mic] engine start failed: \(error)\n".data(using: .utf8) ?? Data()
                )
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }
        }
    }
}
