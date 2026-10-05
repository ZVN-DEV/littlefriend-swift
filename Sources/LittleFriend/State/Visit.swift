import Foundation

/// One stretch of using the app. It starts at a cold launch, at a return to the foreground after
/// 30 minutes or more in the background, when a deep link with UTM tags arrives, and when consent
/// switches to journey mode after the visit's landing was sent.
struct Visit: Sendable {
    /// A background at least this long ends the visit.
    static let backgroundGapMs: Int64 = 30 * 60 * 1000

    /// The deep link campaign that opened the visit; nil is direct. iOS has no referrer.
    var source: Campaign?
    /// The next screen is the visit's landing (`l: 1`, with `c` from `source`).
    var landingPending: Bool
    /// Started by a cold launch with no deep link, which in journey mode a live stored session continues.
    var coldLaunch: Bool
    /// A screen has been sent in this visit.
    var screened = false
}
