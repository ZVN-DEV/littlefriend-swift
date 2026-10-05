import Foundation

/// The app block `a` on every batch (packages/contract/src/apps.ts WireApp): bundle id, platform,
/// device class and the app's version string.
struct AppInfo: Codable, Sendable, Equatable {
    var i: String
    var p: String
    var d: String
    var v: String
}
