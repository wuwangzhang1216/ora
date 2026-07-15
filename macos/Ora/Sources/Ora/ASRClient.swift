import Foundation
import Qwen3ASR

/// Thin wrapper around Qwen3ASRModel. The underlying `transcribe(...)` is synchronous
/// and blocking, so this actor runs on its own dispatch-queue executor: the
/// seconds-long GPU call occupies that private thread instead of starving the
/// shared cooperative pool that every other task in the app runs on.
actor ASRClient {
    private let model: Qwen3ASRModel
    private let language: String?

    private let inferenceQueue = DispatchSerialQueue(label: "ora.asr.inference", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        inferenceQueue.asUnownedSerialExecutor()
    }

    private init(model: Qwen3ASRModel, language: String?) {
        self.model = model
        self.language = language
    }

    static func load(modelId: String, language: String?) async throws -> ASRClient {
        let m = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: { progress, status in
                let pct = Int(progress * 100)
                let msg = status.isEmpty ? "\(pct)%" : "\(status) (\(pct)%)"
                FileHandle.standardError.write("[asr] \(msg)\r".data(using: .utf8) ?? Data())
            }
        )
        FileHandle.standardError.write("\n[asr] ready.\n".data(using: .utf8) ?? Data())
        return ASRClient(model: m, language: language)
    }

    func transcribe(_ audio: [Float]) -> String {
        model.transcribe(
            audio: audio,
            sampleRate: Config.sampleRate,
            language: language
        )
    }
}
