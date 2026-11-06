@preconcurrency import AVFoundation
import Foundation
import Speech

/// SpeechAnalyzer's range replacements are scoped to the current utterance;
/// final ranges and the revisable tail are assembled in audio-time order.
struct SpeechResultText {
    private struct Part {
        let start: Double
        let end: Double
        let text: String
    }
    private var parts: [Part] = []
    var text: String { parts.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    mutating func update(start: Double, end: Double, text: String) {
        parts.removeAll { $0.start < end && $0.end > start || $0.start == start }
        parts.append(Part(start: start, end: end, text: text))
        parts.sort { $0.start < $1.start }
    }
}

@available(macOS 26.0, *)
actor AppleSpeechASRClient: SpeechRecognitionBackend {
    nonisolated let isStreaming = true
    private let format: AVAudioFormat
    private let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var cursor = StreamingRecognitionCursor()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var transcript = SpeechResultText()
    private var generation = UUID()
    private var revision = 0
    private var failure: Error?

    private init(format: AVAudioFormat) { self.format = format }

    static func load() async throws -> AppleSpeechASRClient {
        guard SpeechTranscriber.isAvailable else {
            throw APILocalBenchmark.BenchmarkError.configuration("Apple SpeechTranscriber is unavailable on this Mac.")
        }
        let module = makeTranscriber()
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            FileHandle.standardError.write(Data("[apple-asr] Installing on-device English assets…\n".utf8))
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw APILocalBenchmark.BenchmarkError.configuration("No compatible Apple speech audio format.")
        }
        return AppleSpeechASRClient(format: format)
    }

    private static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        try await transcribe(audio, id: UUID(), final: true)
    }

    func transcribe(_ audio: [Float], id: UUID, final: Bool) async throws -> String {
        let next = cursor.consume(audio, id: id)
        if next.restart || analyzer == nil { try await beginSession() }
        if let failure { throw failure }
        let before = revision
        if !next.delta.isEmpty { try feed(next.delta) }
        if final, let analyzer {
            input?.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
            self.analyzer = nil
            input = nil
            if let failure { throw failure }
        } else {
            // Results are asynchronous. Allow a bounded chance for this input
            // to produce a volatile update; the next snapshot coalesces ahead.
            let deadline = ContinuousClock.now + .milliseconds(250)
            while revision == before && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                if let failure { throw failure }
            }
        }
        return transcript.text
    }

    private func beginSession() async throws {
        if let analyzer { await analyzer.cancelAndFinishNow() }
        resultsTask?.cancel()
        let token = UUID()
        generation = token
        failure = nil
        transcript = SpeechResultText()
        revision = 0
        let module = Self.makeTranscriber()
        let pair = AsyncStream<AnalyzerInput>.makeStream()
        input = pair.continuation
        converter = AVAudioConverter(from: sourceFormat, to: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    await self?.receive(start: result.range.start.seconds, end: result.range.end.seconds,
                        text: String(result.text.characters), generation: token)
                }
            } catch {
                await self?.failed(error, generation: token)
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: pair.stream)
    }

    private func receive(start: Double, end: Double, text: String, generation: UUID) {
        guard self.generation == generation else { return }
        transcript.update(start: start, end: end, text: text)
        revision += 1
    }

    private func failed(_ error: Error, generation: UUID) {
        if self.generation == generation { failure = error }
    }

    private func feed(_ samples: [Float]) throws {
        guard let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * format.sampleRate / 16_000) + 1024)) else {
            throw APILocalBenchmark.BenchmarkError.configuration("Cannot allocate Apple speech conversion buffers.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error else {
            throw APILocalBenchmark.BenchmarkError.configuration("Apple speech audio conversion failed.")
        }
        if output.frameLength > 0 { input?.yield(AnalyzerInput(buffer: output)) }
    }
}
