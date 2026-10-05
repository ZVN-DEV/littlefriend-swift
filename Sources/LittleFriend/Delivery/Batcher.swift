import Foundation

/// Sends the queue in batches of one mode, session and test flag: once 10 events have been enqueued since the
/// current or last cycle started, 5 seconds after an enqueue that found no timer and no cycle, and
/// on `flushNow()`. A flush cycle sends one batch at a time until the queue is empty or a batch
/// fails its last retry; then its events stay queued for the next trigger. Nothing is dropped for a
/// network error, a 429 or a 5xx. Events the collector would refuse as clock skew are dropped
/// before every batch.
final class Batcher: @unchecked Sendable {
    static let flushCount = 10
    static let flushDelay: TimeInterval = 5
    static let maxEvents = 50
    static let maxBytes = 15_000
    /// The wait before each retry; there are as many retries as delays.
    static let retryDelays: [TimeInterval] = [1, 4, 16]
    static let minRetryDelay: TimeInterval = 1
    static let maxRetryDelay: TimeInterval = 30

    private let queue: EventQueue
    private let transport: Transport
    private let key: String
    private let app: AppInfo
    private let sdk: String
    /// Stamped on every event this batcher enqueues. A batch's `d` comes from its events, so events
    /// a test run left in the queue go out as test traffic from any later process.
    private let test: Bool
    private let scheduler: Scheduler
    private let serial = DispatchQueue(label: "io.littlefriend.batcher")

    // Read and written on `serial` only.
    private var timer: ScheduledWork?
    private var timerID = 0
    private var retry: ScheduledWork?
    private var inFlight: Task<Void, Never>?
    private var flushing = false
    private var stopped = false
    /// Changes when a cycle starts and when the batcher stops, so an answer to an older cycle's
    /// request never drives a newer cycle.
    private var cycle = 0
    /// Events enqueued since the current or last cycle started.
    private var enqueuedSinceCycle = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        queue: EventQueue, transport: Transport, key: String, app: AppInfo, sdk: String, test: Bool,
        scheduler: Scheduler
    ) {
        self.queue = queue
        self.transport = transport
        self.key = key
        self.app = app
        self.sdk = sdk
        self.test = test
        self.scheduler = scheduler
    }

    /// Queues the event on disk with this batcher's test flag and starts a flush or the timer.
    /// Ignored after `stop()`.
    func enqueue(_ event: QueuedEvent) {
        serial.sync {
            guard !stopped else { return }
            var stamped = event
            stamped.test = test
            queue.append(stamped)
            enqueuedSinceCycle += 1
            guard !flushing else { return }
            if enqueuedSinceCycle >= Self.flushCount {
                startCycle()
            } else if timer == nil {
                timerID += 1
                let id = timerID
                timer = scheduler.schedule(after: Self.flushDelay) { [weak self] in self?.timerFired(id) }
            }
        }
    }

    /// Returns when the queue is empty, a batch has failed its last retry, or the batcher stops.
    /// Joins a cycle that is already running.
    func flushNow() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            serial.async {
                guard !self.stopped else { return continuation.resume() }
                self.waiters.append(continuation)
                if !self.flushing { self.startCycle() }
            }
        }
    }

    /// Cancels the timer, any pending retry and the request in flight. Nothing is sent after it
    /// returns, and the queue is left to its owner.
    func stop() {
        serial.sync {
            stopped = true
            cycle += 1
            timer?.cancel()
            timer = nil
            retry?.cancel()
            retry = nil
            inFlight?.cancel()
            inFlight = nil
            finish()
        }
    }

    /// The wait before retry number `attempt + 1`: Retry-After when the collector gave one, else the
    /// backoff, clamped to 1 to 30 seconds.
    static func retryDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let delay = retryAfter ?? retryDelays[min(attempt, retryDelays.count - 1)]
        return min(max(delay, minRetryDelay), maxRetryDelay)
    }

    /// Called on the scheduler's thread. A timer that was cancelled or replaced does nothing.
    private func timerFired(_ id: Int) {
        serial.async {
            guard id == self.timerID, self.timer != nil else { return }
            self.timer = nil
            guard !self.stopped, !self.flushing else { return }
            self.startCycle()
        }
    }

    // MARK: On `serial` only

    private func startCycle() {
        flushing = true
        cycle += 1
        enqueuedSinceCycle = 0
        timer?.cancel()
        timer = nil
        sendNext()
    }

    private func sendNext() {
        let stale = queue.removeOutsideWindow()
        if stale > 0 {
            Log.warn("\(stale) events outside the collector's time window were dropped before sending")
        }
        let batch = queue.peekBatch(maxEvents: Self.maxEvents, maxBytes: Self.maxBytes) { first in
            self.envelopeSize(for: first)
        }
        guard let first = batch.first else { return finish() }
        let ids = Set(batch.map(\.event.i))
        let wire = envelope(for: first, events: batch.map(\.event))
        guard let body = wire.json() else {
            // Values the queue accepted always encode; dropping keeps a cycle from repeating forever.
            Log.warn("a batch of \(batch.count) events could not be encoded and was dropped")
            queue.remove(ids: ids)
            return sendNext()
        }
        send(body, ids: ids, attempt: 0, token: cycle)
    }

    private func send(_ body: Data, ids: Set<String>, attempt: Int, token: Int) {
        let transport = self.transport
        inFlight = Task { [weak self] in
            // A send that stop() cancelled before it began never reaches the network.
            guard !Task.isCancelled else { return }
            let result = await transport.send(body)
            self?.serial.async { [weak self] in
                self?.handle(result, body: body, ids: ids, attempt: attempt, token: token)
            }
        }
    }

    private func handle(_ result: TransportResult, body: Data, ids: Set<String>, attempt: Int, token: Int) {
        let current = token == cycle && !stopped
        if current { inFlight = nil }
        switch result {
        case .accepted:
            queue.remove(ids: ids)
            if current { sendNext() }
        case let .drop(status):
            queue.remove(ids: ids)
            Log.warn("a batch of \(ids.count) events was refused with HTTP \(status) and dropped")
            if current { sendNext() }
        case let .retry(after):
            guard current else { return }
            guard attempt < Self.retryDelays.count else { return finish() }
            let delay = Self.retryDelay(attempt: attempt, retryAfter: after)
            retry = scheduler.schedule(after: delay) { [weak self] in
                self?.serial.async { [weak self] in
                    guard let self, token == self.cycle, !self.stopped, self.retry != nil else { return }
                    self.retry = nil
                    self.send(body, ids: ids, attempt: attempt + 1, token: token)
                }
            }
        }
    }

    private func finish() {
        flushing = false
        let done = waiters
        waiters.removeAll()
        for waiter in done { waiter.resume() }
    }

    /// The batch for events that share `first`'s mode, session and test flag.
    private func envelope(for first: QueuedEvent, events: [WireEvent]) -> WireBatch {
        let journey = first.mode == "j"
        return WireBatch(
            k: key, m: journey ? "j" : "a", s: journey ? first.session : nil, sv: sdk, d: first.test ? 1 : nil, a: app,
            e: events
        )
    }

    private func envelopeSize(for first: QueuedEvent) -> Int {
        envelope(for: first, events: []).json()?.count ?? 0
    }
}
