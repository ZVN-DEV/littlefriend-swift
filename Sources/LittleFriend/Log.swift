import Foundation
import os

/// One line per notable SDK decision. A line names counts, statuses and rules, never event content.
enum Log {
    private static let logger = Logger(subsystem: "io.littlefriend", category: "sdk")
    static let observers = LogObservers()

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
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
