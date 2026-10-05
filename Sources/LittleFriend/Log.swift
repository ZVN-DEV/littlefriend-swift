import Foundation
import os

/// One line per notable SDK decision. A line names counts, statuses and rules, never event content.
/// Written with os_log and a C format string: Logger's interpolation adds an `__oslogstring` section,
/// which the linker aligns to a whole page in an app that has none.
enum Log {
    private static let log = OSLog(subsystem: "io.littlefriend", category: "sdk")
    static let observers = LogObservers()

    /// One copy, called from every site.
    @inline(never)
    static func warn(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message as NSString)
        observers.notify(message)
    }
}

/// Lets tests read the lines the SDK logs.
final class LogObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (String) -> Void] = [:]

    func add(_ observer: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    func notify(_ message: String) {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observer in current { observer(message) }
    }
}
