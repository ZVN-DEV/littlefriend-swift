import Foundation

/// The SDK's wall clock. Every timestamp and every age check reads it, so tests can move time.
protocol Clock: Sendable {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

extension Clock {
    /// Epoch milliseconds, as event timestamps carry them.
    func nowMs() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// Work that a scheduler will run unless it is cancelled first.
protocol ScheduledWork: Sendable {
    func cancel()
}

/// Runs work after a delay. Timers and retry waits go through it, so tests can run them without waiting.
protocol Scheduler: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork
}

final class DispatchScheduler: Scheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "io.littlefriend.scheduler")) {
        self.queue = queue
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return DispatchWork(item: item)
    }

    /// DispatchWorkItem's cancel() may be called from any thread.
    private final class DispatchWork: ScheduledWork, @unchecked Sendable {
        private let item: DispatchWorkItem
        init(item: DispatchWorkItem) {
            self.item = item
        }

        func cancel() { item.cancel() }
    }
}
