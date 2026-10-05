import Foundation

/// One stretch of using the app. It starts at a cold launch, at a return to the foreground after
/// 30 minutes or more in the background, and when a deep link with UTM tags arrives.
struct Visit: Sendable {
    /// A background at least this long ends the visit.
    static let backgroundGapMs: Int64 = 30 * 60 * 1000

    /// The deep link campaign that opened the visit; nil is direct. iOS has no referrer.
    var source: Campaign?
    /// The next screen is the visit's landing (`l: 1`, with `c` from `source`). False once the
    /// landing was sent, and for a cold launch that continues a session whose entry was sent.
    var landingPending: Bool
}
