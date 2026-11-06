import CoreML
import Foundation
import NemotronStreamingASR

/// Cache-aware CoreML recognition on a private serial executor. All sessions
/// share weights but never encoder/decoder state. Audio stays on this Mac.
actor NemotronASRClient: SpeechRecognitionBackend {
    static let modelID = "aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8"
    nonisolated let isStreaming = true
    nonisolated let commitsPartialTokens = true
    private let model: NemotronStreamingASRModel
    private var session: StreamingSession?
    private var cursor = StreamingRecognitionCursor()
    private var text = ""
    private let inferenceQueue = DispatchSerialQueue(label: "ora.nemotron.inference", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        inferenceQueue.asUnownedSerialExecutor()
    }

    private init(model: NemotronStreamingASRModel) { self.model = model }

    static func load() async throws -> NemotronASRClient {
        let model = try await NemotronStreamingASRModel.fromPretrained(
            modelId: modelID, computeUnits: .cpuAndNeuralEngine,
            progressHandler: { fraction, status in
                FileHandle.standardError.write(Data("[nemotron] \(status) (\(Int(fraction * 100))%)\n".utf8))
            })
        return NemotronASRClient(model: model)
    }

    func transcribe(_ audio: [Float]) throws -> String {
        try transcribe(audio, id: UUID(), final: true)
    }

    func transcribe(_ audio: [Float], id: UUID, final: Bool) throws -> String {
        let input = cursor.consume(audio, id: id)
        if input.restart || session == nil {
            session = try model.createSession(language: "en-US")
            text = ""
        }
        guard let session else { return "" }
        for result in try session.pushAudio(input.delta) { text = result.text }
        if final {
            for result in try session.finalize() { text = result.text }
            self.session = nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
