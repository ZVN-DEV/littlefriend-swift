import Foundation
import Security

enum ReplayID {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".unicodeScalars)

    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = generator.next() }
        }
        var id = String.UnicodeScalarView()
        for byte in bytes { id.append(alphabet[Int(byte & 31)]) }
        return String(id)
    }
}
