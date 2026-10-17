@_spi(LittleFriendReplay) import LittleFriend
import Foundation

private struct ReplayPage {
    let sessionID: String
    let id: String
    let route: String
    var nextSequence = 0
    var ready = false
    var events: [ReplayEvent] = []
    var bytes = 0
}

/// Owns eligibility and page state. Every stop path invalidates asynchronous work before clearing it.
final class ReplayCoordinator: @unchecked Sendable {
    static let flushDelay: TimeInterval = 10
    static let flushBytes = 128 * 1024

    private let capture: ReplayCaptureDriver
    private let transportFactory: @Sendable (ReplayBridgeConfiguration) -> ReplayTransport
    private let lock = NSRecursiveLock()
    private var core: ReplayBridgeConfiguration?
    private var transport: ReplayTransport?
    private var sender: ReplayChunkSender?
    private var config: ReplayClientConfig?
    private var configTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var generation = 0
    private var permanentlyStopped = false
    private var optedOut = false
    private var disabled = false
    private var foreground = true
    private var latestState: ReplayBridgeState?
    private var pendingAppearance: ReplayBridgeState?
    private var currentSessionID: String?
    private var page: ReplayPage?
    private var hitTargets: [ReplayHitTarget] = []

    init(
        capture: ReplayCaptureDriver,
        transportFactory: @escaping @Sendable (ReplayBridgeConfiguration) -> ReplayTransport
    ) {
        self.capture = capture
        self.transportFactory = transportFactory
    }

