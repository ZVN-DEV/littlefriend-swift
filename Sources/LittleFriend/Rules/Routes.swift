import Foundation

/// Route cleaning, mirroring sanitizeRoute in packages/contract/src/sanitize.ts.
///   /orders/8812/items?x=1#top  ->  /orders/:id/items
///   /u/jane@example.com         ->  /u/:redacted
///   Settings                    ->  /Settings
enum Routes {
    /// Longest raw path read before cleaning, in UTF-16 code units.
    static let maxRawPath = 2048
    /// Longest route kept, in UTF-16 code units.
    static let maxRoute = 256

    /// The route with no identifiers in it, or nil when it is too long to keep.
    static func clean(_ input: String) -> String? {
        if input.utf16.count > maxRawPath { return nil }
        var path = Text.cutQueryAndFragment(input)
        if path.unicodeScalars.first != "/" { path = "/" + path }
        // A path that fails to decode is kept raw; its segments are still checked.
        var decoded = Text.decodeURIComponent(path) ?? path
        decoded = Text.clean(decoded)
        // Cut again after decoding, so an encoded ? or # cannot carry a query or fragment into the route.
        decoded = Text.cutQueryAndFragment(decoded)
        let segments = decoded.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map {
            segment(String($0))
        }
        var out = segments.joined(separator: "/")
        if out.utf16.count > 1 && out.unicodeScalars.last == "/" {
            out = String(out.unicodeScalars.dropLast())
        }
        if out.utf16.count > maxRoute { return nil }
        return out
    }

    private static func segment(_ seg: String) -> String {
        // A path segment holding a value (a fragment pasted as a route, a sign-in token) is never a route.
        if seg.unicodeScalars.contains("=") { return ":redacted" }
        if seg.isEmpty || seg.unicodeScalars.first == ":" { return seg }
        let units = Array(seg.utf16)
        if Text.isNumeric(units) || Text.isUUID(units) || Text.isHexish(units) || Text.isTokenish(units) {
            return ":id"
        }
        if Text.looksLikePII(seg) { return ":redacted" }
        return seg
    }
}
