import Foundation
import HFAPI
import MLXLLM
import MLXLMCommon

/// Minimal continuation-style prompt. Small models can't reliably follow
/// multi-rule instructions; this format gives them almost no room to
/// hallucinate — they just produce the next line.
func buildTranslationPrompt(targetLanguage: String, text: String) -> String {
    "Translate to \(targetLanguage). Output only the translation.\n\nSource: \(text)\n\(targetLanguage): "
}

/// Single MLX-swift-lm backed translator. Both quality tiers share this class —
/// only the model id differs. Reasoning is disabled via `enable_thinking: false`
/// in the chat template context.
final class MLXChatTranslator: @unchecked Sendable {
    // ChatSession is not Sendable per mlx-swift-lm docs but is documented safe
    // for one caller at a time (the underlying ModelContainer handles isolation).
    private let session: ChatSession
    /// Mutable so the engine can apply a target-language change without
    /// reloading the whole model — we're just swapping the prompt template.
    var targetLanguage: String

    private init(session: ChatSession, targetLanguage: String) {
        self.session = session
        self.targetLanguage = targetLanguage
    }

    static func load(
        modelId: String,
        targetLanguage: String,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MLXChatTranslator {
        FileHandle.standardError.write("[llm] loading \(modelId) ...\n".data(using: .utf8) ?? Data())

        let container = try await loadModelContainer(
            from: HubClient.default,
            using: TokenizersLoader(),
            id: modelId,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                let pct = Int(fraction * 100)
                let desc = progress.localizedDescription ?? ""
                FileHandle.standardError.write(
                    "[llm] \(desc) \(pct)%\r".data(using: .utf8) ?? Data()
                )
                onProgress?(fraction, desc)
            }
        )

        let session = ChatSession(
            container,
            additionalContext: ["enable_thinking": false]
        )
        FileHandle.standardError.write("\n[llm] ready.\n".data(using: .utf8) ?? Data())
        return MLXChatTranslator(session: session, targetLanguage: targetLanguage)
    }

    private func prompt(for text: String) -> String {
        buildTranslationPrompt(targetLanguage: targetLanguage, text: text)
    }

    func translate(_ text: String) async throws -> String {
        await session.clear()
        return try await session.respond(to: prompt(for: text))
    }

    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        let p = prompt(for: text)
        return AsyncThrowingStream { continuation in
            Task {
                await self.session.clear()
                do {
                    for try await chunk in self.session.streamResponse(to: p, images: [], videos: []) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
