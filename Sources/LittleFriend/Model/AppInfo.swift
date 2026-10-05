import Foundation

/// The app block `a` on every batch (packages/contract/src/apps.ts WireApp): bundle id, platform,
/// device class and the app's version string.
struct AppInfo: JSONWritable, Sendable {
    var i: String
    var p: String
    var d: String
    var v: String

    func write(to json: inout JSONWriter) {
        json.beginObject()
        json.field("i", i)
        json.field("p", p)
        json.field("d", d)
        json.field("v", v)
        json.endObject()
    }
}
