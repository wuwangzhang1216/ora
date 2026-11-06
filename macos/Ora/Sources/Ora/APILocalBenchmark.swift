import AVFoundation
import Foundation

/// Explicit audio-file replay only: never starts capture or exports credentials.
/// Run from a signed Ora bundle to reuse that bundle's own saved Keychain key.
enum APILocalBenchmark {
    struct Fixture: Codable {
        let id: String
        let language: String
        let targetLanguage: String
        let reference: String
        let referenceTranslation: String
        let audioPath: String
        var tailSilenceSeconds: Double? = nil
        var drainBudgetSeconds: Double? = nil
    }

    struct Row: Codable {
        let kind: String
        let mode: String
        let fixture: String
        let round: Int
        let audioSeconds: Double
        let reference: String
        let referenceTranslation: String
        let targetLanguage: String
        let recognized: String
        let translation: String
        let asrMS: Double
        let translationFirstTokenMS: Double?
        let translationTotalMS: Double
        let firstTranslationMS: Double?
        let totalMS: Double
        let error: String?
    }

    enum BenchmarkError: LocalizedError {
        case configuration(String)
        var errorDescription: String? {
            switch self { case .configuration(let value): return value }
        }
    }

    nonisolated static func runAndExit() -> Never {
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Benchmark stopped: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    @MainActor
    private static func run() async throws {
        let arguments = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains("--list-api-models") {
            let key = try RealRouterCredentials.load()
            let url = try RealRouterTranslator.normalizedBaseURL(Preferences.shared.realRouterURL)
            var request = URLRequest(url: url.appendingPathComponent("v1/models"))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw BenchmarkError.configuration("Could not list model capabilities.")
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = (object?["data"] as? [[String: Any]] ?? []).map { row in
                ["id": row["id"] ?? "", "capabilities": row["x_realrouter"] ?? [:]]
            }
            let output = try JSONSerialization.data(withJSONObject: models, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: output, as: UTF8.self))
            return
        }
        guard let mode = argument("--mode"), ["api", "local", "hybrid", "rapid"].contains(mode),
              let manifest = argument("--manifest"), let output = argument("--output"),
              let repeats = Int(argument("--repeats") ?? "2"), (1...5).contains(repeats) else {
            throw BenchmarkError.configuration("Use --mode api|local|hybrid|rapid --manifest FILE --output FILE [--repeats 2].")
        }
        guard !FileManager.default.fileExists(atPath: output) else {
            throw BenchmarkError.configuration("Benchmark output already exists; choose a new output file.")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        guard let first = fixtures.first else { throw BenchmarkError.configuration("The fixture manifest is empty.") }
        let quality = TranslatorQuality(rawValue: argument("--quality") ?? "high") ?? .high
        let recognition = argument("--recognizer") ?? "qwen"
        guard ["qwen", "nemotron", "apple"].contains(recognition), recognition == "qwen" || mode != "api" else {
            throw BenchmarkError.configuration("Use --recognizer qwen|nemotron|apple with a local recognition mode.")
        }
        if recognition != "qwen", fixtures.contains(where: { !$0.language.lowercased().hasPrefix("en") }) {
            throw BenchmarkError.configuration("The streaming recognition trial currently fixes the input language to English.")
        }
        @Sendable func loadLocalRecognizer() async throws -> any SpeechRecognitionBackend {
            if recognition == "nemotron" { return try await NemotronASRClient.load() }
            if recognition == "apple" {
                guard #available(macOS 26.0, *) else { throw BenchmarkError.configuration("Apple streaming requires macOS 26.") }
                return try await AppleSpeechASRClient.load()
            }
            return try await ASRClient.load(modelId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", language: nil)
        }
        let preferences = Preferences.shared
        let translationModel = argument("--translation-model") ?? preferences.realRouterModel
        let loading = ContinuousClock.now
        let recognizer: any SpeechRecognitionBackend
        let translator: any TranslationBackend
        if mode == "rapid" {
            recognizer = try await loadLocalRecognizer()
            translator = try await RapidMLXTranslator.load(baseURL: preferences.rapidMLXURL,
                model: preferences.rapidMLXModel, targetLanguage: first.targetLanguage)
        } else if mode != "local" {
            let key = try RealRouterCredentials.load()
            if mode == "api" {
                let speech = try RealRouterSpeechRecognizer(baseURL: preferences.realRouterURL, apiKey: key, language: nil)
                try await speech.checkServer()
                recognizer = speech
            } else {
                recognizer = try await loadLocalRecognizer()
            }
            translator = try await RealRouterTranslator.load(baseURL: preferences.realRouterURL,
                model: translationModel, apiKey: key, targetLanguage: first.targetLanguage)
        } else {
            async let asr = loadLocalRecognizer()
            async let llm = MLXChatTranslator.load(modelId: quality.modelId, targetLanguage: first.targetLanguage)
            recognizer = try await asr
            translator = try await llm
        }
        let loadMS = milliseconds(loading, .now)
        FileManager.default.createFile(atPath: output, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        defer { try? handle.close() }
        func write<T: Encodable>(_ value: T) throws {
            var data = try JSONEncoder().encode(value)
            data.append(10)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        try write(["kind": "metadata", "mode": mode, "loading_ms": String(loadMS),
                   "asr": mode == "api" ? "RealRouter upstream (server-selected)" : recognition == "apple" ? "Apple SpeechTranscriber / en-US / volatile + fast results" : recognition == "nemotron" ? NemotronASRClient.modelID : "Qwen3-ASR-1.7B-MLX-8bit",
                   "recognition_execution": recognition == "apple" ? "SpeechAnalyzer asynchronous audio stream" : recognizer.isStreaming ? "cache-aware incremental CoreML / cpuAndNeuralEngine / 320ms chunks" : "whole-snapshot transcription",
                   "translator": mode == "rapid" ? "Rapid-MLX / \(preferences.rapidMLXModel)" : mode != "local" ? translationModel : quality.modelId,
                   "language_hint": recognition != "qwen" ? "en-US" : "auto", "history": arguments.contains("--pipeline") ? "rolling committed + confirmed unit" : "none",
                   "vad_silence_ms": String(preferences.speechEndMs),
                   "acoustic_slice_s": String(Config.maxUtteranceS),
                   "preferred_recognition_window_s": String(Config.preferredRecognitionWindowS),
                   "caption_cjk_characters_per_second": String(CaptionPaginator.cjkCharactersPerSecond),
                   "fixture_count": String(fixtures.count),
                   "repeats": String(repeats), "timestamp": ISO8601DateFormatter().string(from: Date())])
        // Exclude the first request after initialization from steady-state stats.
        let warmup = try await measure(first, mode: mode, round: -1, kind: "warmup", asr: recognizer, translator: translator)
        try write(warmup)
        print("[benchmark] \(mode) warmup total_ms=\(Int(warmup.totalMS)) error=\(warmup.error ?? "none")")
        guard warmup.error == nil else { throw BenchmarkError.configuration("Warm-up failed: \(warmup.error!)") }
        if arguments.contains("--pipeline") {
            let vad = try await VADSegmenter.load()
            for fixture in fixtures {
                translator.targetLanguage = fixture.targetLanguage
                let row = try await CaptionPipelineBenchmark.measure(fixture, asr: recognizer, translator: translator, vad: vad)
                try write(row)
                print("[pipeline-benchmark] \(fixture.id) segments=\(row.segments) first_caption_ms=\(Int(row.firstCaptionMS ?? -1)) reading_ratio=\(row.minimumReadingRatio ?? -1) error=\(row.error ?? "none")")
            }
            return
        }
        for round in 0..<repeats {
            let ordered = round % 2 == 0 ? fixtures : Array(fixtures.reversed())
            for fixture in ordered {
                let row = try await measure(fixture, mode: mode, round: round, kind: "sample",
                                            asr: recognizer, translator: translator)
                try write(row)
                print("[benchmark] \(mode) \(fixture.id) round=\(round) asr_ms=\(Int(row.asrMS)) first_translation_ms=\(Int(row.firstTranslationMS ?? -1)) total_ms=\(Int(row.totalMS)) error=\(row.error ?? "none")")
            }
        }
    }

    private static func measure(_ fixture: Fixture, mode: String, round: Int, kind: String,
                                asr: any SpeechRecognitionBackend, translator: any TranslationBackend) async throws -> Row {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture.audioPath))
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchmarkError.configuration("Fixtures must be 16 kHz mono audio.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw BenchmarkError.configuration("Cannot decode fixture audio.") }
        var audio = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        audio.append(contentsOf: [Float](repeating: 0, count: Config.sampleRate / 4))
        let audioSeconds = Double(audio.count) / Double(Config.sampleRate)
        translator.targetLanguage = fixture.targetLanguage
        let begin = ContinuousClock.now
        var asrEnd = begin
        var translationBegin: ContinuousClock.Instant?
        var firstToken: ContinuousClock.Instant?
        var recognized = "", translated = "", failure: String?
        do {
            recognized = try await asr.transcribe(audio)
            asrEnd = .now
            guard !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchmarkError.configuration("No recognized speech returned.")
            }
            translationBegin = .now
            for try await token in translator.translateStream(recognized, history: []) {
                if firstToken == nil, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { firstToken = .now }
                translated += token
            }
            guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchmarkError.configuration("No translation returned.")
            }
        } catch {
            if translationBegin == nil { asrEnd = .now }
            failure = error.localizedDescription
        }
        let end = ContinuousClock.now
        return Row(kind: kind, mode: mode, fixture: fixture.id, round: round, audioSeconds: audioSeconds,
                   reference: fixture.reference, referenceTranslation: fixture.referenceTranslation,
                   targetLanguage: fixture.targetLanguage, recognized: recognized, translation: translated,
                   asrMS: milliseconds(begin, asrEnd),
                   translationFirstTokenMS: firstToken.flatMap { first in translationBegin.map { milliseconds($0, first) } },
                   translationTotalMS: translationBegin.map { milliseconds($0, end) } ?? 0,
                   firstTranslationMS: firstToken.map { milliseconds(begin, $0) },
                   totalMS: milliseconds(begin, end), error: failure)
    }

    private static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: end).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
