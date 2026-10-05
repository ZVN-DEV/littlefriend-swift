import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What `start` needs from the platform and the process.
struct Environment: Sendable {
    var host: PlatformHost
    /// Application Support/littlefriend, or nil when there is none.
    var storage: URL?
    var bundleID: String?
    /// CFBundleShortVersionString.
    var bundleVersion: String?
    var clock: Clock
    var scheduler: Scheduler
    var makeTransport: @Sendable (_ endpoint: URL, _ sdk: String) -> Transport
    var detectTest: @Sendable () -> Bool

    static func live() -> Environment {
        let bundleID = Bundle.main.bundleIdentifier
        return Environment(
            host: LiveHost(),
            storage: storageDirectory(bundleID: bundleID),
            bundleID: bundleID,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            clock: SystemClock(),
            scheduler: DispatchScheduler(),
            makeTransport: { endpoint, sdk in URLSessionTransport(endpoint: endpoint, sdk: sdk) },
            detectTest: { TestDetection.isTestTraffic() }
        )
    }

    /// Application Support/littlefriend. On the Mac, Application Support outside a sandbox is shared by
    /// every app of the user, so the directory sits under the bundle id.
    static func storageDirectory(bundleID: String?) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return base.appendingPathComponent(bundleID).appendingPathComponent("littlefriend")
        #else
        return base.appendingPathComponent("littlefriend")
        #endif
    }
}

/// The platform glue `start` uses. `device()` and `attach` run on the thread `onMain` hands them.
protocol PlatformHost: Sendable {
    /// `ios` or `macos`, as the contract's app block names them.
    var platform: String { get }
    /// Runs `work` on the main thread: at once when already on it.
    func onMain(_ work: @escaping @Sendable () -> Void)
    /// `mobile`, `tablet` or `desktop`.
    func device() -> String
    /// Observes the app's lifecycle for `tracker`, counts a start while the app is active as the
    /// cold launch foreground, and turns on `autoScreens` where the platform has them. The result
    /// keeps the observers alive.
    func attach(_ tracker: Tracker, clock: Clock, autoScreens: Bool) -> AnyObject?
}

/// What the lifecycle drives. The tracker in the SDK; a recorder in tests.
protocol LifecycleTarget: AnyObject, Sendable {
    func foreground(at date: Date, coldLaunch: Bool)
    func background(at date: Date)
    func flush() async
}

/// Turns the app's activation, background and termination notifications into tracker calls.
final class Lifecycle: @unchecked Sendable {
    /// How long termination waits for the queue to go out; whatever is left is sent at the next launch.
    static let terminateWait: TimeInterval = 2

    struct Names {
        var active: Notification.Name
        var background: Notification.Name
        var terminate: Notification.Name
    }

    private let target: LifecycleTarget
    private let clock: Clock
    private let center: NotificationCenter
    /// Sends the queue after the app left the foreground; on iOS inside a background task.
    private let sendInBackground: @Sendable (LifecycleTarget) -> Void
    private let lock = NSLock()
    private var activated = false
    private var tokens: [NSObjectProtocol] = []

    init(
        target: LifecycleTarget, clock: Clock, center: NotificationCenter, names: Names,
        sendInBackground: @escaping @Sendable (LifecycleTarget) -> Void
    ) {
        self.target = target
        self.clock = clock
        self.center = center
        self.sendInBackground = sendInBackground
        // Delivered on the posting thread, so termination is handled before the process ends.
        tokens = [
            center.addObserver(forName: names.active, object: nil, queue: nil) { [weak self] _ in self?.becameActive() },
            center.addObserver(forName: names.background, object: nil, queue: nil) { [weak self] _ in
                self?.enteredBackground()
            },
            center.addObserver(forName: names.terminate, object: nil, queue: nil) { [weak self] _ in self?.willTerminate() },
        ]
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }

    /// The first activation of the process is the cold launch.
    func becameActive() {
        lock.lock()
        let coldLaunch = !activated
        activated = true
        lock.unlock()
        target.foreground(at: clock.now(), coldLaunch: coldLaunch)
    }

    func enteredBackground() {
        target.background(at: clock.now())
        sendInBackground(target)
    }

