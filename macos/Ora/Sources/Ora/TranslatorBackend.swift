import Foundation
import HFAPI
import MLXLLM
import MLXLMCommon

/// Minimal continuation-style prompt. Small models can't reliably follow
/// multi-rule instructions; this format gives them almost no room to
/// hallucinate — they just produce the next line.
///
/// `history` carries recent committed (source → translation) pairs as few-shot
/// continuation lines, so pronouns, register, and terminology stay consistent
/// across VAD segments instead of resetting at every utterance boundary.
func buildTranslationPrompt(
    targetLanguage: String,
    text: String,
    history: [TranslationExchange] = []
) -> String {
    var prompt = "Translate to \(targetLanguage). Output only the translation.\n\n"
    for exchange in history {
        prompt += "Source: \(exchange.source)\n\(targetLanguage): \(exchange.translation)\n\n"
    }
    prompt += "Source: \(text)\n\(targetLanguage): "
    return prompt
}

struct TranslationExchange: Equatable {
    let source: String
    let translation: String
}

/// Thread-safe rolling window of recent committed translations. Finals include
/// it as few-shot context; partials skip it to keep their prompts minimal.
final class TranslationContext: @unchecked Sendable {
    /// How many committed exchanges to carry. More context helps consistency
    /// but every pair is re-prefilled on each final, so keep the window small.
    static let maxExchanges = 4
    /// Outsized segments (15s run-on utterances) would dominate the prompt —
    /// skip them rather than truncate mid-sentence.
    static let maxExchangeChars = 300

    private let lock = NSLock()
    private var exchanges: [TranslationExchange] = []

    func note(source: String, translation: String) {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !dst.isEmpty,
              src.count + dst.count <= Self.maxExchangeChars else { return }
        lock.lock()
        defer { lock.unlock() }
        exchanges.append(TranslationExchange(source: src, translation: dst))
        if exchanges.count > Self.maxExchanges {
            exchanges.removeFirst(exchanges.count - Self.maxExchanges)
        }
    }

    func snapshot() -> [TranslationExchange] {
        lock.lock()
        defer { lock.unlock() }
        return exchanges
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        exchanges.removeAll()
    }
}

protocol TranslationBackend: AnyObject, Sendable {
    var targetLanguage: String { get set }

    /// Partial-path translation: minimal prompt, no context — transient and
    /// latency-critical.
    func translate(_ text: String) async throws -> String
    /// Final-path translation. `history` is the engine-owned rolling context;
    /// backends are stateless formatters so context survives backend reloads
    /// and can't drift between implementations.
    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error>
}

/// Serializes generation on the shared ChatSession: `clear()` + generate must
/// be atomic, otherwise a partial translate interleaving with a final's stream
/// leaves the partial's exchange in the session history.
private actor GenerationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Single MLX-swift-lm backed translator. Both quality tiers share this class —
/// only the model id differs. Reasoning is disabled via `enable_thinking: false`
/// in the chat template context.
final class MLXChatTranslator: TranslationBackend, @unchecked Sendable {
    // ChatSession is not Sendable per mlx-swift-lm docs but is documented safe
    // for one caller at a time — the GenerationGate enforces exactly that.
    private let session: ChatSession
    private let gate = GenerationGate()
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

        // NOTE: draft-model speculative decoding is architecturally
        // unavailable here — Qwen3.5's linear-attention layers use a
        // non-trimmable MambaCache and mlx-swift-lm's speculation needs
        // trimmable caches to roll back rejected tokens. See Config.swift.
        let container = try await Self.loadContainer(id: modelId, label: "llm", onProgress: onProgress)

        let session = ChatSession(
            container,
            // Bounded, caption-shaped generation matching the Rapid-MLX backend
            // config — the library default (temperature 0.6, unbounded tokens)
            // is tuned for open-ended chat, not captions, and an unbounded
            // runaway generation would stall the whole finals queue.
            generateParameters: GenerateParameters(
                maxTokens: 512,
                temperature: 0.3,
                topP: 0.9
            ),
            additionalContext: ["enable_thinking": false]
        )
        FileHandle.standardError.write("\n[llm] ready.\n".data(using: .utf8) ?? Data())
        return MLXChatTranslator(session: session, targetLanguage: targetLanguage)
    }

    private static func loadContainer(
        id: String,
        label: String,
        onProgress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ModelContainer {
        try await loadModelContainer(
            from: HubClient.default,
            using: TokenizersLoader(),
            id: id,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                let pct = Int(fraction * 100)
                let desc = progress.localizedDescription ?? ""
                FileHandle.standardError.write(
                    "[\(label)] \(desc) \(pct)%\r".data(using: .utf8) ?? Data()
                )
                onProgress?(fraction, desc)
            }
        )
    }

    func translate(_ text: String) async throws -> String {
        let p = buildTranslationPrompt(targetLanguage: targetLanguage, text: text)
        await gate.acquire()
        await session.clear()
        do {
            let result = try await session.respond(to: p)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        let p = buildTranslationPrompt(
            targetLanguage: targetLanguage,
            text: text,
            history: history
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.gate.acquire()
                await self.session.clear()
                do {
                    for try await chunk in self.session.streamResponse(to: p, images: [], videos: []) {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    await self.gate.release()
                    continuation.finish()
                } catch {
                    await self.gate.release()
                    continuation.finish(throwing: error)
                }
            }
            // Stop generating (not just consuming) when the caller walks away —
            // e.g. Stop Listening mid-stream.
            continuation.onTermination = { _ in task.cancel() }
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

    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest(
                        text: text,
                        stream: true,
                        history: history
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try self.validate(response: response, body: nil)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
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
            continuation.onTermination = { _ in task.cancel() }
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
        temperature: Double = 0.3,
        history: [TranslationExchange] = []
    ) throws -> URLRequest {
        let prompt = buildTranslationPrompt(targetLanguage: targetLanguage, text: text, history: history)
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
