import Foundation
@testable import LittleFriend

/// A clock that moves only when a test moves it.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }

    var ms: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }
}

/// A scheduler whose work runs only inside `advance(by:)`, in due order, moving the clock with it.
final class ManualScheduler: Scheduler, @unchecked Sendable {
    private struct Item {
        let id: Int
        let due: TimeInterval
        let delay: TimeInterval
        let work: @Sendable () -> Void
    }

    private final class Handle: ScheduledWork, @unchecked Sendable {
        weak var scheduler: ManualScheduler?
        let id: Int
        init(_ scheduler: ManualScheduler, _ id: Int) {
            self.scheduler = scheduler
            self.id = id
        }

        func cancel() { scheduler?.cancel(id) }
    }

    private struct Waiter {
        let id: Int
        let count: Int
        let continuation: CheckedContinuation<[TimeInterval], Never>
    }

    private let lock = NSLock()
    private let clock: ManualClock?
    private var elapsed: TimeInterval = 0
    private var nextID = 0
    private var items: [Item] = []
    private var ran = 0
    private var waiters: [Waiter] = []

    init(clock: ManualClock? = nil) {
        self.clock = clock
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork {
        lock.lock()
        nextID += 1
        let id = nextID
        items.append(Item(id: id, due: elapsed + delay, delay: delay, work: work))
        let ready = waiters.filter { items.count >= $0.count }
        waiters.removeAll { items.count >= $0.count }
        let delays = items.map(\.delay)
        lock.unlock()
        for waiter in ready { waiter.continuation.resume(returning: delays) }
        return Handle(self, id)
    }

    /// Returns the pending delays once at least `count` items wait, or after `timeout` with what
    /// waits, so work that is never scheduled fails the test's assertions instead of hanging it.
    func waitForPending(_ count: Int = 1, timeout: TimeInterval = 5) async -> [TimeInterval] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if items.count >= count {
                let delays = items.map(\.delay)
                lock.unlock()
                continuation.resume(returning: delays)
                return
            }
            nextID += 1
            let id = nextID
            waiters.append(Waiter(id: id, count: count, continuation: continuation))
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        let delays = items.map(\.delay)
        lock.unlock()
        waiter.continuation.resume(returning: delays)
    }

    private func cancel(_ id: Int) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
    }

    /// The delays of work still waiting, in the order it was scheduled.
    var pendingDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return items.map(\.delay)
    }

    /// How many scheduled items have run.
    var ranCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ran
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        let target = elapsed + seconds
        lock.unlock()
        while true {
            lock.lock()
            guard let next = items.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) else {
                let rest = target - elapsed
                elapsed = target
                lock.unlock()
                clock?.advance(rest)
                return
            }
            items.removeAll { $0.id == next.id }
            let step = next.due - elapsed
            elapsed = next.due
            ran += 1
            lock.unlock()
            clock?.advance(step)
            next.work()
        }
    }
}

/// Captures the SDK's log lines while a test runs.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    private var token: UUID?

    init() {
        token = Log.observers.add { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.captured.append(line)
            self.lock.unlock()
        }
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stop() {
        if let token { Log.observers.remove(token) }
        token = nil
    }
}

/// A clock whose reads block while its gate is closed, so a test can hold a tracker's queue inside a
/// call and check what another thread sees meanwhile.
final class GateClock: Clock, @unchecked Sendable {
    private let base: Clock
    private let condition = NSCondition()
    private var closed = false
    private var waiting = 0

    init(_ base: Clock) {
        self.base = base
    }

    func close() {
        condition.lock()
        closed = true
        condition.unlock()
    }

    func open() {
        condition.lock()
        closed = false
        condition.broadcast()
        condition.unlock()
    }

    func now() -> Date {
        condition.lock()
        while closed {
            waiting += 1
            condition.broadcast()
            condition.wait()
            waiting -= 1
        }
        condition.unlock()
        return base.now()
    }

    /// True once a read is blocked at the gate, false after `timeout`.
    func waitForReader(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date() + timeout
        condition.lock()
        defer { condition.unlock() }
        while waiting == 0 {
            if !condition.wait(until: deadline) { return waiting > 0 }
        }
        return true
    }
}
