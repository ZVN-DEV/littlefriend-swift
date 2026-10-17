@_spi(LittleFriendReplay) import LittleFriend
import Foundation

struct ReplayPendingChunk: Sendable, Equatable {
    let sessionID: String
    let pageID: String
    let sequence: Int
    let body: Data
    let hasSnapshot: Bool
}

enum ReplayChunkFactory {
    static let maxChunkBytes = 256 * 1024
    static let maxSnapshotChunkBytes = 1024 * 1024

    static func make(
        core: ReplayBridgeConfiguration, sessionID: String, pageID: String, sequence: Int, route: String,
        events: [ReplayEvent]
    ) throws -> ReplayPendingChunk {
        guard !events.isEmpty, events.count <= 5000 else { throw ReplayChunkError.invalidEvents }
        let snapshot = events.contains(where: \.isFullSnapshot)
        let wire = ReplayWireChunk(
            k: core.key, s: sessionID, p: pageID, q: sequence, sv: replayRecorderLabel, u: route,
            d: core.test ? 1 : nil, a: ReplayWireApp(core.app), e: events
        )
        let body = try ReplayWire.encoded(wire)
        let limit = snapshot ? maxSnapshotChunkBytes : maxChunkBytes
        guard body.count <= limit else { throw ReplayChunkError.tooLarge }
        return ReplayPendingChunk(
            sessionID: sessionID, pageID: pageID, sequence: sequence, body: body, hasSnapshot: snapshot
        )
    }
}

enum ReplayChunkError: Error { case invalidEvents, tooLarge }

protocol ReplayRetryWaiting: Sendable {
    func wait(_ delay: TimeInterval) async
}

struct ReplayTaskWaiting: ReplayRetryWaiting {
    func wait(_ delay: TimeInterval) async {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// One in-memory ordered queue. A retry sends the exact same body, session, page and sequence.
final class ReplayChunkSender: @unchecked Sendable {
    static let retryDelays: [TimeInterval] = [1, 4, 16]

    private let transport: ReplayTransport
    private let waiting: ReplayRetryWaiting
    private let maxChunks: Int
    private let maxBytes: Int
    private let onTerminal: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var queue: [ReplayPendingChunk] = []
    private var bytes = 0
    private var pumpTask: Task<Void, Never>?
    private var generation = 0
    private var stopped = false

    init(
        transport: ReplayTransport, waiting: ReplayRetryWaiting = ReplayTaskWaiting(),
        maxChunks: Int = 32, maxBytes: Int = 4 * 1024 * 1024,
        onTerminal: @escaping @Sendable (Int) -> Void
    ) {
        self.transport = transport
        self.waiting = waiting
        self.maxChunks = maxChunks
        self.maxBytes = maxBytes
        self.onTerminal = onTerminal
    }

    /// False means the bound was exceeded: all pending chunks are discarded and the caller stops capture.
    func enqueue(_ chunk: ReplayPendingChunk) -> Bool {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return false
        }
        guard chunk.body.count <= maxBytes, queue.count < maxChunks, bytes + chunk.body.count <= maxBytes else {
            discardLocked()
            lock.unlock()
            return false
        }
        queue.append(chunk)
        bytes += chunk.body.count
        startPumpLocked()
        lock.unlock()
        return true
    }

    func poke() {
        lock.lock()
        startPumpLocked()
        lock.unlock()
    }

    /// Cancels retries and requests, and clears every chunk that has not been accepted.
    func discardPending() {
        lock.lock()
        discardLocked()
        lock.unlock()
    }

    func stopAndClear() {
        lock.lock()
        stopped = true
        discardLocked()
        lock.unlock()
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var isSending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pumpTask != nil
    }

    static func retryDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let delay = retryAfter ?? retryDelays[min(attempt, retryDelays.count - 1)]
        return min(max(delay, 1), 30)
    }

    private func discardLocked() {
        generation += 1
        pumpTask?.cancel()
        pumpTask = nil
        queue.removeAll()
        bytes = 0
    }

    private func startPumpLocked() {
        guard !stopped, pumpTask == nil, !queue.isEmpty else { return }
        let token = generation
        pumpTask = Task { [weak self] in
            await self?.pump(token: token)
        }
    }

    private func pump(token: Int) async {
        var attempt = 0
        while !Task.isCancelled {
            let next: ReplayPendingChunk?
            lock.lock()
            next = token == generation && !stopped ? queue.first : nil
            lock.unlock()
            guard let chunk = next else { return }
            let result = await transport.send(chunk.body)
            guard !Task.isCancelled else { return }

            var terminal: Int?
            var wait: TimeInterval?
            var finished = false
            lock.lock()
            guard token == generation, !stopped, queue.first == chunk else {
                lock.unlock()
                return
            }
            switch result {
            case .accepted:
                queue.removeFirst()
                bytes -= chunk.body.count
                attempt = 0
                if queue.isEmpty {
                    pumpTask = nil
                    finished = true
                }
            case let .terminal(status):
                queue.removeAll()
                bytes = 0
                stopped = true
                pumpTask = nil
                terminal = status
                finished = true
            case let .retry(after):
                if attempt < Self.retryDelays.count {
                    wait = Self.retryDelay(attempt: attempt, retryAfter: after)
                    attempt += 1
                } else {
                    pumpTask = nil
                    finished = true
                }
            }
            lock.unlock()
            if let terminal {
                onTerminal(terminal)
                return
            }
            if finished { return }
            if let wait {
                await waiting.wait(wait)
                if Task.isCancelled { return }
            }
        }
    }
}
