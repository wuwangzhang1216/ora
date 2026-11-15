import AudioCommon
import Foundation

enum LocalSpeechModelCache {
    static let recognitionFiles = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]
    static let vadFiles = ["config.json", "silero_vad.mlmodelc/coremldata.bin",
                           "silero_vad.mlmodelc/model.mil", "silero_vad.mlmodelc/weights/weight.bin"]

    static func canLoadOffline(from directory: URL, requiredFiles: [String]) -> Bool {
        guard HuggingFaceDownloader.weightsExist(in: directory) else { return false }
        return requiredFiles.allSatisfy { name in
            let file = directory.appendingPathComponent(name)
            guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                return false
            }
            return attributes.isRegularFile == true && (attributes.fileSize ?? 0) > 0
        }
    }
}
