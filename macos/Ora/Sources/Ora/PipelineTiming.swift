import Foundation

/// Explicit replay instrumentation. Production engines leave this nil, so
/// live speech/translation never enters a timing log. One monotonic clock
/// connects audio, recognition, assembly, translation and display events.
final class PipelineTiming: @unchecked Sendable {
    struct Event: Encodable {
        let ms: Double
        let stage: String
        let id: UUID?
        let span: UUID?
        let path: String?
        let samples: Int?
        let text: String?
        let durationMS: Double?
        let reason: String?
    }
    let epoch: ContinuousClock.Instant
    private let lock = NSLock()
    private var events: [Event] = []
    init(epoch: ContinuousClock.Instant = .now) { self.epoch = epoch }
    static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
        let d = start.duration(to: end).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    func note(_ stage: String, id: UUID? = nil, span: UUID? = nil, path: String? = nil,
              samples: Int? = nil, text: String? = nil, durationMS: Double? = nil, reason: String? = nil) {
        let event = Event(ms: Self.ms(epoch), stage: stage, id: id, span: span, path: path,
                          samples: samples, text: text, durationMS: durationMS, reason: reason)
        lock.withLock { events.append(event) }
    }
    func snapshot() -> [Event] { lock.withLock { events.sorted { $0.ms < $1.ms } } }
}
