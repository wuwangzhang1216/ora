import AVFoundation
import XCTest
@testable import Ora

final class RealRouterSpeechRecognizerTests: XCTestCase {
    override func tearDown() {
        RouterStub.handler = nil
        RouterStub.stopped = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterStub.self]
        return URLSession(configuration: config)
    }

    private func recognizer(language: String? = nil) throws -> RealRouterSpeechRecognizer {
        try RealRouterSpeechRecognizer(baseURL: "http://127.0.0.1:8789/v1/", apiKey: "test-key",
                                       language: language, session: session())
    }

    func testWAVIsReadable16kMonoPCMAndClampsInvalidSamples() throws {
        let audio: [Float] = [-2, 0, 2, .nan, .infinity, 0.5]
        let wav = try RealRouterSpeechRecognizer.wav(audio)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ora-test-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try wav.write(to: file)
        let reader = try AVAudioFile(forReading: file)
        XCTAssertEqual(reader.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 1)
        XCTAssertEqual(reader.length, 6)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 6))
        try reader.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for (index, expected) in [Float]([-1, 0, 1, 0, 0, 0.5]).enumerated() {
            XCTAssertEqual(samples[index], expected, accuracy: 0.001)
        }
        XCTAssertThrowsError(try RealRouterSpeechRecognizer.wav([]))
    }

    func testMultipartUploadUsesBearerAuthenticationAndLanguageHint() async throws {
        RouterStub.handler = { request in
            XCTAssertEqual(request.url!.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let type = request.value(forHTTPHeaderField: "Content-Type")!
            XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=Ora-"))
            let body = RouterStub.requestBody(request)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav"))
            XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nzh\r\n"))
            XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
            XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\njson\r\n"))
            XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
            XCTAssertNotNil(body.range(of: Data("WAVEfmt ".utf8)))
            return .init(body: "{\"text\":\"  大家好。  \"}")
        }
        let text = try await recognizer(language: "zh").transcribe([Float](repeating: 0.1, count: 16000))
        XCTAssertEqual(text, "大家好。")
    }

    func testAutomaticLanguageOmitsTheHint() async throws {
        RouterStub.handler = { request in
            XCTAssertFalse(String(decoding: RouterStub.requestBody(request), as: UTF8.self).contains("name=\"language\""))
            return .init(body: "{\"text\":\"Hello\"}")
        }
        let text = try await recognizer().transcribe([0, 0.1])
        XCTAssertEqual(text, "Hello")
    }

    func testSpeechFailuresDoNotBecomeRecognizedTextOrExposeResponseBodies() async throws {
        for response in [RouterStub.Reply(status: 401, body: "private audio test-key"),
                         RouterStub.Reply(body: "{\"error\":\"private audio test-key\"}")] {
            RouterStub.handler = { _ in response }
            do {
                _ = try await recognizer().transcribe([0.1, 0.2])
                XCTFail("a failed speech response must never become a recognized sentence")
            } catch {
                XCTAssertTrue(error is RealRouterError)
                XCTAssertFalse(error.localizedDescription.contains("private audio"))
                XCTAssertFalse(error.localizedDescription.contains("test-key"))
            }
        }
    }

    func testSpeechCancellationClosesTheUploadRequest() async throws {
        let started = expectation(description: "speech request started")
        let stopped = expectation(description: "speech request cancelled")
        stopped.assertForOverFulfill = false
        RouterStub.handler = { _ in
            started.fulfill()
            return .init(body: "", finish: false)
        }
        RouterStub.stopped = { stopped.fulfill() }
        let backend = try recognizer()
        let task = Task { try await backend.transcribe([Float](repeating: 0.1, count: 16000)) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 3)
        do { _ = try await task.value; XCTFail("cancelled audio must not be published") }
        catch { }
    }

    func testAPIPartialsRequireEnoughAudioGrowthAndElapsedTime() {
        var throttle = RecognitionPartialThrottle(policy: .api)
        let first = UUID(), second = UUID(), start = ContinuousClock.now
        XCTAssertFalse(throttle.allow(id: first, sampleCount: 8000, now: start))
        XCTAssertTrue(throttle.allow(id: first, sampleCount: 16000, now: start))
        XCTAssertFalse(throttle.allow(id: first, sampleCount: 32000, now: start + .milliseconds(500)))
        XCTAssertFalse(throttle.allow(id: first, sampleCount: 20000, now: start + .milliseconds(1500)))
        XCTAssertTrue(throttle.allow(id: first, sampleCount: 40000, now: start + .milliseconds(1600)))
        XCTAssertTrue(throttle.allow(id: second, sampleCount: 16000, now: start + .milliseconds(1700)))
        var local = RecognitionPartialThrottle(policy: .local)
        XCTAssertTrue(local.allow(id: first, sampleCount: 1, now: start))
        XCTAssertTrue(local.allow(id: first, sampleCount: 1, now: start))
    }

    func testSpeechAPIAndTranslationAPIWorkThroughTheSameCaptionPipeline() async throws {
        let translated = expectation(description: "translation from API-recognized speech")
        let sourceReady = expectation(description: "source recognized")
        sourceReady.assertForOverFulfill = false
        var paths: [String] = []
        RouterStub.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path == "/v1/audio/transcriptions" {
                return .init(body: "{\"text\":\"Hello world.\"}")
            }
            let body = try JSONSerialization.jsonObject(with: RouterStub.requestBody(request)) as! [String: Any]
            let messages = body["input"] as! [[String: String]]
            XCTAssertEqual(messages.last?["content"], "Hello world.")
            return .init(body: """
            data: {"type":"response.output_text.delta","delta":"你好，世界。"}

            data: {"type":"response.completed","response":{"status":"completed"}}

            """)
        }
        let asr = try recognizer()
        let translator = try RealRouterTranslator(baseURL: "http://127.0.0.1:8789", model: "test-model",
            apiKey: "test-key", targetLanguage: "Chinese", session: session())
        // Endpoint throttling has its own clock-controlled test above; this
        // test covers the real HTTP codecs plus agreement-based rendering.
        let pipe = PartialPipeline(transcribe: { try await asr.transcribe($0) }, backend: translator) { source, text, _ in
            XCTAssertEqual(source, "Hello world.")
            if text == nil { sourceReady.fulfill() }
            if text == "你好，世界。" { translated.fulfill() }
        }
        await pipe.start()
        let id = UUID()
        await pipe.submit([Float](repeating: 0.1, count: 16000), id: id)
        await fulfillment(of: [sourceReady], timeout: 3)
        await pipe.awaitQuiescence()
        await pipe.submit([Float](repeating: 0.1, count: 32000), id: id)
        await fulfillment(of: [translated], timeout: 3)
        await pipe.shutdown()
        XCTAssertEqual(paths, ["/v1/audio/transcriptions", "/v1/audio/transcriptions", "/v1/responses"])
    }

    @MainActor
    func testFinalSpeechUsesBothAPIsAndCommitsOneCorrectTranscript() async throws {
        var paths: [String] = []
        RouterStub.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path == "/v1/audio/transcriptions" {
                return .init(body: "{\"text\":\"We should ship on Friday.\"}")
            }
            return .init(body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"我们应该在周五发布。\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-api-final-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = try readyEngine(history: history)
        await engine.start(sourceOverride: ShortSpeechFixture())
        let deadline = ContinuousClock.now + .seconds(3)
        while history.currentSession.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(history.currentSession.count, 1)
        XCTAssertEqual(history.currentSession.first?.sourceText, "We should ship on Friday.")
        XCTAssertEqual(history.currentSession.first?.translationText, "我们应该在周五发布。")
        // Under-one-second speech must skip speculative API uploads, then
        // still receive its unthrottled final recognition and translation.
        XCTAssertEqual(paths, ["/v1/audio/transcriptions", "/v1/responses"])
        engine.stop()
        try await history.flush(sessionID: history.sessionId)
    }

    @MainActor
    func testFinalSpeechFailureStopsCaptureAndNeverSavesAnErrorAsSpeech() async throws {
        var paths: [String] = []
        RouterStub.handler = { request in
            paths.append(request.url!.path)
            return .init(status: 401, body: "private recording")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ora-api-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory)
        let engine = try readyEngine(history: history)
        await engine.start(sourceOverride: ShortSpeechFixture())
        let deadline = ContinuousClock.now + .seconds(3)
        while engine.phase == .listening, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if case .error(let message) = engine.phase {
            XCTAssertTrue(message.contains("401"))
            XCTAssertFalse(message.contains("private recording"))
        } else { XCTFail("speech failure must stop listening and surface an error") }
        XCTAssertTrue(history.currentSession.isEmpty)
        XCTAssertEqual(paths, ["/v1/audio/transcriptions"])
    }

    @MainActor
    private func readyEngine(history: TranscriptHistory) throws -> TranslatorEngine {
        let translator = try RealRouterTranslator(baseURL: "http://127.0.0.1:8789", model: "test-model",
            apiKey: "test-key", targetLanguage: "Chinese", session: session())
        return try TranslatorEngine(history: history, recognizer: recognizer(), translator: translator,
            segmenter: VADSegmenter(probe: { audio in audio.contains { abs($0) > 0.2 } ? 0.9 : 0.1 }))
    }

    @MainActor
    func testConnectionProbeProducesSpeechWithoutUsingAMicrophone() async throws {
        let audio = try await RealRouterSpeechProbe.audio()
        XCTAssertGreaterThan(audio.count, Config.sampleRate / 2)
        XCTAssertLessThan(audio.count, Config.sampleRate * 10)
        XCTAssertTrue(audio.contains { abs($0) > 0.01 })
        XCTAssertTrue(try RealRouterSpeechRecognizer.wav(audio).starts(with: Data("RIFF".utf8)))
    }
}

private final class ShortSpeechFixture: AudioSource, Sendable {
    func stream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            for index in 0..<40 {
                let voiced = (3..<23).contains(index)
                continuation.yield([Float](repeating: voiced ? 0.5 : 0, count: Config.vadFrameSamples))
            }
            continuation.finish()
        }
    }
}
