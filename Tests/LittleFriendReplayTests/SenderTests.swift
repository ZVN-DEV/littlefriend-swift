import Foundation
import XCTest
@testable import LittleFriendReplay

final class SenderTests: XCTestCase {
    private func chunk(_ sequence: Int, bytes: Int = 16) -> ReplayPendingChunk {
        ReplayPendingChunk(
            sessionID: "abcdefghijklmnopqrst", pageID: "pagepagepagepagepage", sequence: sequence,
            body: Data(repeating: 0x7B, count: bytes), hasSnapshot: sequence == 0
        )
    }

    func testRetrySendsTheExactSameBodySoChunkIdentityIsStable() async {
        let transport = FakeReplayTransport()
        transport.results = [.retry(after: nil), .retry(after: 2), .accepted]
        let sender = ReplayChunkSender(transport: transport, waiting: ImmediateWaiting()) { _ in }
        let first = chunk(0)
        XCTAssertTrue(sender.enqueue(first))
        let done = await eventually { transport.bodies.count == 3 && sender.pendingCount == 0 }
        XCTAssertTrue(done)
        XCTAssertEqual(transport.bodies, [first.body, first.body, first.body])
    }

    func testTerminalResponseClearsTheQueueAndReportsOnce() async {
        let transport = FakeReplayTransport()
        transport.results = [.terminal(status: 402)]
        let terminals = TerminalLog()
        let sender = ReplayChunkSender(transport: transport, waiting: ImmediateWaiting()) { status in
            terminals.add(status)
        }
        XCTAssertTrue(sender.enqueue(chunk(0)))
        let done = await eventually { terminals.values == [402] }
        XCTAssertTrue(done)
        XCTAssertEqual(sender.pendingCount, 0)
        XCTAssertFalse(sender.enqueue(chunk(1)))
    }

    func testQueueBoundsDiscardEverythingPending() {
        let transport = FakeReplayTransport()
        transport.fallback = .retry(after: nil)
        let sender = ReplayChunkSender(
            transport: transport, waiting: ImmediateWaiting(), maxChunks: 2, maxBytes: 1024
        ) { _ in }
        XCTAssertTrue(sender.enqueue(chunk(0)))
        XCTAssertTrue(sender.enqueue(chunk(1)))
        XCTAssertFalse(sender.enqueue(chunk(2)))
        XCTAssertEqual(sender.pendingCount, 0)
        XCTAssertEqual(sender.pendingBytes, 0)
    }

    func testRetryDelayHonorsRetryAfterWithinBounds() {
        XCTAssertEqual(ReplayChunkSender.retryDelay(attempt: 0, retryAfter: nil), 1)
        XCTAssertEqual(ReplayChunkSender.retryDelay(attempt: 1, retryAfter: nil), 4)
        XCTAssertEqual(ReplayChunkSender.retryDelay(attempt: 2, retryAfter: nil), 16)
        XCTAssertEqual(ReplayChunkSender.retryDelay(attempt: 0, retryAfter: 10), 10)
        XCTAssertEqual(ReplayChunkSender.retryDelay(attempt: 0, retryAfter: 0), 1)
        XCTAssertEqual(ReplayChunkSender.retryDelay(attempt: 0, retryAfter: 900), 30)
    }
}

private final class TerminalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func add(_ status: Int) {
        lock.lock()
        storage.append(status)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
