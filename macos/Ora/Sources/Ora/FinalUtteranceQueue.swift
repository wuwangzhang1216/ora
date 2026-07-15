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

    /// Returns true when this enqueue shed the oldest queued utterance, so the
    /// caller can surface "captions fell behind" without a second actor hop.
    @discardableResult
    func enqueue(_ audio: [Float]) -> Bool {
        guard !finished else { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: audio)
            return false
        }
        items.append(audio)
        if items.count > capacity {
            items.removeFirst()
            droppedCount += 1
            return true
        }
        return false
    }

    /// Suspends until an utterance is available; returns nil after `finish()`
    /// once the backlog is drained, or immediately when the caller is
    /// cancelled (so a stopped worker never hangs on a suspended dequeue).
    func dequeue() async -> [Float]? {
        if !items.isEmpty {
            return items.removeFirst()
        }
        if finished {
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation may have landed before we could suspend — the
                // onCancel hop found no waiter, so resume ourselves.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.releaseWaiter() }
        }
    }

    private func releaseWaiter() {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
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
