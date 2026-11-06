import Foundation
import Observation

/// Main-actor presentation clock, separate from the GPU and audio tasks.
/// A single cancellable timer drives page changes, even when input is silent.
@MainActor
@Observable
final class CaptionPresenter {
    private(set) var scheduler: CaptionScheduler = {
        var value = CaptionScheduler()
        value.followsLiveSpeech = true
        return value
    }()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let epoch = ContinuousClock.now
    /// Opt-in replay probe; unset in normal use and never logs live speech.
    @ObservationIgnored var onDelivery: ((UUID, String, String?, Bool) -> Void)?

    nonisolated init() {}

    var visible: ScheduledCaption? { scheduler.visible }
    var queuedCount: Int { scheduler.queuedUtteranceCount }
    var isDraining: Bool { scheduler.isDraining }

    private var now: TimeInterval {
        let d = epoch.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    func update(id: UUID, source: String, translation: String?, final: Bool = false) {
        onDelivery?(id, source, translation, final)
        scheduler.update(id: id, source: source, translation: translation, final: final, now: now)
        schedule()
    }

    func reflow(_ typography: CaptionTypography) {
        scheduler.reflow(typography, now: now)
        schedule()
    }

    func reset() {
        timer?.cancel()
        timer = nil
        let typography = scheduler.typography
        scheduler = CaptionScheduler()
        scheduler.followsLiveSpeech = true
        scheduler.typography = typography
    }

    func finishPending() {
        scheduler.finishPending(now: now)
        schedule()
    }

    func finish(id: UUID) {
        scheduler.finish(id: id, now: now)
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = scheduler.nextDeadline else { return }
        let delay = max(0.01, deadline - now)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduler.advance(now: self.now)
            self.schedule()
        }
    }
}
