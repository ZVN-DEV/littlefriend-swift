import Foundation
import Security

/// A journey session, as `session.json` holds it. Times are epoch milliseconds on the SDK clock.
struct Session: Codable, Equatable, Sendable {
    static let idleMs: Int64 = 30 * 60 * 1000
    static let maxMs: Int64 = 24 * 60 * 60 * 1000

    var id: String
    var start: Int64
    /// The last screen, track or background of the session.
    var last: Int64
    /// The sequence number of the session's last event; its first event carries 1.
    var seq: Int
    /// The session's first screen has been sent.
    var entered: Bool

    /// Less than 30 minutes since its last activity and less than 24 hours since it started. A clock
    /// that moved back past its start ends it, so no duration is ever negative.
    func isLive(at t: Int64) -> Bool {
        t >= start && t - last < Self.idleMs && t - start < Self.maxMs
    }

    /// SESSION_ID_RE `^[A-Za-z0-9_-]{16,32}$`, times in order and a sequence number that is not negative.
    var isWellFormed: Bool {
        let u = Array(id.utf16)
        return (16...32).contains(u.count)
            && u.allSatisfy { Text.isAlnum($0) || $0 == 0x5F || $0 == 0x2D }
            && start <= last
            && seq >= 0
    }
}

/// `session.json` inside the SDK directory: written atomically on every change, excluded from
/// backup, deleted when it cannot be read. Used on the tracker's queue only.
final class SessionStore {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".unicodeScalars)
    static let idLength = 20

    let fileURL: URL
    private let directory: URL
    private let encoder = JSONEncoder()

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("session.json")
    }

    /// The stored session, or nil. A file that does not decode to a well-formed session is deleted.
    func load() -> Session? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        if let data = try? Data(contentsOf: fileURL),
           let session = try? JSONDecoder().decode(Session.self, from: data),
           session.isWellFormed {
            return session
        }
        Log.warn("the session file could not be read and was deleted")
        delete()
        return nil
    }

    func save(_ session: Session) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
            try encoder.encode(session).write(to: fileURL, options: .atomic)
            // An atomic write replaces the file, so its backup exclusion is set again.
            excludeFromBackup(fileURL)
        } catch {
            Log.warn("the session file could not be written")
        }
    }

    func delete() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Log.warn("the session file could not be deleted")
        }
    }

    /// 20 random base-32 characters (100 bits), as lf.js makes them.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: idLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = generator.next() }
        }
        var id = String.UnicodeScalarView()
        for byte in bytes { id.append(alphabet[Int(byte & 31)]) }
        return String(id)
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
