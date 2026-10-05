import Foundation

/// Campaign fields as the wire carries them: utm_source, utm_medium, utm_campaign, and, only when the
/// project allowlists them, utm_term and utm_content.
struct Campaign: Equatable, Sendable {
    var s: String?
    var m: String?
    var c: String?
    var t: String?
    var n: String?

    init(s: String? = nil, m: String? = nil, c: String? = nil, t: String? = nil, n: String? = nil) {
        self.s = s
        self.m = m
        self.c = c
        self.t = t
        self.n = n
    }
}

/// Deep link UTM tags, mirroring utmFromUrl and sanitizeCampaignValue in packages/contract/src.
enum CampaignRules {
    static let maxValueLength = 64

    private static let keys = ["utm_source", "utm_medium", "utm_campaign"]
    private static let extendedKeys = keys + ["utm_term", "utm_content"]

    /// The allowlisted UTM values from a deep link URL, or nil when none survive. Only the query is
    /// read; the fragment never is.
    static func fromURL(_ url: String, extended: Bool) -> Campaign? {
        guard let query = WebURL.query(of: url) else { return nil }
        let params = FormQuery.parse(query)
        var out = Campaign()
        var kept = 0
        for key in extended ? extendedKeys : keys {
            // URLSearchParams.get: the first value with exactly this name.
            guard let raw = params.first(where: { $0.0 == key })?.1, let value = cleanValue(raw) else { continue }
            switch key {
            case "utm_source": out.s = value
            case "utm_medium": out.m = value
            case "utm_campaign": out.c = value
            case "utm_term": out.t = value
            default: out.n = value
            }
            kept += 1
        }
        return kept > 0 ? out : nil
    }

    /// sanitizeCampaignValue: control characters removed, trimmed, lowercased, cut to 64, and
    /// nil when empty or when it looks like personal data.
    static func cleanValue(_ input: String) -> String? {
        if input.isEmpty { return nil }
        // NSString's canonical mapping matches JavaScript's toLowerCase, final sigma included.
        let lower = (Text.trim(Text.clean(input)) as NSString).lowercased
        let value = Text.prefix(lower, utf16: maxValueLength)
        if value.isEmpty || Text.looksLikePII(value) { return nil }
        return value
    }
}

/// The parts of the WHATWG URL parser that decide whether `new URL(input)` succeeds and what its
/// query is. Host names are percent-decoded and checked for the code points the parser refuses, but
/// not converted with IDNA, and an IPv6 literal is checked for its characters only: deep links reach
/// the SDK already parsed by the system.
enum WebURL {
    private static let specialSchemes: Set<String> = ["ftp", "file", "http", "https", "ws", "wss"]

    /// The query (without `?`), "" when there is none, or nil when the input is not a URL.
    static func query(of input: String) -> String? {
        // Leading and trailing C0 controls and spaces are removed, and tabs and newlines anywhere.
        var units = Array(input.utf16)
        while let f = units.first, f <= 0x20 { units.removeFirst() }
        while let l = units.last, l <= 0x20 { units.removeLast() }
        units.removeAll { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }

        guard let colon = units.firstIndex(of: 0x3A), colon > 0, Text.isAlpha(units[0]),
              units[1..<colon].allSatisfy({ Text.isAlnum($0) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2E })
        else { return nil }
        let scheme = String(decoding: units[0..<colon], as: UTF16.self).lowercased()
        let rest = Array(units[(colon + 1)...])

        let hash = rest.firstIndex(of: 0x23) ?? rest.count
        let mark = rest.firstIndex(of: 0x3F).flatMap { $0 < hash ? $0 : nil }
        let beforeQuery = Array(rest[0..<(mark ?? hash)])

        if specialSchemes.contains(scheme) {
            if scheme != "file" {
                // Any run of slashes or backslashes, then the authority up to the next one.
                var i = 0
                while i < beforeQuery.count && (beforeQuery[i] == 0x2F || beforeQuery[i] == 0x5C) { i += 1 }
                let end = beforeQuery[i...].firstIndex { $0 == 0x2F || $0 == 0x5C } ?? beforeQuery.count
                guard validAuthority(Array(beforeQuery[i..<end]), special: true) else { return nil }
            }
        } else if beforeQuery.starts(with: [0x2F, 0x2F]) {
            let authority = beforeQuery.dropFirst(2)
            let end = authority.firstIndex(of: 0x2F) ?? authority.endIndex
            guard validAuthority(Array(authority[..<end]), special: false) else { return nil }
        }

        guard let q = mark else { return "" }
        return String(decoding: rest[(q + 1)..<hash], as: UTF16.self)
    }

