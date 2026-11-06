import AVFoundation
import Foundation

/// RealRouter accepts completed audio files, not a streaming recognition
/// connection. Short, rate-limited rolling WAV snapshots provide provisional
/// captions; the VAD-finalized utterance is always transcribed again in full.
final class RealRouterSpeechRecognizer: SpeechRecognitionBackend, @unchecked Sendable {
    private let baseURL: URL
    private let key: String
    private let language: String?
    private let session: URLSession
    let partialPolicy = RecognitionPartialPolicy.api

    init(baseURL: String, apiKey: String, language: String?, session: URLSession? = nil) throws {
        self.baseURL = try RealRouterTranslator.normalizedBaseURL(baseURL)
        key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RealRouterError.missingKey }
        self.language = language
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 45
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config, delegate: RealRouterSessionDelegate(), delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    func checkServer() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RealRouterError.invalidTranscription }
        guard (200..<300).contains(http.statusCode) else { throw RealRouterError.badStatus(http.statusCode) }
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        try Task.checkCancellation()
        let wav = try Self.wav(audio)
        let boundary = "Ora-" + UUID().uuidString
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", "whisper-1") // compatibility label; server chooses the actual upstream model
        field("response_format", "json")
        if let language, !language.isEmpty { field("language", language) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RealRouterError.invalidTranscription }
        guard (200..<300).contains(http.statusCode) else { throw RealRouterError.badStatus(http.statusCode) }
        struct Transcription: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Transcription.self, from: data) else {
            throw RealRouterError.invalidTranscription
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono PCM16 WAV, in memory only. No audio recordings on disk.
    static func wav(_ audio: [Float]) throws -> Data {
        guard !audio.isEmpty else { throw RealRouterError.invalidAudio }
        guard audio.count <= (25 * 1024 * 1024 - 44) / 2 else { throw RealRouterError.audioTooLarge }
        var data = Data()
        data.reserveCapacity(44 + audio.count * 2)
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(audio.count * 2)
        text("RIFF"); integer(bytes + 36); text("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(Config.sampleRate)); integer(UInt32(Config.sampleRate * 2))
        integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(bytes)
        for sample in audio {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            integer(Int16((value * 32_767).rounded()))
        }
        return data
    }
}

/// A controlled synthetic English sentence for the connection test. Uses the
/// Mac's speech synthesizer without playback or microphone capture.
@MainActor
private final class SpeechProbeSynthesizer {
    let synthesizer = AVSpeechSynthesizer()
}

@MainActor
enum RealRouterSpeechProbe {
    static let sentence = "The meeting starts at ten."

    static func audio() async throws -> [Float] {
        guard let voice = AVSpeechSynthesisVoice(language: "en-US"),
              let resampler = AudioResampler() else { throw RealRouterError.probeUnavailable }
        let owner = SpeechProbeSynthesizer()
        defer { withExtendedLifetime(owner) {} }
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { continuation.finish(throwing: RealRouterError.probeUnavailable) }
            }
            owner.synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    continuation.finish(throwing: RealRouterError.probeUnavailable)
                    return
                }
                if pcm.frameLength == 0 { continuation.finish(); return }
                guard let audio = resampler.resample(pcm) else {
                    continuation.finish(throwing: RealRouterError.probeUnavailable)
                    return
                }
                continuation.yield(audio)
            }
            continuation.onTermination = { [weak owner] _ in
                timeout.cancel()
                Task { @MainActor in owner?.synthesizer.stopSpeaking(at: .immediate) }
            }
        }
        var audio: [Float] = []
        for try await chunk in stream {
            try Task.checkCancellation()
            audio.append(contentsOf: chunk)
        }
        guard !audio.isEmpty else { throw RealRouterError.probeUnavailable }
        return audio
    }
}
