import Foundation

enum Config {
    static let sampleRate = 16_000
    static let vadFrameSamples = 512              // Silero requires exactly 512 @ 16kHz (~32ms)
    static let vadFrameMs = vadFrameSamples * 1_000 / sampleRate

    // VAD thresholds with hysteresis — avoid rapid toggling when speech
    // probability hovers around the boundary. Start > stop by vadHysteresis
    // is the pattern Silero FAQ / Pipecat / LiveKit all recommend.
    static let vadThreshold: Float = 0.5          // start-of-speech threshold (Silero default)
    static let vadHysteresis: Float = 0.15        // gap below start to end speech
    static var vadStopThreshold: Float { max(0.0, vadThreshold - vadHysteresis) }

    static let speechStartFrames = 3              // ~96ms voiced before we trigger start
    static let speechEndMs = 500                  // trailing silence to end an utterance (industry-standard balance)
    static let preRollMs = 200                    // audio kept before speech start
    static let minUtteranceMs = 300               // drop anything shorter
    static let maxUtteranceS: Double = 15         // safety cap for run-on speech

    static let partialIntervalS: Double = 0.6     // rolling partial cadence (~500 ms is industry norm)
    static let partialMinGrowthS: Double = 0.3    // skip partial unless buffer grew this much

    static let rapidMLXURL = "http://127.0.0.1:8000/v1"
    static let rapidMLXModel = "default"
}

enum AudioSourceKind: String, CaseIterable {
    case microphone
    case systemAudio

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        }
    }
}

enum CaptionDisplayMode: String, CaseIterable {
    case bilingual
    case translationOnly
    case compact

    var displayName: String {
        switch self {
        case .bilingual: return "Bilingual"
        case .translationOnly: return "Translation Only"
        case .compact: return "Compact"
        }
    }

    var helpText: String {
        switch self {
        case .bilingual: return "Shows source text above the translation."
        case .translationOnly: return "Hides source text for a cleaner caption card."
        case .compact: return "Uses a narrower card with tighter spacing for calls and screen sharing."
        }
    }
}

enum LLMBackendKind: String, CaseIterable {
    case mlxSwift
    case rapidMLX

    var displayName: String {
        switch self {
        case .mlxSwift: return "MLX Swift"
        case .rapidMLX: return "Rapid-MLX"
        }
    }

    var helpText: String {
        switch self {
        case .mlxSwift:
            return "Runs the translator inside Ora. Best for the packaged app and offline use."
        case .rapidMLX:
            return "Connects to a local Rapid-MLX OpenAI-compatible server for lower-latency experiments."
        }
    }
}

enum VADPreset: String, CaseIterable {
    case quiet
    case meeting
    case noisy
    case custom

    var displayName: String {
        switch self {
        case .quiet: return "Quiet Room"
        case .meeting: return "Meeting"
        case .noisy: return "Noisy Room"
        case .custom: return "Custom"
        }
    }

    var settings: (threshold: Double, speechEndMs: Int)? {
        switch self {
        case .quiet: return (0.42, 650)
        case .meeting: return (0.50, 500)
        case .noisy: return (0.68, 420)
        case .custom: return nil
        }
    }
}

enum TranslatorQuality: String, CaseIterable {
    case standard       // 2B-class MLX 4bit — default, ~1.2 GB, fast
    case high           // 4B-class MLX 4bit — better quality, ~3 GB, slower
    case extraHigh      // 9B-class MLX 4bit — best quality, ~6 GB, slowest

    var modelId: String {
        switch self {
        case .standard:  return "mlx-community/Qwen3.5-2B-MLX-4bit"
        case .high:      return "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .extraHigh: return "mlx-community/Qwen3.5-9B-MLX-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .standard:  return "Standard (~1.2 GB)"
        case .high:      return "High (~3 GB)"
        case .extraHigh: return "Extra High (~6 GB)"
        }
    }
}

// ANSI escape codes
enum ANSI {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"
    static let green = "\u{1B}[32m"
    static let clearLine = "\r\u{1B}[K"
}
