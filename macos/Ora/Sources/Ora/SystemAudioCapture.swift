import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// System audio, optionally with the default microphone in the same SCK
/// capture session (macOS 15+). Both outputs share presentation timestamps;
/// separate resamplers preserve each device's native format and converter state.
final class SystemAudioCapture: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let resampler: AudioResampler
    private let microphoneResampler: AudioResampler?
    private let onError: @Sendable (String) -> Void
    private var scStream: SCStream?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private let sampleQueue = DispatchQueue(label: "com.wangzhangwu.ora.sysaudio", qos: .userInteractive)
    // All mutable capture state below is confined to sampleQueue.
    private var mixer: MeetingAudioMixer?
    private var timer: DispatchSourceTimer?
    private var terminated = false

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init(resampler: AudioResampler, microphoneResampler: AudioResampler?,
                 onError: @escaping @Sendable (String) -> Void) {
        self.resampler = resampler
        self.microphoneResampler = microphoneResampler
        self.onError = onError
        self.mixer = microphoneResampler == nil ? nil : MeetingAudioMixer()
        super.init()
    }

    static func create(includeMicrophone: Bool = false,
                       onError: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SystemAudioCapture {
        if includeMicrophone {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard granted else {
                throw CaptureError(message: "Meeting audio needs microphone access. Enable Ora in System Settings → Privacy & Security → Microphone, then start again.")
            }
        }
        guard let resampler = AudioResampler(),
              let micResampler = AudioResampler() else {
            throw CaptureError(message: "Could not initialize audio conversion.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError(message: "System audio unavailable. Allow Ora in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Ora. \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            throw CaptureError(message: "System audio unavailable: no display is available for capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = includeMicrophone
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCK requires video dimensions even though we never subscribe to video.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let capture = SystemAudioCapture(resampler: resampler,
                                         microphoneResampler: includeMicrophone ? micResampler : nil,
                                         onError: onError)
        let stream = SCStream(filter: filter, configuration: config, delegate: capture)
        try stream.addStreamOutput(capture, type: .audio, sampleHandlerQueue: capture.sampleQueue)
        if includeMicrophone {
            try stream.addStreamOutput(capture, type: .microphone, sampleHandlerQueue: capture.sampleQueue)
        }
        capture.scStream = stream
        return capture
    }

    func stream() -> AsyncStream<[Float]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Config.maxPendingAudioChunks)) { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.sampleQueue.async { self.endCapture() }
            }
            sampleQueue.async {
                guard !self.terminated, let stream = self.scStream else {
                    continuation.finish()
                    return
                }
                self.continuation = continuation
                stream.startCapture { [self] error in
                    sampleQueue.async {
                        // Stop can race the asynchronous start completion. Stop
                        // again once start has completed so capture cannot leak.
                        if self.terminated {
                            if error == nil { stream.stopCapture { _ in } }
                            return
                        }
                        if let error {
                            self.fail("Audio capture could not start: \(error.localizedDescription)")
                        } else if self.mixer != nil {
                            self.startMixTimer()
                        }
                    }
                }
            }
        }
    }

    private func startMixTimer() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, !self.terminated else { return }
            // 100 ms lets system and microphone callbacks arrive in either
            // order without adding an unbounded wait when one side is silent.
            let deadline = CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.1
            for frame in self.mixer?.render(until: deadline) ?? [] {
                self.continuation?.yield(frame)
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func endCapture() {
        guard !terminated else { return }
        terminated = true
        timer?.cancel()
        timer = nil
        continuation?.finish()
        continuation = nil
        scStream?.stopCapture { _ in }
    }

    private func fail(_ message: String) {
        guard !terminated else { return }
        endCapture()
        onError(message)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !terminated, sampleBuffer.isValid,
              type == .audio || (type == .microphone && microphoneResampler != nil),
              let description = sampleBuffer.formatDescription else { return }
        // Microphone format is native-device format, independent of config's
        // system-audio sampleRate/channelCount (including interleaved devices).
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let converter = type == .microphone ? microphoneResampler : resampler
        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
                pcm.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                guard let samples = converter?.resample(pcm), !samples.isEmpty else { return }
                if self.mixer != nil {
                    self.mixer?.append(samples, from: type == .audio ? .system : .microphone,
                                       at: sampleBuffer.presentationTimeStamp.seconds)
                } else {
                    self.continuation?.yield(samples)
                }
            }
        } catch {
            // Transient decode errors drop only this buffer.
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async {
            self.fail("Audio capture stopped: \(error.localizedDescription). Check audio permissions and start again.")
        }
    }
}
