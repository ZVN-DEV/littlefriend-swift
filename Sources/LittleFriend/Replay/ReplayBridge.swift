import Foundation

@_spi(LittleFriendReplay)
public struct ReplayBridgeConfiguration: Sendable {
    public let key: String
    public let app: ReplayBridgeApp
    public let endpoint: URL
    public let sdkLabel: String
    public let test: Bool
    private let clock: @Sendable () -> Int64

    public init(
        key: String, app: ReplayBridgeApp, endpoint: URL, sdkLabel: String, test: Bool,
        timestamp: @escaping @Sendable () -> Int64
    ) {
        self.key = key
        self.app = app
        self.endpoint = endpoint
        self.sdkLabel = sdkLabel
        self.test = test
        clock = timestamp
    }

    public func timestamp() -> Int64 { clock() }
}

@_spi(LittleFriendReplay)
public struct ReplayBridgeApp: Sendable, Equatable {
    public let i: String
    public let p: String
    public let d: String
    public let v: String

    public init(i: String, p: String, d: String, v: String) {
        self.i = i
        self.p = p
        self.d = d
        self.v = v
    }
}

@_spi(LittleFriendReplay)
public struct ReplayBridgeState: Sendable, Equatable {
    public let sessionID: String?
    public let route: String?
    public let timestamp: Int64
    public let foreground: Bool
    public let journey: Bool
    /// The journey session's start and last analytics activity, on the SDK clock. The add-on
    /// applies the core expiry rules (30 minute idle, 24 hour cap) from these, so a screen left
    /// foregrounded without analytics activity cannot record under an expired session.
    public let sessionStartedAt: Int64?
    public let sessionLastActivityAt: Int64?

    public init(
        sessionID: String?, route: String?, timestamp: Int64, foreground: Bool, journey: Bool,
        sessionStartedAt: Int64? = nil, sessionLastActivityAt: Int64? = nil
    ) {
        self.sessionID = sessionID
        self.route = route
        self.timestamp = timestamp
        self.foreground = foreground
        self.journey = journey
        self.sessionStartedAt = sessionStartedAt
        self.sessionLastActivityAt = sessionLastActivityAt
    }
}

@_spi(LittleFriendReplay)
public enum ReplayBridgeEvent: Sendable {
    case configuration(ReplayBridgeConfiguration)
    case screen(ReplayBridgeState)
    case session(ReplayBridgeState)
    case foreground(ReplayBridgeState)
    case background(ReplayBridgeState)
    case consent(ReplayBridgeState)
    case optIn(ReplayBridgeState)
    case optOut
}

@_spi(LittleFriendReplay)
public final class ReplayBridgeSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit { cancel() }
}

@_spi(LittleFriendReplay)
public enum ReplayBridge {
    /// The observer also receives configuration when it attaches after the core has started.
    public static func observe(
        _ observer: @escaping @Sendable (ReplayBridgeEvent) -> Void
    ) -> ReplayBridgeSubscription {
        Facade.shared.replayObservers.add(observer)
    }
}

/// The tracker's narrow observer channel. It carries no views, text, touches or input values.
final class ReplayBridgeHub: @unchecked Sendable {
    /// One recursive lock serializes registration, catch-up and every live publication, and
    /// delivery happens under it: a catch-up can never be overtaken by a newer event (a consent
    /// withdrawal must never be followed by the stale journey state it withdrew). Recursive so an
    /// observer that calls back into the hub on its delivery thread cannot deadlock.
    private let lock = NSRecursiveLock()
    private var observers: [UUID: @Sendable (ReplayBridgeEvent) -> Void] = [:]
    private var configuration: ReplayBridgeConfiguration?
    /// The latest state-carrying event's state, replayed to an observer that attaches after the
    /// screen it describes was already sent. Cleared on opt-out.
    private var latestState: ReplayBridgeState?

    func add(_ observer: @escaping @Sendable (ReplayBridgeEvent) -> Void) -> ReplayBridgeSubscription {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        if let configuration { observer(.configuration(configuration)) }
        if let latestState {
            observer(.session(latestState))
            if latestState.route != nil { observer(.screen(latestState)) }
        }
        lock.unlock()
        return ReplayBridgeSubscription { [weak self] in self?.remove(id) }
    }

    func attach(_ configuration: ReplayBridgeConfiguration) {
        lock.lock()
        self.configuration = configuration
        let current = Array(observers.values)
        for observer in current { observer(.configuration(configuration)) }
        lock.unlock()
    }

    func publish(_ event: ReplayBridgeEvent) {
        lock.lock()
        switch event {
        case let .screen(state), let .session(state), let .foreground(state),
             let .background(state), let .consent(state), let .optIn(state):
            latestState = state
        case .optOut:
            latestState = nil
        case .configuration:
            break
        }
        let current = Array(observers.values)
        for observer in current { observer(event) }
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }
}
