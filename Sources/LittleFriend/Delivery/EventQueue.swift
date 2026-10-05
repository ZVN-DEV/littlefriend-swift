import Foundation

/// An event waiting in the file queue, with the mode, session and test flag its batch must carry.
/// A queue line is {"event", "mode", "session"?, "test"}; a line without "test" is real traffic.
struct QueuedEvent: JSONWritable, Sendable, Equatable {
    var event: WireEvent
    /// "a" (aggregate) or "j" (journey).
    var mode: String
    /// The journey session id; always nil in aggregate mode.
    var session: String?
    /// Test traffic: its batch carries `d: 1`, whatever the process sending it was started with.
    var test = false

    func write(to json: inout JSONWriter) {
        json.beginObject()
        json.field("event", event)
        json.field("mode", mode)
        json.field("session", session)
        json.key("test")
        json.bool(test)
        json.endObject()
    }
}

extension QueuedEvent {
    /// A queue line, or nil when it is not one.
    init?(json data: Data) {
        guard let f = JSON.object(data),
              let event = f["event"].flatMap(WireEvent.init(json:)),
              let mode = f["mode"].flatMap(JSON.string),
              let session = JSON.optional(f["session"], JSON.string),
              let test = JSON.optional(f["test"], JSON.bool)
        else { return nil }
        self.init(event: event, mode: mode, session: session, test: test ?? false)
    }
}

/// The unsent events, in memory and in `queue.jsonl` inside `directory`, one QueuedEvent per line.
/// The directory and the file are excluded from backup. An append writes one line; a removal or a
/// clear rewrites the file. At most `capacity` events are kept, dropping the oldest.
final class EventQueue: @unchecked Sendable {
    static let capacity = 1000
    /// The collector refuses events older than 24 hours; an hour is left for the send.
    static let maxAgeMs: Int64 = 23 * 60 * 60 * 1000
    /// The collector refuses events more than 10 minutes ahead of its clock.
    static let maxAheadMs: Int64 = 10 * 60 * 1000

    let fileURL: URL
    private let directory: URL
    private let clock: Clock
    private let serial = DispatchQueue(label: "io.littlefriend.queue")
    private var entries: [Entry] = []
    /// False when the directory or the file could not be read: a file this process cannot see is
    /// never overwritten, and events are kept in memory only.
    private var onDisk = true

    private struct Entry {
        let queued: QueuedEvent
        /// The encoded QueuedEvent, without its newline.
        let line: Data
        /// The encoded WireEvent's length, as it appears in a batch body.
        let size: Int
    }

    init(directory: URL, clock: Clock) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("queue.jsonl")
        self.clock = clock
        serial.sync { load() }
    }

    var count: Int { serial.sync { entries.count } }

    func append(_ event: QueuedEvent) {
        serial.sync {
            let entry: Entry
            switch makeEntry(event) {
            case let .success(made):
                entry = made
            case .failure(.unknownMode):
                Log.warn("an event was not queued: its mode is neither aggregate nor journey")
                return
            case .failure(.unencodable):
                Log.warn("an event was not queued: it could not be encoded")
                return
            }
            entries.append(entry)
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
                rewrite()
            } else {
                appendLine(entry.line)
            }
        }
    }

    /// The oldest events that share the first event's mode, session and test flag, in order: at most
    /// `maxEvents`, and stopping before the event that would push the body past `maxBytes`. `overhead`
    /// gives the body's size with no events for the first event's batch. A batch always holds at
    /// least one event.
    func peekBatch(
        maxEvents: Int,
        maxBytes: Int,
        overhead: (_ first: QueuedEvent) -> Int = { _ in 0 }
    ) -> [QueuedEvent] {
        serial.sync {
            guard let first = entries.first?.queued else { return [] }
            var total = overhead(first)
            var batch: [QueuedEvent] = []
            for entry in entries {
                let next = entry.queued
                guard batch.count < maxEvents, next.mode == first.mode, next.session == first.session,
                      next.test == first.test
                else { break }
                // Events after the first are joined with a comma.
                let added = entry.size + (batch.isEmpty ? 0 : 1)
                if !batch.isEmpty && total + added > maxBytes { break }
                total += added
                batch.append(entry.queued)
            }
            return batch
        }
    }

    /// Removes the events the collector would refuse as clock skew by this queue's clock, with one
    /// rewrite, and returns how many were removed.
    func removeOutsideWindow() -> Int {
        serial.sync {
            let now = clock.nowMs()
            let before = entries.count
            entries.removeAll { !Self.inWindow($0.queued.event.t, now: now) }
            let removed = before - entries.count
            if removed > 0 { rewrite() }
            return removed
        }
    }

    /// Not older than 23 hours and not more than 10 minutes ahead of `now`.
    static func inWindow(_ t: Int64, now: Int64) -> Bool {
        t >= now - maxAgeMs && t <= now + maxAheadMs
    }

    func remove(ids: Set<String>) {
        serial.sync {
            let before = entries.count
            entries.removeAll { ids.contains($0.queued.event.i) }
            if entries.count != before { rewrite() }
        }
    }

    /// Empties memory and deletes the file, even one this process could not read.
    func clear() {
        serial.sync {
            entries.removeAll()
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                Log.warn("the event queue file could not be deleted")
            }
        }
    }

    // MARK: Serial queue only

    private enum EntryError: Error {
        /// A mode other than "a" or "j".
        case unknownMode
        /// A number that is not finite: JSON has none.
        case unencodable
    }

    /// An aggregate event never keeps a session.
    private func makeEntry(_ event: QueuedEvent) -> Result<Entry, EntryError> {
        var queued = event
        switch queued.mode {
        case "a": queued.session = nil
        case "j": break
        default: return .failure(.unknownMode)
        }
        guard let line = queued.json(), let size = queued.event.json()?.count else {
            return .failure(.unencodable)
        }
        return .success(Entry(queued: queued, line: line, size: size))
    }

    /// Drops lines that do not decode and events the collector would refuse by age; rewrites the
    /// file when anything was dropped or the last line was cut short.
    private func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
        } catch {
            onDisk = false
            Log.warn("the event queue directory could not be created; events are kept in memory only")
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            onDisk = false
            Log.warn("the event queue file could not be read; events are kept in memory only")
            return
        }
        let now = clock.nowMs()
        var dirty = !data.isEmpty && data.last != 0x0A
        for line in data.split(separator: 0x0A) {
            guard let decoded = QueuedEvent(json: Data(line)),
                  case let .success(entry) = makeEntry(decoded),
                  Self.inWindow(entry.queued.event.t, now: now)
            else {
                dirty = true
                continue
            }
            if entry.queued != decoded { dirty = true }
            entries.append(entry)
        }
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
            dirty = true
        }
        if dirty { rewrite() }
    }

    private func appendLine(_ line: Data) {
        guard onDisk else { return }
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                excludeFromBackup(fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([0x0A]))
        } catch {
            // A failed append may leave part of a line; a full rewrite puts the file back in order.
            rewrite()
        }
    }

    private func rewrite() {
        guard onDisk else { return }
        do {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return
            }
            var data = Data(capacity: entries.reduce(0) { $0 + $1.line.count + 1 })
            for entry in entries {
                data.append(entry.line)
                data.append(0x0A)
            }
            try data.write(to: fileURL, options: .atomic)
            // An atomic write replaces the file, so its backup exclusion is set again.
            excludeFromBackup(fileURL)
        } catch {
            Log.warn("the event queue file could not be written")
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
