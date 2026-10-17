@_spi(LittleFriendReplay) import LittleFriend
import Foundation

enum ReplayTransportResult: Equatable, Sendable {
    case accepted
    case retry(after: TimeInterval?)
    case terminal(status: Int)
}

protocol ReplayTransport: Sendable {
    func loadConfig(key: String, appID: String) async -> ReplayClientConfig?
    func send(_ body: Data) async -> ReplayTransportResult
}

final class ReplayURLSessionTransport: ReplayTransport {
    static let timeout: TimeInterval = 10
    static let maxRetryAfter: TimeInterval = 3600

    private let endpoint: URL
    private let chunkURL: URL
    private let userAgent: String
    private let session: URLSession

    init(configuration core: ReplayBridgeConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        endpoint = core.endpoint
        chunkURL = core.endpoint.appendingPathComponent("v1").appendingPathComponent("r")
        userAgent = "LittleFriend/\(core.sdkLabel) LittleFriendReplay/\(replayVersion)"
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Self.timeout
        session = URLSession(configuration: config, delegate: ReplayRefuseRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    var configuration: URLSessionConfiguration { session.configuration }

    func loadConfig(key: String, appID: String) async -> ReplayClientConfig? {
        var components = URLComponents(
            url: endpoint.appendingPathComponent("v1").appendingPathComponent("r").appendingPathComponent("config"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "app", value: appID),
        ]
        guard let url = components?.url else { return nil }
        var request = request(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return ReplayClientConfig.parse(data)
        } catch {
            return nil
        }
    }

    func send(_ body: Data) async -> ReplayTransportResult {
        var request = request(url: chunkURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry(after: nil) }
            return Self.result(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .retry(after: nil)
        }
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.setValue(nil, forHTTPHeaderField: "Origin")
        return request
    }

    static func result(status: Int, retryAfter: String?) -> ReplayTransportResult {
        switch status {
        case 200..<300: return .accepted
        case 429, 500..<600: return .retry(after: retryAfter.flatMap(seconds))
        default: return .terminal(status: status)
        }
    }

    static func seconds(_ header: String) -> TimeInterval? {
        let value = header.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return min(TimeInterval(value) ?? maxRetryAfter, maxRetryAfter)
    }
}

private final class ReplayRefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
