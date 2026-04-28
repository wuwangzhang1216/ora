import Foundation

/// Uniform interface for anything that produces 16 kHz mono Float32 audio
/// chunks for the VAD/ASR pipeline. Implemented by `MicrophoneCapture`
/// (AVAudioEngine mic input) and `SystemAudioCapture` (ScreenCaptureKit
/// system-wide loopback). The engine picks one based on user preference.
protocol AudioSource: AnyObject, Sendable {
    func stream() -> AsyncStream<[Float]>
}
