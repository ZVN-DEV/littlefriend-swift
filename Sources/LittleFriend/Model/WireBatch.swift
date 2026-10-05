import Foundation

/// One request body (packages/contract/src/events.ts WireBatch). `s` is present in journey mode only
/// and `d` only for test traffic; nil fields are left out of the JSON.
struct WireBatch: Codable, Sendable, Equatable {
    var v: Int = 1
    var k: String
    var m: String
    var s: String?
    var sv: String
    var d: Int?
    var a: AppInfo?
    var e: [WireEvent]
}
