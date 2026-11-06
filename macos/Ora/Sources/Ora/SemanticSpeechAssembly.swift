import Foundation

/// Conservative endpoint hints, not a grammatical parser. A recognizer's
/// punctuation alone must not turn "I don't think." into a complete thought.
enum SentenceBoundary {
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc", "e.g", "i.e"]

    static func isSentencePeriod(_ chars: [Character], at i: Int) -> Bool {
        if i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber { return false }
        if i + 1 < chars.count, chars[i + 1].isLetter { return false }
        let token = String(chars[..<i].reversed().prefix { $0.isLetter || $0 == "." }.reversed()).lowercased()
        if abbreviations.contains(token) || (token.count == 1 && token.first?.isLetter == true) { return false }
        let initials = token.split(separator: ".")
        return !(initials.count > 1 && initials.allSatisfy { $0.count == 1 && $0.first?.isLetter == true })
    }

    static func hasCompleteUnit(_ text: String) -> Bool {
        !completePrefix(text).isEmpty
    }

    static func completePrefix(_ text: String) -> String {
        let characters = Array(text)
        var sentence = ""
        var end = 0
        for (index, character) in characters.enumerated() {
            sentence.append(character)
            if character == ".", !isSentencePeriod(characters, at: index) { continue }
            if ".!?。！？".contains(character) {
                guard isComplete(sentence) else { break }
                end = index + 1
                sentence = ""
            }
        }
        return String(characters.prefix(end)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isComplete(_ text: String, allowDependentClause: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’」』】）》)]}"))
        guard let end = unquoted.last, ".!?。！？".contains(end) else { return false }
        if end == ".", !isSentencePeriod(Array(unquoted), at: unquoted.count - 1) { return false }
        if unquoted.hasSuffix("...") || unquoted.hasSuffix("…") { return false }
        let body = unquoted.trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let hangingWords: Set<String> = ["a", "an", "the", "to", "of", "for", "from", "with", "without", "if", "unless", "because", "although", "and", "but", "or", "that", "which", "whose", "is", "are", "was", "were"]
        if let last = words.last, hangingWords.contains(last) { return false }
        let hangingPhrases = ["i think", "i don't think", "i do not think", "we think", "i believe", "we need", "we should", "we can", "i want", "it depends on"]
        if hangingPhrases.contains(where: { body == $0 || body.hasSuffix(" " + $0) }) { return false }
        if !allowDependentClause, end != "?", let first = words.first,
           ["if", "unless", "because", "although", "while"].contains(first), !body.contains(",") { return false }
        let hangingCJK = ["因为", "如果", "虽然", "但是", "除非", "以及", "或者", "为了", "我觉得", "我认为", "我们认为", "我们需要", "需要", "不要把", "请把", "关于"]
        return !hangingCJK.contains(where: { body.hasSuffix($0) })
    }
}

/// The ASR snapshot must cover the entire pending audio before it can shorten
/// the hold. A fluent but stale partial is never evidence of a final boundary.
final class SpeechRecognitionSnapshot: @unchecked Sendable {
    private let acceptsUnpunctuatedEnd: Bool
    private let lock = NSLock()
    private var value: (UUID, Int, String)?
    private var observations: [(samples: Int, text: String)] = []
    private var translatedSource = ""
    init(acceptsUnpunctuatedEnd: Bool = false) {
        self.acceptsUnpunctuatedEnd = acceptsUnpunctuatedEnd
    }
    private func isComplete(_ text: String) -> Bool {
        if SentenceBoundary.isComplete(text) { return true }
        // RNN-T tokens are committed before terminal punctuation necessarily
        // arrives. At an acoustic endpoint, missing punctuation alone must not
        // impose the 2.4s unfinished-thought hold. Hanging negations/prepositions
        // still use that existing continuation protection.
        guard acceptsUnpunctuatedEnd, let last = text.last, last.isLetter || last.isNumber else { return false }
        return SentenceBoundary.isComplete(text + ".")
    }
    func note(id: UUID, samples: Int, text: String) {
        lock.withLock {
            if value?.0 != id { observations.removeAll(); translatedSource = "" }
            value = (id, samples, text)
            observations.append((samples, text))
            if observations.count > 256 { observations.removeFirst(observations.count - 256) }
        }
    }
    func complete(id: UUID, samples: Int) -> Bool {
        lock.withLock {
            guard let value, value.0 == id, value.1 == samples else { return false }
            return isComplete(value.2)
        }
    }
    func transcript(id: UUID, samples: Int) -> String? {
        lock.withLock {
            guard let value, value.0 == id, value.1 == samples else { return nil }
            return value.2
        }
    }
    func noteTranslation(id: UUID, source: String) {
        lock.withLock {
            guard value?.0 == id else { return }
            translatedSource = source
        }
    }
    func needsContinuation(id: UUID, samples: Int) -> Bool {
        lock.withLock {
            guard let value, value.0 == id, value.1 == samples else { return false }
            return !isComplete(value.2)
        }
    }
    func safeBoundary(id: UUID, minimumSamples: Int, maximumSamples: Int) -> (samples: Int, text: String)? {
        lock.withLock {
            guard let latest = value, latest.0 == id else { return nil }
            for observation in observations.reversed() {
                guard observation.samples >= minimumSamples, observation.samples < maximumSamples,
                      observation.samples + Config.sampleRate / 3 <= latest.1,
                      SentenceBoundary.isComplete(observation.text),
                      let aligned = RecognitionTextAgreement.alignedPrefix(observation.text, in: latest.2) else { continue }
                // Earlier commas may change freely. The matched endpoint
                // itself must still end a sentence in the latest recognition.
                guard SentenceBoundary.isComplete(aligned),
                      translatedSource.isEmpty || RecognitionTextAgreement.alignedPrefix(translatedSource, in: aligned) != nil else { continue }
                return (observation.samples, aligned)
            }
            return nil
        }
    }
}

