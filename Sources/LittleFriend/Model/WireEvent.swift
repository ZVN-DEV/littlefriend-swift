import Foundation

/// One event as the collector reads it (packages/contract/src/events.ts WireEvent). Optional fields
/// are left out of the JSON when nil.
struct WireEvent: Codable, Sendable, Equatable {
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

    private enum CodingKeys: String, CodingKey { case i, n, t, q, u, r, c, p, l, x }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(i, forKey: .i)
        try c.encode(n, forKey: .n)
        try c.encode(t, forKey: .t)
        try c.encode(q, forKey: .q)
        try c.encode(u, forKey: .u)
        try c.encodeIfPresent(r, forKey: .r)
        try c.encodeIfPresent(self.c, forKey: .c)
        try c.encodeIfPresent(p?.mapValues(WireProp.init), forKey: .p)
        try c.encodeIfPresent(l, forKey: .l)
        try c.encodeIfPresent(x, forKey: .x)
    }

    /// A new event id: a random UUID v4 as 32 lowercase hex digits. With its dashes a UUID is 36
    /// characters, longer than the contract's EVENT_ID_RE allows (8 to 32).
    static func newID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

extension WireEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        i = try c.decode(String.self, forKey: .i)
        n = try c.decode(String.self, forKey: .n)
        t = try c.decode(Int64.self, forKey: .t)
        q = try c.decode(Int.self, forKey: .q)
        u = try c.decode(String.self, forKey: .u)
        r = try c.decodeIfPresent(String.self, forKey: .r)
        self.c = try c.decodeIfPresent(Campaign.self, forKey: .c)
        p = try c.decodeIfPresent([String: WireProp].self, forKey: .p)?.mapValues(\.value)
        l = try c.decodeIfPresent(Int.self, forKey: .l)
        x = try c.decodeIfPresent(String.self, forKey: .x)
    }
}

/// A property value as a bare JSON string, number or boolean.
private struct WireProp: Codable {
    let value: PropValue

    init(_ value: PropValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            value = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            value = .number(n)
        } else {
            value = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        }
    }
}

/// The one JSON configuration for everything the SDK writes, so the byte budget is measured on the
/// bytes that are sent.
enum WireJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}
