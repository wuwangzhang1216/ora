import Foundation

/// Deliberately exposes no upstream response body: errors may echo private speech.
enum RealRouterError: LocalizedError {
    case invalidURL, missingKey, missingModel, unsupportedModel, badStatus(Int)
    case failedResponse, incompleteStream, emptyResponse, invalidStream
    case invalidTranscription, invalidAudio, audioTooLarge, probeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTPS server URL, or HTTP on localhost, without credentials or query parameters."
        case .missingKey: return "Save your RealRouter API key in Preferences first."
        case .missingModel: return "Choose a RealRouter model in Preferences."
        case .unsupportedModel: return "The selected model is unavailable or does not support streamed Responses. Check the model name and key access."
        case .badStatus(401): return "RealRouter rejected the API key (HTTP 401)."
        case .badStatus(402): return "RealRouter requires available credit or a subscription (HTTP 402)."
        case .badStatus(429): return "RealRouter is busy or rate limited (HTTP 429). Try again shortly."
        case .badStatus(let status): return "RealRouter returned HTTP \(status)."
        case .failedResponse: return "RealRouter could not complete this translation."
        case .incompleteStream: return "RealRouter disconnected before confirming a complete translation."
        case .emptyResponse: return "RealRouter returned no translated text."
        case .invalidStream: return "RealRouter returned an invalid translation stream."
        case .invalidTranscription: return "RealRouter returned an invalid speech transcription."
        case .invalidAudio: return "There is no speech audio to transcribe."
        case .audioTooLarge: return "Speech audio exceeds the RealRouter 25 MiB limit."
        case .probeUnavailable: return "Could not synthesize the speech test. Check that an English system voice is installed."
        }
    }
}

/// Parses complete SSE events, including multiline data and heartbeat comments.
/// A 200 or a [DONE] marker alone never makes a failed/truncated response valid.
struct RealRouterEventParser {
    enum Event { case delta(String), completed }
    private var data: [String] = []
    private var dataSize = 0
    private(set) var completed = false
    private var hasText = false

    mutating func receive(_ line: String) throws -> Event? {
        if line.isEmpty { return try flush() }
        guard line.hasPrefix("data:") else { return nil }
        let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        dataSize += value.utf8.count
        guard dataSize <= 262_144 else { throw RealRouterError.invalidStream }
        data.append(value)
        return nil
    }

    mutating func flush() throws -> Event? {
        guard !data.isEmpty else { return nil }
        let payload = data.joined(separator: "\n")
        data.removeAll(keepingCapacity: true)
        dataSize = 0
        if payload == "[DONE]" {
            guard completed else { throw RealRouterError.incompleteStream }
            return nil
        }
        guard let value = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let type = value["type"] as? String else { throw RealRouterError.invalidStream }
        switch type {
        case "response.output_text.delta":
            guard !completed, let delta = value["delta"] as? String else { throw RealRouterError.invalidStream }
            hasText = hasText || !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return .delta(delta)
        case "response.completed":
            guard let response = value["response"] as? [String: Any],
                  response["status"] as? String == "completed",
                  response["error"] == nil || response["error"] is NSNull else {
                throw RealRouterError.failedResponse
            }
            completed = true
            return .completed
        case "error", "response.failed", "response.incomplete", "response.cancelled":
            throw RealRouterError.failedResponse
        default: return nil
        }
    }

    func validateCompletion() throws {
        guard completed else { throw RealRouterError.incompleteStream }
        guard hasText else { throw RealRouterError.emptyResponse }
    }
}

final class RealRouterSessionDelegate: NSObject, URLSessionTaskDelegate {
    // Never forward a bearer key or meeting text through an HTTP redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class RealRouterTranslator: TranslationBackend, @unchecked Sendable {
    private struct Models: Decodable {
        struct Model: Decodable {
            struct Capabilities: Decodable {
                let supports_responses: Bool?
                let supports_streaming: Bool?
                let reasoning_efforts: [String]?
            }
            let id: String
            let x_realrouter: Capabilities?
        }
        let data: [Model]
    }
    private struct RequestBody: Encodable {
        struct Reasoning: Encodable { let effort: String }
        let model: String
        let input: [TranslationMessage]
        let reasoning: Reasoning?
        let service_tier: String?
        let stream = true
        let tool_choice = "none"
        let max_output_tokens: Int
    }

