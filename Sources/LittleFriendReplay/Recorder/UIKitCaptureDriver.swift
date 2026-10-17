import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Captures the key window of the active scene on the main queue, and reports taps through a
/// non-interfering gesture recognizer on that window. SwiftUI screens are captured through their
/// hosting UIView in the same walk. The recognizer never cancels or delays the app's own touches.
final class UIKitCaptureDriver: NSObject, ReplayCaptureDriver, UIGestureRecognizerDelegate {
    private let onTap: @Sendable (Double, Double) -> Void
    private let lock = NSLock()
    private var generation = 0
    private var recognizer: UITapGestureRecognizer?
    private weak var window: UIWindow?

    init(onTap: @escaping @Sendable (Double, Double) -> Void) {
        self.onTap = onTap
        super.init()
    }

    func capture(
        route: String, timestamp: Int64,
        completion: @escaping @Sendable (ReplayCapturedSnapshot?) -> Void
    ) {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            self.lock.lock()
            let live = token == self.generation
            self.lock.unlock()
            guard live, let window = Self.activeWindow() else {
                completion(nil)
                return
            }
            self.installTapRecognizer(on: window)
            let snapshot = MainActor.assumeIsolated {
                ReplaySerializer.snapshot(root: window, route: route, timestamp: timestamp)
            }
            self.lock.lock()
            let stillLive = token == self.generation
            self.lock.unlock()
            completion(stillLive ? snapshot : nil)
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func detach() {
        cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self, let recognizer = self.recognizer else { return }
            self.window?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
            self.window = nil
        }
    }

    @MainActor
    private static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive }
            + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            if let key = scene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }) { return key }
        }
        return ordered.lazy.flatMap(\.windows).first { !$0.isHidden && $0.rootViewController != nil }
    }

    @MainActor
    private func installTapRecognizer(on window: UIWindow) {
        if self.window === window, recognizer != nil { return }
        if let recognizer, let old = self.window { old.removeGestureRecognizer(recognizer) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap
        self.window = window
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        let point = recognizer.location(in: view)
        onTap(Double(point.x), Double(point.y))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#else
/// No UIKit, no capture: replay stays off and every capture completes empty.
final class UIKitCaptureDriver: ReplayCaptureDriver, @unchecked Sendable {
    init(onTap: @escaping @Sendable (Double, Double) -> Void) {}

    func capture(
        route: String, timestamp: Int64,
        completion: @escaping @Sendable (ReplayCapturedSnapshot?) -> Void
    ) {
        completion(nil)
    }

    func cancel() {}
}
#endif