enum SpeechAssemblyEmission {
    case partial([Float], UUID)
    case final([Float], UUID)
    case contextual(CapturedUtterance, final: Bool)

    var preview: CapturedUtterance? {
        switch self {
        case .partial(let audio, let id): return CapturedUtterance(id: id, audio: audio)
        case .contextual(let utterance, final: false): return utterance
        default: return nil
        }
    }
    var finalized: CapturedUtterance? {
        switch self {
        case .final(let audio, let id): return CapturedUtterance(id: id, audio: audio)
        case .contextual(let utterance, final: true): return utterance
        default: return nil
        }
    }
}

/// Audio slicing, semantic endpointing and caption pagination have separate
/// boundaries. Retain audio across short VAD pauses and re-recognize the joined
/// utterance, so lost punctuation/word boundaries aren't repaired by guessing.
struct SemanticSpeechAssembly {
    let minimumHold: TimeInterval
    let maximumHold: TimeInterval
    let continuationHold: TimeInterval
    let maximumSamples: Int
    let preferredSamples: Int
    let previewAtPause: Bool
    private(set) var id: UUID?
    private var prefix: [Float] = []
    private var latest: [Float] = []
    private var overlapSource: String?
    private(set) var pausedAt: TimeInterval?

    init(minimumHold: TimeInterval = 0.25, maximumHold: TimeInterval = 0.45,
         maximumSamples: Int = Int(Config.maxSemanticUtteranceS) * Config.sampleRate,
         preferredSamples: Int = Int(Config.preferredRecognitionWindowS) * Config.sampleRate,
         continuationHold: TimeInterval = 2.4,
         previewAtPause: Bool = true) {
        self.minimumHold = minimumHold
        self.maximumHold = max(minimumHold, maximumHold)
        self.continuationHold = max(maximumHold, continuationHold)
        self.maximumSamples = maximumSamples
        self.preferredSamples = min(maximumSamples, preferredSamples)
        self.previewAtPause = previewAtPause
    }

    mutating func start(now: TimeInterval, recognition: SpeechRecognitionSnapshot) -> [SpeechAssemblyEmission] {
        let emissions = poll(now: now, recognition: recognition)
        if pausedAt != nil {
            prefix = latest
            pausedAt = nil
        }
        if id == nil { id = UUID() }
        return emissions
    }

    mutating func partial(_ audio: [Float]) -> [SpeechAssemblyEmission] {
        if id == nil { id = UUID() }
        latest = prefix + audio
        guard !latest.isEmpty else { return [] }
        if let overlapSource {
            return [.contextual(CapturedUtterance(id: id!, audio: latest, overlapSource: overlapSource), final: false)]
        }
        return [.partial(latest, id!)]
    }

    mutating func pause(_ audio: [Float], now: TimeInterval, recognition: SpeechRecognitionSnapshot? = nil) -> [SpeechAssemblyEmission] {
        let preview = partial(audio)
        var emissions = previewAtPause ? preview : []
        pausedAt = now
        if latest.count >= preferredSamples {
            let overlap = Config.sampleRate
            if let id, let boundary = recognition?.safeBoundary(id: id,
                minimumSamples: max(Config.sampleRate * 2, latest.count - maximumSamples + overlap),
                maximumSamples: latest.count) {
                let committed = CapturedUtterance(id: id, audio: Array(latest.prefix(boundary.samples)),
                    sourceOverride: boundary.text, overlapSource: overlapSource)
                let tail = Array(latest.dropFirst(max(0, boundary.samples - overlap)))
                self.id = UUID()
                prefix = []
                latest = tail
                overlapSource = boundary.text
                emissions.append(.contextual(committed, final: true))
                emissions.append(.contextual(CapturedUtterance(id: self.id!, audio: tail,
                    overlapSource: boundary.text), final: false))
            } else if latest.count >= maximumSamples { emissions += flush() }
        }
        return emissions
    }

