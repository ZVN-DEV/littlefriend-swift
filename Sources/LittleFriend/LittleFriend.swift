import Foundation

extension LittleFriend {
    /// Starts the SDK with the project's public site key. Calls made before it, at most 100, are
    /// replayed in order with the time each was made. A key that does not match
    /// `^lf_[A-Za-z0-9]{12,40}$`, or an app block the contract refuses, disables the SDK with one log
    /// line. Only the first call counts.
    public static func start(key: String, options: Options = .init()) {
        Facade.shared.start(key: key, options: options, environment: .live())
    }

    /// Records a screen. `route` is a template such as `/orders/:id`, cleaned on the device; `type`
    /// sets the `page_type` prop when it matches `^[a-z][a-z0-9_-]{0,31}$`. The route already on
    /// screen again within a second is ignored.
    public static func screen(_ route: String, type: String? = nil) {
        Facade.shared.perform(.screen(route, type: type))
    }

    /// Records a custom event. `name` matches `^[a-z][a-z0-9_.:-]{0,63}$`; props are cleaned to at most
    /// 8. `correlationId` is sent in journey mode only.
    public static func track(_ name: String, props: [String: PropValue] = [:], correlationId: String? = nil) {
        Facade.shared.perform(.track(name, props: props, correlationId: correlationId))
    }

    /// `.journey` switches a journey mode app that waits for consent to journey mode; `.none` and
    /// `.required` return it to aggregate mode and delete the stored session.
    public static func consent(_ c: Consent) {
        Facade.shared.perform(.consent(c))
    }

    /// Drops what is queued, deletes the session and sends nothing more, across launches, until
    /// `optIn()`. Once the SDK has started, the choice is on disk and the queue and session files are
    /// deleted when this returns: the one call with file operations on the calling thread, three
    /// small ones. Before `start` it waits with the other early calls.
    public static func optOut() {
        Facade.shared.perform(.optOut)
    }

    public static func optIn() {
        Facade.shared.perform(.optIn)
    }

    /// A deep link or universal link that opened the app. Only its allowlisted UTM tags are read; a
    /// link with at least one is the source of a visit. A new visit holds its screens and events for
    /// up to 500 ms, so a link that arrives after the first screen is still that visit's source, and
    /// a screen the link opens is its landing. A later link starts a new visit.
    public static func handle(url: URL) {
        Facade.shared.perform(.handle(url))
    }

    /// Sends what is queued now, without waiting for the batch timer.
    public static func flush() {
        Facade.shared.perform(.flush)
    }
}

/// A UIKit view controller's screen route for `autoScreens`, in place of its class name.
@MainActor
public protocol LFScreen {
    var lfRoute: String { get }
}

/// For SDKs that wrap this one: the label sent as the batch's `sv` and in the user agent. Read once,
/// when `start` builds the engine. Defaults to `ios-0.1.0`, or `macos-0.1.0` on macOS and Mac
/// Catalyst. A label that is not 1 to 24 of `A-Z a-z 0-9 . _ + -`, starting with a letter, is
/// replaced by the default with one log line.
public enum WrapperBridge {
    private static let stored = Locked<String?>(nil)

    public static var sdkLabel: String {
        get { stored.value ?? SDKLabel.platformDefault }
        set { stored.value = newValue }
    }

    /// The label to send: the one set, when it passes the rule, else the default.
    static func resolvedLabel() -> String {
        let label = sdkLabel
        guard SDKLabel.valid(label) else {
            Log.warn("WrapperBridge.sdkLabel is ignored: it must be 1 to 24 letters, digits or ._+- starting with a letter")
            return SDKLabel.platformDefault
        }
        return label
    }

    /// Back to the default, for tests.
    static func reset() {
        stored.value = nil
    }
}

enum SDKLabel {
    static let version = "0.1.0"

    static var platformDefault: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return "macos-\(version)"
        #else
        return "ios-\(version)"
        #endif
    }

    static func valid(_ label: String) -> Bool {
        let u = Array(label.utf8)
        guard (1...24).contains(u.count), let first = u.first, Text.isAlpha(UInt16(first)) else { return false }
        return u.allSatisfy { Text.isAlnum(UInt16($0)) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2B || $0 == 0x2D }
    }
}

/// A value guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value

    init(_ value: Value) {
        current = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}

/// The one engine behind the static API, and the calls made before `start`.
final class Facade: @unchecked Sendable {
    static let shared = Facade()
    /// Calls kept before `start`; later ones are dropped.
    static let bufferLimit = 100

    enum Call: Sendable {
        case screen(String, type: String?)
        case track(String, props: [String: PropValue], correlationId: String?)
        case consent(LittleFriend.Consent)
        case optOut
        case optIn
        case handle(URL)
        case flush
    }

