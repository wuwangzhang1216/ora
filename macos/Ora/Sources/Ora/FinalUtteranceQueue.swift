import Foundation

/// FIFO hand-off between the (fast, never-blocking) VAD dispatch loop and the
/// finals worker that runs ASR + translation.
///
/// Bounded: under sustained overload the OLDEST utterance is shed — but
/// explicitly counted, never silently. Partials may be conflated at will;
/// a final IS the user's sentence, so every shed must be observable.
actor FinalUtteranceQueue {
    private var items: [[Float]] = []
    private var waiter: CheckedContinuation<[Float]?, Never>?
    private var finished = false
    private(set) var droppedCount = 0

    private let capacity: Int

    init(capacity: Int = Config.maxPendingFinalUtterances) {
        self.capacity = max(1, capacity)
    }

    /// Returns the total number of utterances shed so far, so the caller can
    /// surface "captions fell behind" without a second actor hop.
    @discardableResult
    func enqueue(_ audio: [Float]) -> Int {
        guard !finished else { return droppedCount }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: audio)
            return droppedCount
        }
        items.append(audio)
        if items.count > capacity {
            items.removeFirst()
            droppedCount += 1
        }
        return droppedCount
    }

    /// Suspends until an utterance is available; returns nil after `finish()`
    /// once the backlog is drained.
    func dequeue() async -> [Float]? {
        if !items.isEmpty {
            return items.removeFirst()
        }
        if finished {
            return nil
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    var depth: Int { items.count }

    /// Stop accepting work and release a pending `dequeue()`. Already-queued
    /// utterances remain drainable.
    func finish() {
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}
