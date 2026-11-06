import Foundation
import XCTest
@testable import Ora

final class RouterStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: String
        var finish = true
    }
    static var handler: ((URLRequest) throws -> Reply)?
    static var stopped: (() -> Void)?
    private var stopHandler: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        stopHandler = Self.stopped
        do {
            let reply = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": request.url!.path.hasSuffix("models") ? "application/json" : "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Split UTF-8 and SSE fields across transport callbacks.
            let data = Data(reply.body.utf8)
            for offset in stride(from: 0, to: data.count, by: 7) {
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count)))
            }
            if reply.finish { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stopHandler?() }
    static func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&bytes, maxLength: bytes.count)
            if n <= 0 { break }
            data.append(contentsOf: bytes.prefix(n))
        }
        return data
    }
}

final class RealRouterTranslatorTests: XCTestCase {
    private let modelJSON = """
    {"data":[{"id":"test-model","x_realrouter":{"supports_responses":true,"supports_streaming":true,"reasoning_efforts":["low","none"]}}]}
    """
    private let success = """
    : heartbeat
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"你好"}

    data: {"type":"response.output_text.delta","delta":"，世界。"}

    event: response.completed
    data: {"type":"response.completed","response":{"status":"completed","error":null}}

    data: [DONE]

    """

    override func tearDown() {
        RouterStub.handler = nil
        RouterStub.stopped = nil
        super.tearDown()
    }

