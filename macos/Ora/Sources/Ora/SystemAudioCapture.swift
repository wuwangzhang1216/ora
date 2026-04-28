import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures the macOS system audio mixdown via ScreenCaptureKit and yields
/// resampled 16 kHz mono Float32 chunks via `AudioResampler`. Uses an
/// audio-only SCStream (minimum 2x2 video dimensions are required by the API
/// but we never subscribe to the video output, so no frames are delivered).
///
/// Requires the user to grant Screen Recording permission on first use — that
/// permission gate also covers system audio capture. If the user denies, the
/// `create()` factory returns nil and the engine surfaces an error phase.
final class SystemAudioCapture: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let resampler: AudioResampler
    private var scStream: SCStream?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private let sampleQueue = DispatchQueue(label: "com.wangzhangwu.ora.sysaudio", qos: .userInteractive)

    private init(resampler: AudioResampler) {
        self.resampler = resampler
        super.init()
    }

    /// Build a ready-to-start capture. Returns nil on resampler init failure,
    /// missing shareable displays, or any SCK configuration error (including
    /// the permission-denied case, which surfaces as a thrown error from
    /// `SCShareableContent.current`).
    static func create() async -> SystemAudioCapture? {
        guard let resampler = AudioResampler() else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                FileHandle.standardError.write(
                    "[system-audio] no displays available\n".data(using: .utf8) ?? Data()
                )
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // SCK requires non-zero video dims even for audio-only. We never
            // register a .screen output so frames are discarded server-side.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let capture = SystemAudioCapture(resampler: resampler)
            let stream = SCStream(filter: filter, configuration: config, delegate: capture)
            try stream.addStreamOutput(
                capture,
                type: .audio,
                sampleHandlerQueue: capture.sampleQueue
            )
            capture.scStream = stream
            return capture
        } catch {
            FileHandle.standardError.write(
                "[system-audio] create failed: \(error)\n".data(using: .utf8) ?? Data()
            )
            return nil
        }
    }

    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            self.continuation = continuation
            guard let scStream else {
                continuation.finish()
                return
            }
            scStream.startCapture { [weak self] error in
                if let error {
                    FileHandle.standardError.write(
                        "[system-audio] startCapture failed: \(error)\n".data(using: .utf8) ?? Data()
                    )
                    self?.continuation?.finish()
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.scStream?.stopCapture { _ in }
                self?.continuation = nil
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame
              )
        else { return }

        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                guard let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: abl.unsafePointer
                ) else { return }
                pcm.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                guard let samples = self.resampler.resample(pcm), !samples.isEmpty else { return }
                self.continuation?.yield(samples)
            }
        } catch {
            // Transient decode errors are non-fatal; drop the frame.
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            "[system-audio] stream stopped: \(error)\n".data(using: .utf8) ?? Data()
        )
        continuation?.finish()
    }
}
