@_spi(LittleFriendReplay) import LittleFriend
import Foundation

/// Masked static wireframe replay for iOS, as an add-on to Little Friend analytics.
///
/// Call `start()` once, before or after `LittleFriend.start(key:)`. Recording happens only while
/// the project's replay config is on, the app runs in journey mode with a live session, the
/// session is sampled in and the current route is not excluded. Every text run is masked before
/// it leaves the device, and input values, checked or selected state, chosen options, images,
/// accessibility labels and native identifiers are never read. `LittleFriend.optOut()` stops
/// recording and clears pending chunks before it returns.
///
/// This is masked static wireframe replay, not full-fidelity native animation: one wireframe per
/// screen appearance, plus taps.
public enum LittleFriendReplay {
    private static let box = ReplayRuntimeBox()

    /// Starts observing the analytics core. Only the first call counts until `stop()`.
    public static func start() {
        box.start()
    }

    /// Stops recording, discards pending chunks and removes the tap observer.
    public static func stop() {
        box.stop()
    }

    /// Sends buffered tap events now instead of waiting for the flush timer.
    public static func flush() {
        box.flush()
    }
}

/// A lock-guarded weak reference to one coordinator instance. A driver's tap callback is bound
/// to the coordinator that owns that driver, never to whatever runtime replaces it, and every
/// access is synchronized so callbacks and start/stop on different threads cannot race.
final class ReplayCoordinatorRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: ReplayCoordinator?

    func bind(_ coordinator: ReplayCoordinator) {
        lock.lock()
        value = coordinator
        lock.unlock()
    }

    func recordTapAt(x: Double, y: Double) {
        lock.lock()
        let coordinator = value
        lock.unlock()
        coordinator?.recordTapAt(x: x, y: y)
    }

    var isBound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }
}

private final class ReplayRuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: ReplayCoordinator?
    private var subscription: ReplayBridgeSubscription?

    func start() {
        lock.lock()
        guard coordinator == nil else {
            lock.unlock()
            return
        }
        let owner = ReplayCoordinatorRef()
        let driver = UIKitCaptureDriver { x, y in
            owner.recordTapAt(x: x, y: y)
        }
        let coordinator = ReplayCoordinator(capture: driver) { configuration in
            ReplayURLSessionTransport(configuration: configuration)
        }
        owner.bind(coordinator)
        self.coordinator = coordinator
        subscription = ReplayBridge.observe { coordinator.handle($0) }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let coordinator = self.coordinator
        let subscription = self.subscription
        self.coordinator = nil
        self.subscription = nil
        lock.unlock()
        subscription?.cancel()
        coordinator?.stop()
    }

    func flush() {
        lock.lock()
        let coordinator = self.coordinator
        lock.unlock()
        coordinator?.flush()
    }
}