    let baseURL: URL
    private let model: String
    private let apiKey: String
    private let session: URLSession
    private let targetLock = NSLock()
    private var target: String
    private var reasoningEffort: String?
    var targetLanguage: String {
        get { targetLock.lock(); defer { targetLock.unlock() }; return target }
        set { targetLock.lock(); defer { targetLock.unlock() }; target = newValue }
    }

    static func normalizedBaseURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw RealRouterError.invalidURL }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.hasSuffix("/v1") { parts.path.removeLast(3) }
        guard let url = parts.url else { throw RealRouterError.invalidURL }
        return url
    }

    init(baseURL: String, model: String, apiKey: String, targetLanguage: String,
         session: URLSession? = nil) throws {
        self.baseURL = try Self.normalizedBaseURL(baseURL)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.model.isEmpty else { throw RealRouterError.missingModel }
        guard !self.apiKey.isEmpty else { throw RealRouterError.missingKey }
        self.target = targetLanguage
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config, delegate: RealRouterSessionDelegate(), delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    static func load(baseURL: String, model: String, apiKey: String,
                     targetLanguage: String) async throws -> RealRouterTranslator {
        let translator = try RealRouterTranslator(baseURL: baseURL, model: model, apiKey: apiKey,
                                                  targetLanguage: targetLanguage)
        try await translator.checkServer()
        return translator
    }

    func checkServer() async throws {
        let (data, response) = try await session.data(for: request(path: "v1/models"))
        try validate(response)
        guard let models = try? JSONDecoder().decode(Models.self, from: data) else {
            throw RealRouterError.invalidStream
        }
        guard let selected = models.data.first(where: { $0.id == model }),
              selected.x_realrouter?.supports_responses != false,
              selected.x_realrouter?.supports_streaming != false else { throw RealRouterError.unsupportedModel }
        if model == "gpt-6-luna" {
            guard selected.x_realrouter?.reasoning_efforts?.contains("low") == true else {
                throw RealRouterError.unsupportedModel
            }
            reasoningEffort = "low"
        } else if let efforts = selected.x_realrouter?.reasoning_efforts {
            reasoningEffort = efforts.contains("none") ? "none" : efforts.contains("low") ? "low" : efforts.first
        }
    }

    func translate(_ text: String) async throws -> String {
        var result = ""
        for try await chunk in translateStream(text, history: []) { result += chunk }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translateStream(_ text: String, history: [TranslationExchange]) -> AsyncThrowingStream<String, Error> {
        let body = RequestBody(model: model,
                               input: buildTranslationMessages(targetLanguage: targetLanguage, text: text, history: history),
                               reasoning: reasoningEffort.map { RequestBody.Reasoning(effort: $0) },
                               service_tier: model == "gpt-6-luna" ? "priority" : nil,
                               max_output_tokens: translationTokenBudget(for: text))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = self.request(path: "v1/responses")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await self.session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try self.validate(response)
                    var parser = RealRouterEventParser()
                    var lineBytes = Data()
                    // AsyncBytes.lines can omit empty lines. SSE uses those
                    // empty lines as event boundaries, so preserve them here.
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard lineBytes.count < 262_144 else { throw RealRouterError.invalidStream }
                        if byte != 10 { lineBytes.append(byte); continue }
                        if lineBytes.last == 13 { lineBytes.removeLast() }
                        guard let line = String(data: lineBytes, encoding: .utf8) else { throw RealRouterError.invalidStream }
                        lineBytes.removeAll(keepingCapacity: true)
                        if let event = try parser.receive(line), case .delta(let text) = event {
                            continuation.yield(text)
                        }
                        if parser.completed { break }
                    }
                    if !lineBytes.isEmpty {
                        if lineBytes.last == 13 { lineBytes.removeLast() }
                        guard let line = String(data: lineBytes, encoding: .utf8) else { throw RealRouterError.invalidStream }
                        _ = try parser.receive(line)
                    }
                    if let event = try parser.flush(), case .delta(let text) = event { continuation.yield(text) }
                    try parser.validateCompletion()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RealRouterError.invalidStream }
        guard (200..<300).contains(http.statusCode) else { throw RealRouterError.badStatus(http.statusCode) }
    }
}
