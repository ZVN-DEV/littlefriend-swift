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
}
