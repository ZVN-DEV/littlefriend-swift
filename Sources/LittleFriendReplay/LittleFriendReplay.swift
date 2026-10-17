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

private final class ReplayRuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: ReplayCoordinator?
    private var subscription: ReplayBridgeSubscription?
    private weak var liveCoordinator: ReplayCoordinator?

    func start() {
        lock.lock()
        guard coordinator == nil else {
            lock.unlock()
            return
        }
        let driver = UIKitCaptureDriver { [weak self] x, y in
            self?.liveCoordinator?.recordTapAt(x: x, y: y)
        }
        let coordinator = ReplayCoordinator(capture: driver) { configuration in
            ReplayURLSessionTransport(configuration: configuration)
        }
        self.coordinator = coordinator
        liveCoordinator = coordinator
        subscription = ReplayBridge.observe { coordinator.handle($0) }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let coordinator = self.coordinator
        let subscription = self.subscription
        self.coordinator = nil
        liveCoordinator = nil
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
