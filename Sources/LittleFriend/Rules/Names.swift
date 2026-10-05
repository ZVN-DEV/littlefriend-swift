import Foundation

/// Custom event names, mirroring EVENT_NAME_RE in packages/contract/src/limits.ts:
/// `^[a-z][a-z0-9_.:-]{0,63}$`. Reserved `$` names are the SDK's own and never valid here.
enum Names {
    static func valid(_ name: String) -> Bool {
        let u = Array(name.utf16)
        guard let first = u.first, u.count <= 64, Text.isLower(first) else { return false }
        return u.dropFirst().allSatisfy {
            Text.isLower($0) || Text.isDigit($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A || $0 == 0x2D
        }
    }

    /// PAGE_TYPE_KEY_RE in packages/contract/src/page-types.ts: `^[a-z][a-z0-9_-]{0,31}$`.
    static func validPageType(_ type: String) -> Bool {
        let u = Array(type.utf16)
        guard let first = u.first, u.count <= 32, Text.isLower(first) else { return false }
        return u.dropFirst().allSatisfy { Text.isLower($0) || Text.isDigit($0) || $0 == 0x5F || $0 == 0x2D }
    }

    /// cleanCorrelationId in packages/contract/src/validate.ts: CORRELATION_ID_RE
    /// `^(?![\d-]+$)[A-Za-z0-9_-]{16,64}$`, and not personal data.
    static func validCorrelationId(_ id: String) -> Bool {
        let u = Array(id.utf16)
        guard (16...64).contains(u.count),
              u.allSatisfy({ Text.isAlnum($0) || $0 == 0x5F || $0 == 0x2D }),
              u.contains(where: { !Text.isDigit($0) && $0 != 0x2D })
        else { return false }
        return !Text.looksLikePII(id)
    }
}
