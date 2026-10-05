import Foundation

/// Sends the queue in batches of one mode and session: when 10 or more events are queued, 5 seconds
/// after the first event queued while no flush runs, and on `flushNow()`. A flush cycle sends one
/// batch at a time until the queue is empty or a batch fails its last retry; then its events stay
/// queued for the next trigger. Nothing is dropped for a network error, a 429 or a 5xx.
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
    private let test: Bool
    private let scheduler: Scheduler
    private let serial = DispatchQueue(label: "io.littlefriend.batcher")
    private let encoder = WireJSON.encoder()

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

    /// Queues the event on disk and starts a flush or the timer. Ignored after `stop()`.
    func enqueue(_ event: QueuedEvent) {
        serial.sync {
            guard !stopped else { return }
            queue.append(event)
            guard !flushing else { return }
            if queue.count >= Self.flushCount {
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
        timer?.cancel()
        timer = nil
        sendNext()
    }

    private func sendNext() {
        let batch = queue.peekBatch(maxEvents: Self.maxEvents, maxBytes: Self.maxBytes) { mode, session in
            self.envelopeSize(mode: mode, session: session)
        }
        guard let first = batch.first else { return finish() }
        let ids = Set(batch.map(\.event.i))
        let wire = envelope(mode: first.mode, session: first.session, events: batch.map(\.event))
        guard let body = try? encoder.encode(wire) else {
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

    private func envelope(mode: String, session: String?, events: [WireEvent]) -> WireBatch {
        let journey = mode == "j"
        return WireBatch(k: key, m: journey ? "j" : "a", s: journey ? session : nil, sv: sdk, d: test ? 1 : nil, a: app, e: events)
    }

    private func envelopeSize(mode: String, session: String?) -> Int {
        (try? encoder.encode(envelope(mode: mode, session: session, events: [])).count) ?? 0
    }
}
