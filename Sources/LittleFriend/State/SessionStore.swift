import Foundation
import Security

/// A journey session, as `session.json` holds it. Times are epoch milliseconds on the SDK clock.
struct Session: JSONWritable, Equatable, Sendable {
    static let idleMs: Int64 = 30 * 60 * 1000
    static let maxMs: Int64 = 24 * 60 * 60 * 1000
    /// The largest integer a JSON number holds exactly: the latest `start` and `last` a file may hold.
    static let maxTime: Int64 = 9_007_199_254_740_991
    /// The largest `seq` a file may hold, so the next event's cannot overflow.
    static let maxSeq = 1_000_000_000

    var id: String
    var start: Int64
    /// The last screen, track or background of the session.
    var last: Int64
    /// The sequence number of the session's last event; its first event carries 1.
    var seq: Int
    /// The session's first screen has been sent.
    var entered: Bool

    /// Less than 30 minutes since its last activity and less than 24 hours since it started. A clock
    /// that moved back past its start ends it, so no duration is ever negative. With `start` and
    /// `last` in 0...maxTime, as a loaded file's are, and a clock in the same range, neither
    /// subtraction can overflow: `t >= start` is checked first.
    func isLive(at t: Int64) -> Bool {
        t >= start && t - last < Self.idleMs && t - start < Self.maxMs
    }

    func write(to json: inout JSONWriter) {
        json.beginObject()
        json.field("id", id)
        json.field("start", start)
        json.field("last", last)
        json.field("seq", seq)
        json.key("entered")
        json.bool(entered)
        json.endObject()
    }

    /// SESSION_ID_RE `^[A-Za-z0-9_-]{16,32}$`, 0 <= start <= last <= maxTime and 0 <= seq <= maxSeq.
    var isWellFormed: Bool {
        let u = Array(id.utf16)
        return (16...32).contains(u.count)
            && u.allSatisfy { Text.isAlnum($0) || $0 == 0x5F || $0 == 0x2D }
            && 0 <= start && start <= last && last <= Self.maxTime
            && (0...Self.maxSeq).contains(seq)
    }
}

extension Session {
    /// The file's object, or nil when a field is missing or has the wrong type.
    init?(json data: Data) {
        guard let f = JSON.object(data),
              let id = f["id"].flatMap(JSON.string), let start = f["start"].flatMap(JSON.int64),
              let last = f["last"].flatMap(JSON.int64), let seq = f["seq"].flatMap(JSON.int),
              let entered = f["entered"].flatMap(JSON.bool)
        else { return nil }
        self.init(id: id, start: start, last: last, seq: seq, entered: entered)
    }
}

/// `session.json` inside the SDK directory: written atomically on every change, excluded from
/// backup. A file that was read but does not decode is deleted; one that could not be read is kept
/// and never written over for the rest of the process. Used on the tracker's queue only.
final class SessionStore {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".unicodeScalars)
    static let idLength = 20

    let fileURL: URL
    private let directory: URL
    /// False after a read error, until the file is deleted: saves skip a file this process cannot see.
    private var onDisk = true

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("session.json")
    }

    /// The stored session, or nil.
    func load() -> Session? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            onDisk = false
            Log.warn("the session file could not be read; this launch starts without it")
            return nil
        }
        if let session = Session(json: data), session.isWellFormed {
            return session
        }
        Log.warn("the session file could not be decoded and was deleted")
        delete()
        return nil
    }

    func save(_ session: Session) {
        guard onDisk else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
            guard let data = session.json() else { return }
            try data.write(to: fileURL, options: .atomic)
            // An atomic write replaces the file, so its backup exclusion is set again.
            excludeFromBackup(fileURL)
        } catch {
            Log.warn("the session file could not be written")
        }
    }

    /// Deletes the file, even one this process could not read.
    func delete() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            onDisk = true
            return
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            onDisk = true
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
