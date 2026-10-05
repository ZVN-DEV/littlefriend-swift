import Foundation

/// One request body (packages/contract/src/events.ts WireBatch). `s` is present in journey mode only
/// and `d` only for test traffic; nil fields are left out of the JSON.
struct WireBatch: JSONWritable, Sendable {
    var v: Int = 1
    var k: String
    var m: String
    var s: String?
    var sv: String
    var d: Int?
    var a: AppInfo?
    var e: [WireEvent]

    func write(to json: inout JSONWriter) {
        json.beginObject()
        json.field("v", v)
        json.field("k", k)
        json.field("m", m)
        json.field("s", s)
        json.field("sv", sv)
        json.field("d", d)
        json.field("a", a)
        json.key("e")
        json.beginArray()
        for event in e {
            json.element()
            event.write(to: &json)
        }
        json.endArray()
        json.endObject()
    }
}
