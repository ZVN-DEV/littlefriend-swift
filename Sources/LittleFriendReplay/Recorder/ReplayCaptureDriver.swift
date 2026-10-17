import Foundation

struct ReplayHitTarget: Sendable, Equatable {
    let nodeID: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func contains(x: Double, y: Double) -> Bool {
        x >= self.x && y >= self.y && x <= self.x + width && y <= self.y + height
    }
}

struct ReplayCapturedSnapshot: Sendable, Equatable {
    let events: [ReplayEvent]
    let hitTargets: [ReplayHitTarget]
}

struct ReplayNativeTap: Sendable, Equatable {
    let x: Double
    let y: Double
    let nodeID: Int
}

protocol ReplayCaptureDriver: AnyObject, Sendable {
    func capture(
        route: String, timestamp: Int64,
        completion: @escaping @Sendable (ReplayCapturedSnapshot?) -> Void
    )
    /// Drops a capture that has not completed yet. Must return at once: opt-out calls it on the
    /// caller's thread.
    func cancel()
    /// Removes anything installed on a window. Called when replay is stopped for good.
    func detach()
}

extension ReplayCaptureDriver {
    func detach() {}
}
