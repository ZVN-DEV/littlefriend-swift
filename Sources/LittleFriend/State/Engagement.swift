import Foundation

/// Time the current screen was visible with the app in the foreground, for `$engage`. A clock that
/// moved back counts 0, never a negative span.
struct Engagement: Sendable {
    /// Shorter spans send no `$engage`.
    static let minMs: Int64 = 1000
    /// The most one screen counts.
    static let capMs: Int64 = 30 * 60 * 1000

    /// The route the counted time is recorded under; nil when no screen is open.
    private(set) var route: String?
    /// When counting started; nil while paused.
    private var since: Int64?
    private var ms: Int64 = 0

    /// A new screen with a fresh count, counting at once when the app is in the foreground.
    mutating func open(_ route: String, at t: Int64, counting: Bool) {
        self.route = route
        ms = 0
        since = counting ? t : nil
    }

    mutating func pause(at t: Int64) {
        guard let start = since else { return }
        ms += max(0, t - start)
        since = nil
    }

    /// Counts again on the open screen, if there is one.
    mutating func resume(at t: Int64) {
        guard route != nil, since == nil else { return }
        since = t
    }

    /// The time counted so far, capped, and a fresh count paused on the same route.
    mutating func take(at t: Int64) -> Int64 {
        pause(at: t)
        let counted = min(ms, Self.capMs)
        ms = 0
        return counted
    }

    /// No screen open: nothing counts until the next one.
    mutating func clear() {
        route = nil
        since = nil
        ms = 0
    }
}