    func handle(_ event: ReplayBridgeEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .configuration(configuration):
            guard core == nil else { return }
            core = configuration
            let transport = transportFactory(configuration)
            self.transport = transport
            sender = ReplayChunkSender(transport: transport, onTerminal: { [weak self] status in
                self?.terminal(status)
            })
        case let .screen(state):
            latestState = state
            foreground = state.foreground
            reconcileSession(state)
            pendingAppearance = state
            prepareAppearance()
        case let .session(state):
            latestState = state
            reconcileSession(state)
        case let .foreground(state):
            latestState = state
            foreground = true
            sender?.poke()
            if page == nil, state.sessionID != nil, state.route != nil {
                pendingAppearance = state
            }
            prepareAppearance()
        case let .background(state):
            latestState = state
            foreground = false
            flushTask?.cancel()
            flushTask = nil
            sealBuffer()
            sender?.poke()
        case let .consent(state):
            latestState = state
            foreground = state.foreground
            reconcileSession(state)
            if state.journey, state.sessionID != nil {
                if page == nil { pendingAppearance = state }
                prepareAppearance()
            }
        case let .optIn(state):
            latestState = state
            optedOut = false
            foreground = state.foreground
            currentSessionID = nil
            config = nil
            // A fresh sender: a terminal response or a replay-off config stops the old one for
            // good, and a new opt-in must be able to record again if the config allows it.
            disabled = false
            if let transport {
                sender = ReplayChunkSender(transport: transport, onTerminal: { [weak self] status in
                    self?.terminal(status)
                })
            }
        case .optOut:
            optOut()
        }
    }

    /// A tap in window points. The node is the deepest serialized target under the point, so a
    /// tap can never be attributed to a node it did not land on.
    func recordTapAt(x: Double, y: Double) {
        lock.lock()
        let target = hitTargets.last(where: { $0.contains(x: x, y: y) })
        lock.unlock()
        guard let target else { return }
        recordTap(ReplayNativeTap(x: x, y: y, nodeID: target.nodeID))
    }

    func recordTap(_ tap: ReplayNativeTap) {
        lock.lock()
        defer { lock.unlock() }
        guard !permanentlyStopped, !optedOut, !disabled, foreground,
              var current = page, current.ready, core != nil,
              hitTargets.contains(where: { $0.nodeID == tap.nodeID && $0.contains(x: tap.x, y: tap.y) })
        else { return }
        let timestamp = core?.timestamp() ?? Int64(Date().timeIntervalSince1970 * 1000)
        for event in ReplayEvent.taps(at: timestamp, x: tap.x, y: tap.y, id: tap.nodeID) {
            do {
                current.bytes += try ReplayWire.encoded(event).count + 1
                current.events.append(event)
            } catch {
                disable()
                return
            }
        }
        page = current
        if current.events.count >= 5000 || current.bytes >= Self.flushBytes {
            sealBuffer()
        } else {
            scheduleFlush()
        }
    }

    func flush() {
        lock.lock()
        sealBuffer()
        sender?.poke()
        lock.unlock()
    }

    /// Immediate opt-out: callbacks already queued see a new generation and empty state.
    func optOut() {
        lock.lock()
        optedOut = true
        invalidate(discard: true)
        latestState = nil
        currentSessionID = nil
        config = nil
        lock.unlock()
    }

    func stop() {
        lock.lock()
        permanentlyStopped = true
        invalidate(discard: true)
        capture.detach()
        sender?.stopAndClear()
        latestState = nil
        currentSessionID = nil
        config = nil
        lock.unlock()
    }

    var isOptedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return optedOut
    }

    var pendingChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sender?.pendingCount ?? 0
    }

    var activePageID: String? {
        lock.lock()
        defer { lock.unlock() }
        return page?.id
    }

    private func prepareAppearance() {
        guard !permanentlyStopped, !optedOut, !disabled,
              let state = pendingAppearance, core != nil
        else { return }
        // A screen the config excludes ends the page in progress: nothing from that screen, taps
        // included, may be recorded, and the previous page seals under its own route.
        if let config, let route = state.route,
           !config.on || ReplayPolicy.excluded(route: route, patterns: config.exclude) {
            pendingAppearance = nil
            endPage(discard: false)
            return
        }
        guard eligible(state) else { return }
        if config == nil {
            loadConfig()
            return
        }
        beginIfSampled(state)
    }

    private func eligible(_ state: ReplayBridgeState) -> Bool {
        guard state.foreground, state.journey, let session = state.sessionID, let route = state.route else { return false }
        if session != currentSessionID { return false }
        if let config {
            guard config.on, !ReplayPolicy.excluded(route: route, patterns: config.exclude) else { return false }
        }
        return true
    }

    private func reconcileSession(_ state: ReplayBridgeState) {
        let next = state.journey ? state.sessionID : nil
        guard next != currentSessionID else { return }
        pendingAppearance = nil
        if let next {
            endPage(discard: false)
            currentSessionID = next
        } else {
            endPage(discard: true)
            currentSessionID = nil
        }
    }

    private func loadConfig() {
        guard configTask == nil, !permanentlyStopped, !optedOut, !disabled,
              let core, let transport
        else { return }
        let token = generation
        configTask = Task { [weak self] in
            let loaded = await transport.loadConfig(key: core.key, appID: core.app.i)
            self?.configLoaded(loaded, token: token)
        }
    }

    private func configLoaded(_ loaded: ReplayClientConfig?, token: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard token == generation, !permanentlyStopped, !optedOut, !disabled else { return }
        configTask = nil
        guard let loaded else { return }
        config = loaded
        guard loaded.on else {
            disable()
            return
        }
        prepareAppearance()
    }

    private func beginIfSampled(_ state: ReplayBridgeState) {
        guard let config, let session = state.sessionID, let route = state.route,
              !ReplayPolicy.excluded(route: route, patterns: config.exclude)
        else {
            pendingAppearance = nil
            endPage(discard: false)
            return
        }
        guard ReplayPolicy.sampled(sessionID: session, rate: config.rate) else {
            pendingAppearance = nil
            endPage(discard: false)
            return
        }
        pendingAppearance = nil
        endPage(discard: false)
        guard !disabled, !permanentlyStopped, !optedOut else { return }
        let id = ReplayID.make()
        page = ReplayPage(sessionID: session, id: id, route: route)
        hitTargets = []
        let token = generation
        capture.capture(route: route, timestamp: state.timestamp) { [weak self] snapshot in
            self?.snapshotCaptured(snapshot, pageID: id, token: token)
        }
    }

    private func snapshotCaptured(_ snapshot: ReplayCapturedSnapshot?, pageID: String, token: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard token == generation, !permanentlyStopped, !optedOut, !disabled,
              let core, var current = page, current.id == pageID, !current.ready,
              let snapshot, snapshot.events.count == 2,
              snapshot.events[0].isFullSnapshot == false, snapshot.events[1].isFullSnapshot,
              let state = latestState, eligible(state), state.sessionID == current.sessionID,
              state.route == current.route
        else { return }
        do {
            let chunk = try ReplayChunkFactory.make(
                core: core, sessionID: current.sessionID, pageID: current.id, sequence: 0,
                route: current.route, events: snapshot.events
            )
            guard sender?.enqueue(chunk) == true else {
                disable()
                return
            }
            current.nextSequence = 1
            current.ready = true
            page = current
            hitTargets = snapshot.hitTargets
        } catch {
            disable()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil, let current = page, current.ready, !current.events.isEmpty else { return }
        let token = generation
        let pageID = current.id
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushDelay * 1_000_000_000))
            self?.flushTimer(token: token, pageID: pageID)
        }
    }

    private func flushTimer(token: Int, pageID: String) {
        lock.lock()
        guard token == generation, page?.id == pageID else {
            lock.unlock()
            return
        }
        flushTask = nil
        sealBuffer()
        lock.unlock()
    }

    private func sealBuffer() {
        guard let core, var current = page, current.ready, !current.events.isEmpty else { return }
        flushTask?.cancel()
        flushTask = nil
        do {
            let chunk = try ReplayChunkFactory.make(
                core: core, sessionID: current.sessionID, pageID: current.id,
                sequence: current.nextSequence, route: current.route, events: current.events
            )
            guard sender?.enqueue(chunk) == true else {
                disable()
                return
            }
            current.nextSequence += 1
            current.events = []
            current.bytes = 0
            page = current
        } catch {
            disable()
        }
    }

    private func endPage(discard: Bool) {
        flushTask?.cancel()
        flushTask = nil
        if discard {
            sender?.discardPending()
        } else {
            sealBuffer()
            sender?.poke()
        }
        page = nil
        hitTargets = []
    }

    private func terminal(_ status: Int) {
        lock.lock()
        disable()
        lock.unlock()
    }

    private func disable() {
        disabled = true
        invalidate(discard: true)
        sender?.stopAndClear()
    }

    private func invalidate(discard: Bool) {
        generation += 1
        configTask?.cancel()
        configTask = nil
        pendingAppearance = nil
        endPage(discard: discard)
        capture.cancel()
    }
}