    private enum State {
        case waiting
        /// The key passed; the engine is being built on the main thread.
        case starting
        case running(Tracker)
        case disabled
    }

    /// Times the calls made before `start`.
    private let clock: Clock
    private let lock = NSLock()
    // Guarded by `lock`.
    private var state: State = .waiting
    private var buffer: [(call: Call, at: Date)] = []
    private var dropLogged = false
    /// Keeps the lifecycle observers alive.
    private var attachment: AnyObject?

    init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    func perform(_ call: Call) {
        lock.lock()
        switch state {
        case .waiting, .starting:
            guard buffer.count < Self.bufferLimit else {
                let first = !dropLogged
                dropLogged = true
                lock.unlock()
                if first { Log.warn("a call before start was dropped: at most 100 are kept until start runs") }
                return
            }
            buffer.append((call, clock.now()))
            lock.unlock()
        case let .running(tracker):
            lock.unlock()
            Self.run(call, on: tracker, at: nil)
        case .disabled:
            lock.unlock()
        }
    }

    func start(key: String, options: LittleFriend.Options, environment: Environment) {
        lock.lock()
        guard case .waiting = state else {
            lock.unlock()
            Log.warn("start is ignored: the SDK was started already")
            return
        }
        guard Self.validKey(key) else {
            disableLocked()
            lock.unlock()
            Log.warn("the SDK is disabled: the key does not match ^lf_[A-Za-z0-9]{12,40}$")
            return
        }
        state = .starting
        lock.unlock()
        // The device class and the app's state are read on the main thread; a start from another
        // thread finishes there, and calls made meanwhile wait in the buffer.
        environment.host.onMain {
            self.finishStart(key: key, options: options, environment: environment)
        }
    }

    /// The engine, once `start` has built it.
    var tracker: Tracker? {
        lock.lock()
        defer { lock.unlock() }
        if case let .running(tracker) = state { return tracker }
        return nil
    }

    /// Returns once every call so far has run and the queue is sent, for tests.
    func flushed() async {
        await tracker?.flush()
    }

    static func validKey(_ key: String) -> Bool {
        let u = Array(key.utf16)
        guard (15...43).contains(u.count), u[0] == 0x6C, u[1] == 0x66, u[2] == 0x5F else { return false }
        return u.dropFirst(3).allSatisfy(Text.isAlnum)
    }

    /// The app block `a`: the bundle id, the platform, the device class and the app's version.
    static func appInfo(options: LittleFriend.Options, environment: Environment, device: String) -> AppInfo {
        AppInfo(
            i: environment.bundleID ?? "",
            p: environment.host.platform,
            d: device,
            v: options.appVersion ?? environment.bundleVersion ?? ""
        )
    }

    // MARK: Main thread

    private func finishStart(key: String, options: LittleFriend.Options, environment env: Environment) {
        let app = Self.appInfo(options: options, environment: env, device: env.host.device())
        guard AppRules.valid(id: app.i, platform: app.p, device: app.d, version: app.v) else {
            disable("the SDK is disabled: the app block fails the contract's rules for its bundle id, platform, device or version")
            return
        }
        guard let storage = env.storage else {
            disable("the SDK is disabled: there is no Application Support directory")
            return
        }
        let sdk = WrapperBridge.resolvedLabel()
        let tracker = Tracker(
            options: options, key: key, app: app, sdk: sdk, test: options.test ?? env.detectTest(), storage: storage,
            clock: env.clock, transport: env.makeTransport(options.endpoint, sdk), scheduler: env.scheduler
        )
        // Replayed under the lock, so no later call reaches the engine before an earlier one.
        lock.lock()
        for (call, at) in buffer { Self.run(call, on: tracker, at: at) }
        buffer = []
        state = .running(tracker)
        lock.unlock()
        attachment = env.host.attach(tracker, clock: env.clock, autoScreens: options.autoScreens)
    }

    private func disable(_ reason: String) {
        lock.lock()
        disableLocked()
        lock.unlock()
        Log.warn(reason)
    }

    private func disableLocked() {
        state = .disabled
        buffer = []
    }

    private static func run(_ call: Call, on tracker: Tracker, at date: Date?) {
        switch call {
        case let .screen(route, type): tracker.screen(route, type: type, at: date)
        case let .track(name, props, correlationId): tracker.track(name, props: props, correlationId: correlationId, at: date)
        case let .consent(consent): tracker.consent(consent, at: date)
        case .optOut: tracker.optOut()
        case .optIn: tracker.optIn()
        case let .handle(url): tracker.handle(url: url, at: date)
        case .flush: Task { await tracker.flush() }
        }
    }
}
