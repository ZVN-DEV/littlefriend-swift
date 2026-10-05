import Foundation

/// Any JSON value, so a vector's `in` can hold shapes the SDK types refuse.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var object: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }

    /// A short form for failure messages: long inputs are cut, with their length.
    var label: String {
        switch self {
        case let .string(s): return Self.cut(s)
        case let .number(d): return String(d)
        case let .bool(b): return String(b)
        case .null: return "null"
        case let .array(a): return "[\(a.map(\.label).joined(separator: ","))]"
        case let .object(o):
            return "{\(o.keys.sorted().map { "\(Self.cut($0)):\(o[$0]!.label)" }.joined(separator: ","))}"
        }
    }

    static func cut(_ s: String) -> String {
        let n = s.utf16.count
        return n <= 80 ? "\"\(s)\"" : "\"\(String(s.prefix(60)))...\" (\(n) chars)"
    }
}
