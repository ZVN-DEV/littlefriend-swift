import Foundation

/// The SDK's JSON for its few shapes: request bodies, queue lines and the session file, written by
/// hand. The writer leaves nil fields out, never escapes `/`, writes an integral double as an integer
/// and any other double in its shortest form, so its output has the content and the length of
/// JSONEncoder's with `.withoutEscapingSlashes`. Keys come in the declared order, and those of `p`
/// in ascending order.
protocol JSONWritable {
    func write(to json: inout JSONWriter)
}

extension JSONWritable {
    /// The JSON bytes, or nil when a number is not finite.
    func json() -> Data? {
        var writer = JSONWriter()
        write(to: &writer)
        return writer.valid ? Data(writer.bytes) : nil
    }
}

struct JSONWriter {
    private(set) var bytes: [UInt8] = []
    /// False once a number that is not finite was written: JSON has none.
    private(set) var valid = true

    mutating func beginObject() { bytes.append(UInt8(ascii: "{")) }
    mutating func endObject() { bytes.append(UInt8(ascii: "}")) }
    mutating func beginArray() { bytes.append(UInt8(ascii: "[")) }
    mutating func endArray() { bytes.append(UInt8(ascii: "]")) }

    /// Before an array element: a comma unless it is the first.
    mutating func element() {
        if let last = bytes.last, last != UInt8(ascii: "{"), last != UInt8(ascii: "[") {
            bytes.append(UInt8(ascii: ","))
        }
    }

    mutating func key(_ name: String) {
        element()
        string(name)
        bytes.append(UInt8(ascii: ":"))
    }

    mutating func string(_ value: String) {
        bytes.append(UInt8(ascii: "\""))
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes.append(contentsOf: [0x5C, 0x22])
            case UInt8(ascii: "\\"): bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x08: bytes.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x09: bytes.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x0A: bytes.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0C: bytes.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0D: bytes.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                bytes.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
            default: bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    mutating func integer(_ value: Int64) {
        bytes.append(contentsOf: String(value).utf8)
    }

    mutating func number(_ value: Double) {
        guard value.isFinite else {
            valid = false
            return
        }
        var text = value.description
        if text.hasSuffix(".0") { text.removeLast(2) }
        bytes.append(contentsOf: text.utf8)
    }

    mutating func bool(_ value: Bool) {
        bytes.append(contentsOf: (value ? "true" : "false").utf8)
    }

    mutating func field(_ name: String, _ value: String?) {
        guard let value else { return }
        key(name)
        string(value)
    }

    mutating func field(_ name: String, _ value: Int64?) {
        guard let value else { return }
        key(name)
        integer(value)
    }

    mutating func field(_ name: String, _ value: Int?) {
        field(name, value.map(Int64.init))
    }

    mutating func field(_ name: String, _ value: JSONWritable?) {
        guard let value else { return }
        key(name)
        value.write(to: &self)
    }
}

/// JSON as JSONSerialization reads it: the reader stays in the system's Foundation. A field is read
/// as JSONDecoder read it: a boolean is only `true` or `false`, an integer is a number with a whole
/// value that fits, and a missing or null optional field is nil.
enum JSON {
    /// The top-level object of a document, or nil when the data is not one.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ value: Any) -> String? {
        value as? String
    }

    static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    static func int64(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return Int64(exactly: number)
    }

    static func int(_ value: Any) -> Int? {
        int64(value).flatMap { Int(exactly: $0) }
    }

    static func bool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    /// A field that may be missing or null: `.some(nil)` then. A present value is read, and nil
    /// means it has another type.
    static func optional<T>(_ value: Any?, _ read: (Any) -> T?) -> T?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        return read(value).map { .some($0) }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
