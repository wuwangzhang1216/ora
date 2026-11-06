import Foundation

protocol SpeechRecognitionBackend: Sendable {
    var partialPolicy: RecognitionPartialPolicy { get }
    var isStreaming: Bool { get }
    var commitsPartialTokens: Bool { get }
    func transcribe(_ audio: [Float]) async throws -> String
    /// Growing snapshots share an ID. Streaming backends consume only the new
    /// suffix and flush their buffered acoustic tail on the final call.
    func transcribe(_ audio: [Float], id: UUID, final: Bool) async throws -> String
}

extension SpeechRecognitionBackend {
    var partialPolicy: RecognitionPartialPolicy { .local }
    var isStreaming: Bool { false }
    var commitsPartialTokens: Bool { false }
    func transcribe(_ audio: [Float], id: UUID, final: Bool) async throws -> String {
        try await transcribe(audio)
    }
}

/// The assembly owns immutable, growing audio under each utterance ID. Track
/// the consumed sample boundary separately from model state so a repeated pause
/// snapshot cannot feed the same speech twice to a stateful recognizer.
struct StreamingRecognitionCursor {
    private var id: UUID?
    private var samples = 0

    mutating func consume(_ audio: [Float], id: UUID) -> (restart: Bool, delta: [Float]) {
        let restart = self.id != id || audio.count < samples
        if restart { self.id = id; samples = 0 }
        let delta = Array(audio.dropFirst(samples))
        samples = audio.count
        return (restart, delta)
    }
}

struct RecognitionPartialPolicy: Sendable {
    let minimumSamples: Int
    let minimumGrowth: Int
    let interval: Duration
    static let local = Self(minimumSamples: 0, minimumGrowth: 0, interval: .zero)
    static let api = Self(minimumSamples: Config.sampleRate, minimumGrowth: Config.sampleRate,
                          interval: .milliseconds(1500))
}

/// Rate-limit *attempts*, including failed requests, while leaving final
/// utterances unthrottled. The partial pipeline still coalesces to newest audio.
struct RecognitionPartialThrottle {
    let policy: RecognitionPartialPolicy
    private var id: UUID?
    private var samples = 0
    private var attemptedAt: ContinuousClock.Instant?

    init(policy: RecognitionPartialPolicy) { self.policy = policy }

    mutating func allow(id: UUID, sampleCount: Int, now: ContinuousClock.Instant = .now) -> Bool {
        guard sampleCount >= policy.minimumSamples else { return false }
        if self.id == id, let attemptedAt {
            guard sampleCount - samples >= policy.minimumGrowth,
                  attemptedAt.duration(to: now) >= policy.interval else { return false }
        }
        self.id = id
        samples = sampleCount
        attemptedAt = now
        return true
    }
}
