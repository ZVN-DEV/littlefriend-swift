import Foundation
@testable import LittleFriend

/// A collector stand-in behind a URLProtocol: each instance answers on its own host, so tests never
/// share state. Replies are consumed in order; once they run out every request gets 202.
final class StubServer: @unchecked Sendable {
    enum Reply {
        case status(Int, headers: [String: String] = [:])
        case networkError
        /// The request arrives and no answer ever comes back.
        case hang
    }

    struct Request {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
        let shouldHandleCookies: Bool
        let cachePolicy: URLRequest.CachePolicy
        let timeout: TimeInterval

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }

        /// The body's events, read back as a queue line holds them.
        var events: [WireEvent]? {
            guard let items = JSON.object(body)?["e"] as? [Any] else { return nil }
            let events = items.compactMap { WireEvent(json: $0) }
            return events.count == items.count ? events : nil
        }

        var ids: [String] { events?.map(\.i) ?? [] }

        /// Header lookup ignoring case.
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private struct Waiter {
        let id: Int
        let count: Int
        let continuation: CheckedContinuation<[Request], Never>
    }

    let host = "stub-\(UUID().uuidString.lowercased()).test"
    var endpoint: URL { URL(string: "https://\(host)")! }

    private let lock = NSLock()
    private var replies: [Reply] = []
    private var received: [Request] = []
    private var waiters: [Waiter] = []
    private var nextWaiter = 0

    init() {
        StubProtocol.register(self)
    }

    func close() {
        StubProtocol.unregister(self)
    }

    /// An ephemeral configuration whose requests reach this stub.
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return config
    }

    func reply(_ next: Reply...) {
        lock.lock()
        replies.append(contentsOf: next)
        lock.unlock()
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Returns once `count` requests have arrived, or after `timeout` with what has arrived, so a
    /// missing request fails the test's assertions instead of hanging it.
    func waitForRequests(_ count: Int, timeout: TimeInterval = 5) async -> [Request] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if received.count >= count {
                let now = received
                lock.unlock()
                continuation.resume(returning: now)
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
        let now = received
        lock.unlock()
        waiter.continuation.resume(returning: now)
    }

    fileprivate func handle(_ request: Request) -> Reply {
        lock.lock()
        received.append(request)
        let reply = replies.isEmpty ? .status(202) : replies.removeFirst()
        let ready = waiters.filter { received.count >= $0.count }
        waiters.removeAll { received.count >= $0.count }
        let now = received
        lock.unlock()
        for waiter in ready { waiter.continuation.resume(returning: now) }
        return reply
    }
}

final class StubProtocol: URLProtocol {
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var servers: [String: StubServer] = [:]

        func add(_ server: StubServer) {
            lock.lock()
            servers[server.host] = server
            lock.unlock()
        }

        func remove(_ server: StubServer) {
            lock.lock()
            servers[server.host] = nil
            lock.unlock()
        }

        func server(for host: String?) -> StubServer? {
            lock.lock()
            defer { lock.unlock() }
            return host.flatMap { servers[$0] }
        }
    }

    private static let registry = Registry()

    static func register(_ server: StubServer) { registry.add(server) }
    static func unregister(_ server: StubServer) { registry.remove(server) }

    override class func canInit(with request: URLRequest) -> Bool {
        registry.server(for: request.url?.host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.registry.server(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let captured = StubServer.Request(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request),
            shouldHandleCookies: request.httpShouldHandleCookies,
            cachePolicy: request.cachePolicy,
            timeout: request.timeoutInterval
        )
        switch server.handle(captured) {
        case let .status(code, headers):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    /// URLSession hands a request's body to a protocol as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
