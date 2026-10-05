import Foundation

protocol Transport: Sendable {
    func send(_ body: Data) async -> TransportResult
}

enum TransportResult: Equatable, Sendable {
    /// 2xx: the collector has the batch.
    case accepted
    /// 429, 5xx or a network error: send the same body again later. `after` is Retry-After in seconds.
    case retry(after: TimeInterval?)
    /// Any other status: the batch will never be accepted.
    case drop(status: Int)
}

/// POST <endpoint>/v1/e on an ephemeral URLSession: a JSON body, the user agent
/// `LittleFriend/<sdk label>`, no Origin header, no cookies, no cache, no redirects, and a 10 second
/// request timeout.
final class URLSessionTransport: Transport {
    static let timeout: TimeInterval = 10

    let url: URL
    private let userAgent: String
    private let session: URLSession

    /// `configuration` is copied, then stripped of cookie, credential and cache storage.
    init(endpoint: URL, sdk: String, configuration: URLSessionConfiguration = .ephemeral) {
        url = endpoint.appendingPathComponent("v1").appendingPathComponent("e")
        userAgent = "LittleFriend/\(sdk)"
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Self.timeout
        session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    var configuration: URLSessionConfiguration { session.configuration }

    func send(_ body: Data) async -> TransportResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Without it URLSession sends the device's preferred languages.
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry(after: nil) }
            return Self.result(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .retry(after: nil)
        }
    }

    static func result(status: Int, retryAfter: String?) -> TransportResult {
        switch status {
        case 200..<300: return .accepted
        case 429, 500..<600: return .retry(after: retryAfter.flatMap(seconds))
        default: return .drop(status: status)
        }
    }

    /// Retry-After as a whole number of seconds. The HTTP date form and anything else count as absent.
    static func seconds(_ header: String) -> TimeInterval? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return TimeInterval(value)
    }
}

/// A redirect is answered with its own 3xx status, which drops the batch: the body never follows
/// a redirect to another address.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
