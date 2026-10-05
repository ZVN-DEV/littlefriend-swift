import Foundation
@testable import LittleFriend

/// A transport that keeps every body it is handed and answers from a script, then `.accepted`.
final class RecordingTransport: Transport, @unchecked Sendable {
    /// One event as it reached the transport, with the fields of the batch that carried it.
    struct Sent {
        let batch: [String: JSONValue]
        let event: [String: JSONValue]

        var id: String? { event["i"]?.string }
        var name: String? { event["n"]?.string }
        var route: String? { event["u"]?.string }
        var time: Int64? { event["t"]?.int.map(Int64.init) }
        var seq: Int? { event["q"]?.int }
        var landing: Int? { event["l"]?.int }
        var correlationId: String? { event["x"]?.string }
        var campaign: [String: String]? { event["c"]?.object?.compactMapValues(\.string) }
        var props: [String: JSONValue]? { event["p"]?.object }
        var mode: String? { batch["m"]?.string }
        var session: String? { batch["s"]?.string }
    }

    private struct Waiter {
        let id: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var bodies: [Data] = []
    private var replies: [TransportResult] = []
    private var waiters: [Waiter] = []
    private var nextWaiter = 0

    func reply(_ next: TransportResult...) {
        lock.lock()
        replies.append(contentsOf: next)
        lock.unlock()
    }

    func send(_ body: Data) async -> TransportResult {
        record(body)
    }

    private func record(_ body: Data) -> TransportResult {
        lock.lock()
        bodies.append(body)
        let reply = replies.isEmpty ? .accepted : replies.removeFirst()
        let ready = waiters.filter { bodies.count >= $0.count }
        waiters.removeAll { bodies.count >= $0.count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
        return reply
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bodies.count
    }

    /// Every event received so far, in the order received.
    var sent: [Sent] {
        lock.lock()
        let all = bodies
        lock.unlock()
        return all.flatMap { body -> [Sent] in
            guard case let .object(batch)? = try? JSONDecoder().decode(JSONValue.self, from: body),
                  case let .array(events)? = batch["e"]
            else { return [] }
            return events.compactMap { $0.object.map { Sent(batch: batch, event: $0) } }
        }
    }

    /// Every batch envelope received so far.
    var batches: [[String: JSONValue]] {
        lock.lock()
        let all = bodies
        lock.unlock()
        return all.compactMap { (try? JSONDecoder().decode(JSONValue.self, from: $0))?.object }
    }

    /// Returns once `count` requests have arrived, or after `timeout`.
    func waitForRequests(_ count: Int, timeout: TimeInterval = 5) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if bodies.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            nextWaiter += 1
            let id = nextWaiter
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
        lock.unlock()
        waiter.continuation.resume()
    }
}
