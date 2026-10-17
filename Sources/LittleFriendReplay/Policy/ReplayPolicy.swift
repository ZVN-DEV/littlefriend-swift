import Foundation

struct ReplayClientConfig: Sendable, Equatable {
    let on: Bool
    let rate: Double
    let exclude: [String]

    static func parse(_ data: Data) -> ReplayClientConfig? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["v"] as? NSNumber, version.intValue == 1,
              let on = object["on"] as? NSNumber,
              let rate = object["rate"] as? NSNumber,
              let exclude = object["exclude"] as? [String]
        else { return nil }
        let value = rate.doubleValue
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return ReplayClientConfig(on: on.boolValue, rate: value, exclude: Array(exclude.prefix(50)))
    }
}

enum ReplayPolicy {
    /// FNV-1a over the ASCII session id, in hundredths of a percent, as the web recorder uses.
    static func sampled(sessionID: String, rate: Double) -> Bool {
        guard rate > 0 else { return false }
        var hash = UInt32(0x811C9DC5)
        for byte in sessionID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return Double(hash % 10_000) < rate * 100
    }

    /// A pattern covers its own route and everything below it, on segment boundaries. A trailing
    /// `/*` is the same prefix, and a `*` segment stands for one non-empty segment, matching the
    /// collector's `replayRouteExcluded`.
    static func excluded(route: String, patterns: [String]) -> Bool {
        let have = route.split(separator: "/", omittingEmptySubsequences: false)
        for raw in patterns.prefix(50) {
            var pattern = raw.trimmingCharacters(in: .whitespaces)
            guard pattern.hasPrefix("/") else { continue }
            if pattern.hasSuffix("/*") { pattern.removeLast() }
            if pattern.count > 1, pattern.hasSuffix("/") { pattern.removeLast() }
            if pattern == "/" { return true }
            let want = pattern.split(separator: "/", omittingEmptySubsequences: false)
            guard have.count >= want.count else { continue }
            let matches = zip(want, have).allSatisfy { segment, actual in
                segment == "*" ? !actual.isEmpty : segment == actual
            }
            if matches { return true }
        }
        return false
    }

    static func mask(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.append(scalar)
            } else {
                out.append("█")
            }
        }
        return String(out)
    }
}
