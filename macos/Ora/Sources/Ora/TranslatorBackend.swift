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

protocol TranslationBackend: AnyObject, Sendable {
    var targetLanguage: String { get set }

    func translate(_ text: String) async throws -> String
    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error>
}

/// Single MLX-swift-lm backed translator. Both quality tiers share this class —
/// only the model id differs. Reasoning is disabled via `enable_thinking: false`
/// in the chat template context.
final class MLXChatTranslator: TranslationBackend, @unchecked Sendable {
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

enum RapidMLXError: LocalizedError {
    case invalidBaseURL(String)
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Invalid Rapid-MLX URL: \(value)"
        case .badStatus(let status, let body):
            return "Rapid-MLX returned HTTP \(status): \(body)"
        case .emptyResponse:
            return "Rapid-MLX returned an empty response"
        }
    }
}

/// OpenAI-compatible HTTP translator for a locally running Rapid-MLX server.
///
/// Ora does not manage the Rapid-MLX process. Start it separately, for example:
///
///   rapid-mlx serve qwen3.5-4b --served-model-name default --port 8000 --no-thinking
final class RapidMLXTranslator: TranslationBackend, @unchecked Sendable {
    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let temperature: Double
        let top_p: Double
        let max_tokens: Int
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }

            let delta: Delta?
        }

        let choices: [Choice]
    }

    private let model: String
    private let baseURL: String
    var targetLanguage: String

    private var chatCompletionsURL: URL {
        get throws {
            guard let url = URL(string: "\(baseURL)/chat/completions") else {
                throw RapidMLXError.invalidBaseURL(baseURL)
            }
            return url
        }
    }

    private var modelsURL: URL {
        get throws {
            guard let url = URL(string: "\(baseURL)/models") else {
                throw RapidMLXError.invalidBaseURL(baseURL)
            }
            return url
        }
    }

    private init(baseURL: String, model: String, targetLanguage: String) {
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.model = model
        self.targetLanguage = targetLanguage
    }

    static func load(
        baseURL: String,
        model: String,
        targetLanguage: String
    ) async throws -> RapidMLXTranslator {
        let translator = RapidMLXTranslator(baseURL: baseURL, model: model, targetLanguage: targetLanguage)
        try await translator.checkServer()
        try await translator.warmup()
        return translator
    }

    func translate(_ text: String) async throws -> String {
        let request = try makeRequest(text: text, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw RapidMLXError.emptyResponse
        }
        return content
    }

    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try self.makeRequest(text: text, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try self.validate(response: response, body: nil)

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }

                        let payload: String
                        if trimmed.hasPrefix("data:") {
                            payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            payload = trimmed
                        }

                        if payload == "[DONE]" {
                            break
                        }

                        let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8))
                        if let token = chunk.choices.first?.delta?.content, !token.isEmpty {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func checkServer() async throws {
        let (data, response) = try await URLSession.shared.data(from: try modelsURL)
        try validate(response: response, body: data)
    }

    private func warmup() async throws {
        let request = try makeRequest(text: "hi", stream: false, maxTokens: 1, temperature: 0.0)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
    }

    private func makeRequest(
        text: String,
        stream: Bool,
        maxTokens: Int = 512,
        temperature: Double = 0.3
    ) throws -> URLRequest {
        let prompt = buildTranslationPrompt(targetLanguage: targetLanguage, text: text)
        let body = ChatRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt)],
            stream: stream,
            temperature: temperature,
            top_p: 0.9,
            max_tokens: maxTokens
        )

        var request = URLRequest(url: try chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30
        return request
    }

    private func validate(response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let text = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw RapidMLXError.badStatus(http.statusCode, text)
        }
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
