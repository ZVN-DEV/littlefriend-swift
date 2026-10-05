import Foundation

/// One event as the collector reads it (packages/contract/src/events.ts WireEvent). Optional fields
/// are left out of the JSON when nil.
struct WireEvent: JSONWritable, Sendable, Equatable {
    /// Event id, the same on every retry so the collector can dedupe.
    var i: String
    var n: String
    /// Observed time, epoch milliseconds.
    var t: Int64
    var q: Int
    var u: String
    var r: String? = nil
    var c: Campaign? = nil
    var p: [String: PropValue]? = nil
    var l: Int? = nil
    var x: String? = nil

    /// `p` is written with its keys in ascending order.
    func write(to json: inout JSONWriter) {
        json.beginObject()
        json.field("i", i)
        json.field("n", n)
        json.field("t", t)
        json.field("q", q)
        json.field("u", u)
        json.field("r", r)
        json.field("c", c)
        if let p {
            json.key("p")
            json.beginObject()
            for key in p.keys.sorted() {
                json.key(key)
                switch p[key] {
                case let .string(value)?: json.string(value)
                case let .number(value)?: json.number(value)
                case let .bool(value)?: json.bool(value)
                case nil: break
                }
            }
            json.endObject()
        }
        json.field("l", l)
        json.field("x", x)
        json.endObject()
    }

    /// A new event id: a random UUID v4 as 32 lowercase hex digits. With its dashes a UUID is 36
    /// characters, longer than the contract's EVENT_ID_RE allows (8 to 32).
    static func newID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

extension WireEvent {
    /// An event as a queue line holds it; nil when a field is missing or has the wrong type. Fields
    /// a later version added are ignored.
    init?(json value: Any) {
        guard let f = value as? [String: Any],
              let i = f["i"].flatMap(JSON.string), let n = f["n"].flatMap(JSON.string), let t = f["t"].flatMap(JSON.int64),
              let q = f["q"].flatMap(JSON.int), let u = f["u"].flatMap(JSON.string),
              let r = JSON.optional(f["r"], JSON.string),
              let c = JSON.optional(f["c"], Campaign.init(json:)),
              let p = JSON.optional(f["p"], Self.props),
              let l = JSON.optional(f["l"], JSON.int),
              let x = JSON.optional(f["x"], JSON.string)
        else { return nil }
        self.init(i: i, n: n, t: t, q: q, u: u, r: r, c: c, p: p, l: l, x: x)
    }

    /// Each value a bare string, number or boolean.
    private static func props(_ value: Any) -> [String: PropValue]? {
        guard let fields = value as? [String: Any] else { return nil }
        var props: [String: PropValue] = [:]
        for (key, field) in fields {
            if let b = JSON.bool(field) {
                props[key] = .bool(b)
            } else if let n = JSON.number(field) {
                props[key] = .number(n)
            } else if let s = JSON.string(field) {
                props[key] = .string(s)
            } else {
                return nil
            }
        }
        return props
    }
}