    private static func validAuthority(_ authority: [UInt16], special: Bool) -> Bool {
        let hostPort = authority.lastIndex(of: 0x40).map { Array(authority[($0 + 1)...]) } ?? authority
        var host = hostPort
        var port: [UInt16] = []
        if hostPort.first == 0x5B {
            guard let close = hostPort.firstIndex(of: 0x5D) else { return false }
            host = Array(hostPort[...close])
            let after = hostPort[(close + 1)...]
            if !after.isEmpty {
                guard after.first == 0x3A else { return false }
                port = Array(after.dropFirst())
            }
        } else if let c = hostPort.firstIndex(of: 0x3A) {
            host = Array(hostPort[..<c])
            port = Array(hostPort[(c + 1)...])
        }
        if !port.isEmpty {
            guard port.allSatisfy(Text.isDigit), let n = Int(String(decoding: port, as: UTF16.self)), n <= 65535
            else { return false }
        }
        if host.first == 0x5B {
            let inner = host.dropFirst().dropLast()
            return inner.contains(0x3A) && inner.allSatisfy { Text.isHex($0) || $0 == 0x3A || $0 == 0x2E }
        }
        guard special else { return host.allSatisfy { !forbiddenHost($0, special: false) } }
        if host.isEmpty { return false }
        // A special host is percent-decoded before its code points are checked, and must be UTF-8.
        guard let decoded = percentDecodeStrict(host) else { return false }
        return !decoded.isEmpty && decoded.allSatisfy { !forbiddenHost($0, special: true) }
    }

    /// Each `%XX` becomes its byte, anything else stays, and the bytes must be UTF-8.
    private static func percentDecodeStrict(_ units: [UInt16]) -> [UInt16]? {
        let b = Array(String(decoding: units, as: UTF16.self).utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let hi = Text.hexValue(UInt16(b[i + 1])),
               let lo = Text.hexValue(UInt16(b[i + 2])) {
                bytes.append(hi << 4 | lo)
                i += 3
            } else {
                bytes.append(b[i])
                i += 1
            }
        }
        var out: [UInt16] = []
        let failed = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true) {
            out.append($0)
        }
        return failed ? nil : out
    }

    /// Forbidden host code points, plus, for special schemes, the forbidden domain code points.
    private static func forbiddenHost(_ u: UInt16, special: Bool) -> Bool {
        switch u {
        case 0x00, 0x09, 0x0A, 0x0D, 0x20, 0x23, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x5E, 0x7C:
            return true
        default:
            return special && (u <= 0x1F || u == 0x25 || u == 0x7F)
        }
    }
}

/// application/x-www-form-urlencoded parsing, as URLSearchParams does it.
enum FormQuery {
    static func parse(_ query: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for part in Array(query.utf8).split(separator: 0x26, omittingEmptySubsequences: true) {
            let eq = part.firstIndex(of: 0x3D)
            let name = eq.map { part[part.startIndex..<$0] } ?? part[...]
            let value = eq.map { part[($0 + 1)...] } ?? []
            out.append((decode(name), decode(value)))
        }
        return out
    }

    /// `+` is a space, then each `%XX` is a byte; anything else stays. Bytes that are not UTF-8 become U+FFFD.
    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        let b = Array(bytes)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let hi = Text.hexValue(UInt16(b[i + 1])), let lo = Text.hexValue(UInt16(b[i + 2])) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(b[i] == 0x2B ? 0x20 : b[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// The app block's rules, mirroring parseWireApp in packages/contract/src/apps.ts.
enum AppRules {
    static let maxIdLength = 155
    static let platforms: Set<String> = ["ios", "macos", "android"]
    static let devices: Set<String> = ["mobile", "tablet", "desktop"]

    static func valid(id: String, platform: String, device: String, version: String) -> Bool {
        validId(id) && platforms.contains(platform) && devices.contains(device) && validVersion(version)
    }

    /// `^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$`, at most 155 characters.
    static func validId(_ id: String) -> Bool {
        let u = Array(id.utf16)
        guard u.count <= maxIdLength, let first = u.first, Text.isAlnum(first) else { return false }
        let parts = u.split(separator: 0x2E, omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { Text.isAlnum($0) || $0 == 0x5F || $0 == 0x2D }
        }
    }

    /// `^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$`, and no part between `.`, `-`, `+` or `_` looks like
    /// personal data.
    static func validVersion(_ version: String) -> Bool {
        let u = Array(version.utf16)
        guard u.count <= 32, let first = u.first, Text.isAlnum(first) else { return false }
        let separator: (UInt16) -> Bool = { $0 == 0x2E || $0 == 0x2D || $0 == 0x2B || $0 == 0x5F }
        guard u.allSatisfy({ Text.isAlnum($0) || separator($0) }) else { return false }
        return !u.split(omittingEmptySubsequences: false, whereSeparator: separator).contains {
            Text.looksLikePII(String(decoding: $0, as: UTF16.self))
        }
    }
}