    private func translator() throws -> RealRouterTranslator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterStub.self]
        return try RealRouterTranslator(baseURL: "http://127.0.0.1:8789/v1/", model: "test-model",
            apiKey: "test-key", targetLanguage: "Chinese", session: URLSession(configuration: config))
    }

    func testAuthenticatedStreamingRequestPreservesTranslationContextAndValidatesModelCapabilities() async throws {
        let models = modelJSON, stream = success
        RouterStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            if request.url!.path == "/v1/models" { return .init(body: models) }
            XCTAssertEqual(request.url!.path, "/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: RouterStub.requestBody(request)) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["tool_choice"] as? String, "none")
            let input = body["input"] as! [[String: String]]
            XCTAssertEqual(input.map { $0["role"]! }, ["system", "user", "assistant", "user"])
            XCTAssertTrue(input[0]["content"]!.contains("Chinese"))
            XCTAssertEqual(input[1]["content"], "Previous sentence")
            XCTAssertEqual(input[2]["content"], "上一句")
            XCTAssertEqual(input[3]["content"], "Hello, world.")
            return .init(body: stream)
        }
        let backend = try translator()
        try await backend.checkServer()
        var result = ""
        for try await token in backend.translateStream("Hello, world.", history: [
            .init(source: "Previous sentence", translation: "上一句")
        ]) { result += token }
        XCTAssertEqual(result, "你好，世界。")
    }

    func testServerFailureAfterTextCannotReturnACompletedTranslation() async throws {
        RouterStub.handler = { _ in .init(body: """
        data: {"type":"response.output_text.delta","delta":"partial"}

        data: {"type":"response.failed","response":{"status":"failed","error":{"message":"private speech"}}}

        """) }
        do {
            _ = try await translator().translate("Private source")
            XCTFail("a partial prefix from a failed API response must never be committed as a translation")
        } catch {
            XCTAssertTrue(error is RealRouterError)
            XCTAssertFalse(error.localizedDescription.contains("private speech"))
        }
    }

    func testEndOfStreamWithoutCompletionIsAnError() async throws {
        RouterStub.handler = { _ in .init(body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"unfinished\"}\n\n") }
        do {
            _ = try await translator().translate("hello")
            XCTFail("a disconnected stream must not count as success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disconnected")) }
    }

    func testLunaNegotiatesLowEffortWithFastTier() async throws {
        let stream = success
        RouterStub.handler = { request in
            if request.url!.path == "/v1/models" {
                return .init(body: "{\"data\":[{\"id\":\"gpt-6-luna\",\"x_realrouter\":{\"supports_responses\":true,\"supports_streaming\":true,\"reasoning_efforts\":[\"none\",\"low\"]}}]}")
            }
            let body = try JSONSerialization.jsonObject(with: RouterStub.requestBody(request)) as! [String: Any]
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
            XCTAssertEqual(body["service_tier"] as? String, "priority")
            return .init(body: stream)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterStub.self]
        let backend = try RealRouterTranslator(baseURL: "http://localhost:8789", model: "gpt-6-luna",
            apiKey: "test-key", targetLanguage: "Chinese", session: URLSession(configuration: config))
        try await backend.checkServer()
        let result = try await backend.translate("Hello")
        XCTAssertEqual(result, "你好，世界。")
    }

    func testLunaUsesFastPriorityTier() async throws {
        let stream = success
        RouterStub.handler = { request in
            let body = try JSONSerialization.jsonObject(with: RouterStub.requestBody(request)) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
            XCTAssertEqual(body["service_tier"] as? String, "priority")
            return .init(body: stream)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterStub.self]
        let backend = try RealRouterTranslator(baseURL: "http://localhost:8789", model: "gpt-6-luna",
            apiKey: "test-key", targetLanguage: "Chinese", session: URLSession(configuration: config))
        let result = try await backend.translate("Hello")
        XCTAssertEqual(result, "你好，世界。")
    }

    func testHTTP401FailsWithoutLeakingCredentialsOrResponseBody() async throws {
        RouterStub.handler = { _ in .init(status: 401, body: "test-key private speech") }
        do {
            try await translator().checkServer()
            XCTFail("invalid credentials must fail the connection test")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("test-key"))
            XCTAssertFalse(error.localizedDescription.contains("private speech"))
        }
    }

    func testUnavailableModelIsRejectedBeforeSendingSpeech() async throws {
        var paths: [String] = []
        RouterStub.handler = { request in
            paths.append(request.url!.path)
            return .init(body: "{\"data\":[]}")
        }
        do { try await translator().checkServer(); XCTFail("missing model should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
        XCTAssertEqual(paths, ["/v1/models"])
    }

    func testCancellingConsumerStopsTheNetworkRequest() async throws {
        let firstText = expectation(description: "first streamed text")
        let stopped = expectation(description: "network request cancelled")
        stopped.assertForOverFulfill = false
        RouterStub.handler = { _ in .init(body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n", finish: false) }
        RouterStub.stopped = { stopped.fulfill() }
        let backend = try translator()
        let task = Task {
            do {
                for try await _ in backend.translateStream("hello", history: []) { firstText.fulfill() }
            } catch { }
        }
        await fulfillment(of: [firstText], timeout: 3)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 3)
        await task.value
    }

    func testURLNormalizationAndTransportValidation() throws {
        XCTAssertEqual(try RealRouterTranslator.normalizedBaseURL(" http://localhost:8789/v1/ ").absoluteString,
                       "http://localhost:8789")
        XCTAssertEqual(try RealRouterTranslator.normalizedBaseURL("https://example.com/api/v1").absoluteString,
                       "https://example.com/api")
        for url in ["http://example.com", "file:///tmp/test", "https://user:password@example.com", "http://localhost:8789?key=secret"] {
            XCTAssertThrowsError(try RealRouterTranslator.normalizedBaseURL(url))
        }
        XCTAssertThrowsError(try RealRouterTranslator(baseURL: "http://localhost:8789", model: "test", apiKey: " ", targetLanguage: "Chinese"))
    }

    func testParserAcceptsMultilineEventsAndRejectsFalseCompletion() throws {
        var parser = RealRouterEventParser()
        for line in ["event: response.output_text.delta", "data: {\"type\":\"response.output_text.delta\",", "data: \"delta\":\"hello\"}", ""] {
            _ = try parser.receive(line)
        }
        _ = try parser.receive("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"failed\"}}")
        XCTAssertThrowsError(try parser.receive(""))
        var prematureDone = RealRouterEventParser()
        _ = try prematureDone.receive("data: [DONE]")
        XCTAssertThrowsError(try prematureDone.receive(""))
        var empty = RealRouterEventParser()
        _ = try empty.receive("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}")
        _ = try empty.receive("")
        XCTAssertThrowsError(try empty.validateCompletion())
    }


}