    /// Closes the screen and waits up to `terminateWait` for the queue to go out.
    func willTerminate() {
        target.background(at: clock.now())
        let done = DispatchSemaphore(value: 0)
        let target = self.target
        Task.detached {
            await target.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.terminateWait)
    }
}

#if canImport(UIKit) && !os(watchOS)

/// UIKit: iOS, iPadOS and Mac Catalyst.
struct LiveHost: PlatformHost {
    var platform: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #else
        return "ios"
        #endif
    }

    func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func device() -> String {
        #if targetEnvironment(macCatalyst)
        return "desktop"
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "desktop" }
        return MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile" }
        #endif
    }

    func attach(_ tracker: Tracker, clock: Clock, autoScreens: Bool) -> AnyObject? {
        let lifecycle = Lifecycle(
            target: tracker, clock: clock, center: .default,
            names: .init(
                active: UIApplication.didBecomeActiveNotification,
                background: UIApplication.didEnterBackgroundNotification,
                terminate: UIApplication.willTerminateNotification
            ),
            sendInBackground: { target in
                // UIKit posts on the main thread: the task begins before the notification returns.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { BackgroundSend.start(target) }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { BackgroundSend.start(target) } }
                }
            }
        )
        MainActor.assumeIsolated {
            switch UIApplication.shared.applicationState {
            case .active: lifecycle.becameActive()
            // Launched in the background: the first activation later is the cold launch.
            case .background: tracker.background(at: clock.now())
            default: break
            }
            if autoScreens { UIKitScreens.install() }
        }
        return lifecycle
    }
}

/// Begins and ends the background tasks a send after the app left the foreground runs in.
@MainActor
protocol BackgroundTasks {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ id: UIBackgroundTaskIdentifier)
}

/// The application's background tasks.
struct ApplicationBackgroundTasks: BackgroundTasks {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "io.littlefriend.send", expirationHandler: expiration)
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(id)
    }
}

/// A send after the app entered the background, inside a background task so it can finish.
@MainActor
enum BackgroundSend {
    /// Tests count the tasks through it.
    static var tasks: BackgroundTasks = ApplicationBackgroundTasks()

    static func start(_ target: LifecycleTarget) {
        let task = BackgroundTask(tasks: tasks)
        task.id = task.tasks.begin { task.end() }
        Task { @MainActor in
            await target.flush()
            task.end()
        }
    }
}

/// Ends its background task once, from the expiration handler or after the send.
@MainActor
final class BackgroundTask: Sendable {
    let tasks: BackgroundTasks
    var id: UIBackgroundTaskIdentifier = .invalid

    init(tasks: BackgroundTasks) {
        self.tasks = tasks
    }

    func end() {
        guard id != .invalid else { return }
        tasks.end(id)
        id = .invalid
    }
}

#elseif os(macOS)

/// AppKit. The app counts as in the foreground while it is the active app.
struct LiveHost: PlatformHost {
    var platform: String { "macos" }

    func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func device() -> String { "desktop" }

    func attach(_ tracker: Tracker, clock: Clock, autoScreens: Bool) -> AnyObject? {
        let lifecycle = Lifecycle(
            target: tracker, clock: clock, center: .default,
            names: .init(
                active: NSApplication.didBecomeActiveNotification,
                background: NSApplication.didResignActiveNotification,
                terminate: NSApplication.willTerminateNotification
            ),
            sendInBackground: { target in Task { await target.flush() } }
        )
        // NSApp is nil in a process that never created the application, such as a tool or a test.
        if MainActor.assumeIsolated({ NSApp?.isActive ?? false }) { lifecycle.becameActive() }
        return lifecycle
    }
}

#else

/// No lifecycle: the start is the cold launch foreground.
struct LiveHost: PlatformHost {
    var platform: String { "ios" }
    func onMain(_ work: @escaping @Sendable () -> Void) { work() }
    func device() -> String { "mobile" }
    func attach(_ tracker: Tracker, clock: Clock, autoScreens: Bool) -> AnyObject? {
        tracker.foreground(at: clock.now(), coldLaunch: true)
        return nil
    }
}

#endif
