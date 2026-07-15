import XCTest
@testable import Ora

final class FinalUtteranceQueueTests: XCTestCase {
    func testFIFOOrder() async {
        let q = FinalUtteranceQueue(capacity: 8)
        await q.enqueue([1])
        await q.enqueue([2])
        await q.enqueue([3])
        let a = await q.dequeue()
        let b = await q.dequeue()
        let c = await q.dequeue()
        XCTAssertEqual(a, [1])
        XCTAssertEqual(b, [2])
        XCTAssertEqual(c, [3])
    }

    func testShedsOldestAndCountsUnderOverload() async {
        let q = FinalUtteranceQueue(capacity: 2)
        await q.enqueue([1])
        await q.enqueue([2])
        let dropped = await q.enqueue([3])
        XCTAssertEqual(dropped, 1)
        let depth = await q.depth
        XCTAssertEqual(depth, 2)
        let a = await q.dequeue()
        let b = await q.dequeue()
        XCTAssertEqual(a, [2], "oldest utterance is the one shed")
        XCTAssertEqual(b, [3])
        let total = await q.droppedCount
        XCTAssertEqual(total, 1)
    }

    func testEnqueueHandsOffDirectlyToWaitingDequeue() async {
        let q = FinalUtteranceQueue(capacity: 2)
        let waiter = Task { await q.dequeue() }
        // Give the dequeue a chance to suspend before we enqueue.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await q.enqueue([42])
        let value = await waiter.value
        XCTAssertEqual(value, [42])
        let depth = await q.depth
        XCTAssertEqual(depth, 0)
    }

    func testFinishReleasesPendingDequeueWithNil() async {
        let q = FinalUtteranceQueue(capacity: 2)
        let waiter = Task { await q.dequeue() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await q.finish()
        let value = await waiter.value
        XCTAssertNil(value)
    }

    func testBacklogDrainsAfterFinishThenNil() async {
        let q = FinalUtteranceQueue(capacity: 4)
        await q.enqueue([1])
        await q.enqueue([2])
        await q.finish()
        let a = await q.dequeue()
        let b = await q.dequeue()
        let c = await q.dequeue()
        XCTAssertEqual(a, [1])
        XCTAssertEqual(b, [2])
        XCTAssertNil(c, "after finish + drain, dequeue returns nil instead of suspending")
    }

    func testEnqueueAfterFinishIsIgnored() async {
        let q = FinalUtteranceQueue(capacity: 4)
        await q.finish()
        await q.enqueue([1])
        let value = await q.dequeue()
        XCTAssertNil(value)
    }
}
