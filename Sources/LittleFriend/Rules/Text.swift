import Foundation

/// Text rules shared by the cleaning rules, mirroring packages/contract/src/sanitize.ts.
///
/// The contract's regular expressions run in JavaScript without the `u` flag: they read UTF-16 code
/// units, `\d` is ASCII only, `[a-z]` with `i` is ASCII only, and `\s` is JavaScript's own whitespace
/// set. Swift's `Character` merges combining marks into the character before them, so every check
/// here reads code units or scalars, never characters.
enum Text {
    /// How much of a value the personal-data checks read.
    static let piiScanLimit = 2048

    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    static func isAlpha(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }
    static func isLower(_ u: UInt16) -> Bool { u >= 0x61 && u <= 0x7A }
    static func isAlnum(_ u: UInt16) -> Bool { isDigit(u) || isAlpha(u) }
    static func isHex(_ u: UInt16) -> Bool {
        isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
    }
    static func isHexLetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66) }

    /// JavaScript's `\s`: WhiteSpace and LineTerminator.
    static func isSpace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return u >= 0x2000 && u <= 0x200A
        }
    }

    /// Removes C0 controls and DEL. A Swift string never holds an unpaired surrogate.
    static func clean(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in value.unicodeScalars where !(s.value <= 0x1F || s.value == 0x7F) {
            scalars.append(s)
        }
        return String(scalars)
    }

    /// JavaScript's `trim()`: removes `\s` from both ends.
    static func trim(_ value: String) -> String {
        let units = Array(value.utf16)
        var start = 0
        var end = units.count
        while start < end && isSpace(units[start]) { start += 1 }
        while end > start && isSpace(units[end - 1]) { end -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// The first `limit` UTF-16 code units, as JavaScript's `slice(0, limit)`. A surrogate pair the cut
    /// would split is left out whole: the collector's cleanText removes that half anyway.
    static func prefix(_ value: String, utf16 limit: Int) -> String {
        let units = value.utf16
        if units.count <= limit { return value }
        var end = limit
        if end > 0, UTF16.isLeadSurrogate(units[units.index(units.startIndex, offsetBy: end - 1)]) { end -= 1 }
        return String(decoding: Array(units.prefix(end)), as: UTF16.self)
    }

    /// The text before the first `?` or `#`.
    static func cutQueryAndFragment(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return value }
        return String(scalars[..<cut])
    }

    /// JavaScript's `decodeURIComponent`: every `%XX` is decoded, and nil stands for its URIError
    /// (a `%` without two hex digits, or bytes that are not valid UTF-8).
    static func decodeURIComponent(_ value: String) -> String? {
        let units = Array(value.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            guard units[i] == 0x25 else {
                out.append(units[i])
                i += 1
                continue
            }
            var bytes: [UInt8] = []
            while i < units.count && units[i] == 0x25 {
                guard i + 2 < units.count, let hi = hexValue(units[i + 1]), let lo = hexValue(units[i + 2]) else {
                    return nil
                }
                bytes.append(hi << 4 | lo)
                i += 3
            }
            var decoded: [UInt16] = []
            let failed = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true) {
                decoded.append($0)
            }
            if failed { return nil }
            out.append(contentsOf: decoded)
        }
        return String(decoding: out, as: UTF16.self)
    }

    static func hexValue(_ u: UInt16) -> UInt8? {
        switch u {
        case 0x30...0x39: return UInt8(u - 0x30)
        case 0x41...0x46: return UInt8(u - 0x41 + 10)
        case 0x61...0x66: return UInt8(u - 0x61 + 10)
        default: return nil
        }
    }

    // MARK: Identifier shapes (sanitize.ts)

    /// `^\d+$`
    static func isNumeric(_ u: [UInt16]) -> Bool { !u.isEmpty && u.allSatisfy(isDigit) }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` with `i`
    static func isUUID(_ u: [UInt16]) -> Bool {
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != 0x2D { return false }
            } else if !isHex(c) {
                return false
            }
        }
        return true
    }

    /// `^[0-9a-f]{16,}$` with `i`
    static func isHexish(_ u: [UInt16]) -> Bool { u.count >= 16 && u.allSatisfy(isHex) }

    /// `^(?=.*\d)(?=.*[a-zA-Z])[A-Za-z0-9_-]{20,}$`
    static func isTokenish(_ u: [UInt16]) -> Bool {
        u.count >= 20
            && u.allSatisfy { isAlnum($0) || $0 == 0x5F || $0 == 0x2D }
            && u.contains(where: isDigit)
            && u.contains(where: isAlpha)
    }

    // MARK: Personal data (sanitize.ts looksLikePII)

    /// True when a string looks like it could identify a person: email, phone or card-like digits.
    /// A value that is entirely a hex digest or a UUID, with at least one hex letter, is an opaque id.
    static func looksLikePII(_ input: String) -> Bool {
        var v = Array(input.utf16)
        if v.count > piiScanLimit { v = Array(v[0..<piiScanLimit]) }
        if v.contains(0x40) && hasEmail(v) { return true }
        if (isHexish(v) || isUUID(v)) && v.contains(where: isHexLetter) { return false }
        return hasLongDigits(v)
    }

    /// `[^\s@/]`
    private static func isEmailPart(_ u: UInt16) -> Bool { !(isSpace(u) || u == 0x40 || u == 0x2F) }

    /// `/[^\s@/]{1,64}@[^\s@/]{1,253}\.[a-z]{2,24}/i`, unanchored. The local part only needs one
    /// character before the `@`, and the top level domain only needs two letters, for a match to exist.
    private static func hasEmail(_ v: [UInt16]) -> Bool {
        for p in v.indices where v[p] == 0x40 {
            guard p > 0, isEmailPart(v[p - 1]) else { continue }
            var run = 0
            var j = p + 1
            while j < v.count {
                if run >= 1 && v[j] == 0x2E && j + 2 < v.count && isAlpha(v[j + 1]) && isAlpha(v[j + 2]) {
                    return true
                }
                if !isEmailPart(v[j]) || run == 253 { break }
                run += 1
                j += 1
            }
        }
        return false
    }

    /// `[\d\s().-]`
    private static func isPhonePart(_ u: UInt16) -> Bool {
        isDigit(u) || isSpace(u) || u == 0x28 || u == 0x29 || u == 0x2E || u == 0x2D
    }

    /// `/\d[\d\s().-]{7,}\d/`, unanchored: within one run of phone characters, the first and last
    /// digits are at least nine characters apart, ends included.
    private static func hasLongDigits(_ v: [UInt16]) -> Bool {
        var first: Int?
        for (i, u) in v.enumerated() {
            if !isPhonePart(u) {
                first = nil
                continue
            }
            guard isDigit(u) else { continue }
            if let f = first {
                if i - f + 1 >= 9 { return true }
            } else {
                first = i
            }
        }
        return false
    }
}
