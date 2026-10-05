import Foundation

/// A property value an event may carry.
public enum PropValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

/// Property cleaning, mirroring cleanProps in packages/contract/src/validate.ts.
enum Props {
    static let maxProps = 8
    static let maxKeyLength = 32
    static let maxStringLength = 64

    /// The kept properties, or nil when none survive. Keys are read in ascending order, so which 8 are
    /// kept does not depend on dictionary order.
    static func clean(_ input: [String: PropValue]) -> [String: PropValue]? {
        var out: [String: PropValue] = [:]
        for key in input.keys.sorted() {
            if out.count >= maxProps || !validKey(key) { continue }
            switch input[key]! {
            case let .string(raw):
                let text = Text.clean(raw)
                if Text.looksLikePII(text) { continue }
                out[key] = .string(Text.prefix(text, utf16: maxStringLength))
            case let .number(n):
                guard n.isFinite else { continue }
                out[key] = .number(n)
            case let .bool(b):
                out[key] = .bool(b)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// `^[a-z][a-z0-9_]{0,31}$`
    static func validKey(_ key: String) -> Bool {
        let u = Array(key.utf16)
        guard let first = u.first, u.count <= maxKeyLength, Text.isLower(first) else { return false }
        return u.dropFirst().allSatisfy { Text.isLower($0) || Text.isDigit($0) || $0 == 0x5F }
    }
}