    mutating func poll(now: TimeInterval, recognition: SpeechRecognitionSnapshot) -> [SpeechAssemblyEmission] {
        guard let pausedAt, let id else { return [] }
        let held = now - pausedAt
        let limit = recognition.needsContinuation(id: id, samples: latest.count) ? continuationHold : maximumHold
        guard held >= limit || (held >= minimumHold && recognition.complete(id: id, samples: latest.count)) else { return [] }
        return flush()
    }

    mutating func flush() -> [SpeechAssemblyEmission] {
        defer { id = nil; prefix = []; latest = []; pausedAt = nil; overlapSource = nil }
        guard let id, !latest.isEmpty else { return [] }
        if let overlapSource {
            return [.contextual(CapturedUtterance(id: id, audio: latest, overlapSource: overlapSource), final: true)]
        }
        return [.final(latest, id)]
    }

    func nextCheck(now: TimeInterval, recognition: SpeechRecognitionSnapshot) -> TimeInterval? {
        guard let pausedAt, let id else { return nil }
        let limit = recognition.needsContinuation(id: id, samples: latest.count) ? continuationHold : maximumHold
        return now < pausedAt + minimumHold ? pausedAt + minimumHold : pausedAt + limit
    }
}

/// A monotonic timer flushes a paused utterance even when no more audio arrives.
/// VAD dispatch never waits for recognition or translation inference here.
actor SpeechAssemblyCoordinator {
    private var assembly: SemanticSpeechAssembly
    private let recognition: SpeechRecognitionSnapshot
    private let emit: @Sendable (SpeechAssemblyEmission) async -> Void
    private let epoch = ContinuousClock.now
    private var timer: Task<Void, Never>?
    private var emissionTask: Task<Void, Never>?
    private var closed = false
    private let timing: PipelineTiming?

    init(recognition: SpeechRecognitionSnapshot, previewAtPause: Bool = true, timing: PipelineTiming? = nil,
         emit: @escaping @Sendable (SpeechAssemblyEmission) async -> Void) {
        self.assembly = SemanticSpeechAssembly(previewAtPause: previewAtPause)
        self.recognition = recognition
        self.emit = emit
        self.timing = timing
    }

    private var now: TimeInterval {
        let duration = epoch.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    func receive(_ event: VADEvent) async {
        guard !closed, !Task.isCancelled else { return }
        let emissions: [SpeechAssemblyEmission]
        switch event {
        case .speechStart:
            timing?.note("vad_speech_start", id: assembly.id)
            emissions = assembly.start(now: now, recognition: recognition)
        case .partial(let audio):
            timing?.note("vad_partial", id: assembly.id, samples: audio.count)
            emissions = assembly.partial(audio)
        case .final(let audio):
            timing?.note("vad_endpoint_or_slice", id: assembly.id, samples: audio.count)
            emissions = assembly.pause(audio, now: now, recognition: recognition)
        }
        schedule()
        await publish(emissions)
    }

    func finish() async {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        await publish(assembly.flush())
    }

    func cancel() {
        closed = true
        timer?.cancel()
        emissionTask?.cancel()
        _ = assembly.flush()
    }

    private func tick() async {
        guard !closed, !Task.isCancelled else { return }
        timer = nil
        let emissions = assembly.poll(now: now, recognition: recognition)
        schedule()
        await publish(emissions)
    }

    private func publish(_ emissions: [SpeechAssemblyEmission]) async {
        guard !emissions.isEmpty else { await emissionTask?.value; return }
        let previous = emissionTask
        for item in emissions {
            if let final = item.finalized {
                timing?.note("assembly_release", id: final.id, samples: final.audio.count,
                             reason: final.sourceOverride == nil ? "endpoint_or_limit" : "confirmed_boundary")
            }
        }
        let task = Task { [emit] in
            await previous?.value
            guard !Task.isCancelled else { return }
            for item in emissions { await emit(item) }
        }
        emissionTask = task
        await task.value
    }

    private func schedule() {
        timer?.cancel()
        if let check = assembly.nextCheck(now: now, recognition: recognition) {
            timing?.note("assembly_timer", id: assembly.id, durationMS: max(0, check - now) * 1000)
        }
        timer = nil
        guard !closed, let deadline = assembly.nextCheck(now: now, recognition: recognition) else { return }
        let delay = max(0.001, deadline - now)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.tick()
        }
    }
}
