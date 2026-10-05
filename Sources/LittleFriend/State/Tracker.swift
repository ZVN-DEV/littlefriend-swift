import Foundation

/// The engine: visits, journey sessions, landing source, engagement, consent and opt-out. Every
/// method other than `optOut()` dispatches onto one private serial queue and returns at once;
/// `optOut()` also stops the batcher before it returns, so nothing is sent after it.
///
/// Storage, all in `storage` (Application Support/littlefriend, excluded from backup): the event
/// queue, `session.json` in journey mode only, and the empty `opt-out` flag file.
final class Tracker: @unchecked Sendable {
    /// The same route again within this long is the same screen.
    static let dedupeMs: Int64 = 1000
    /// The test clock offset may move the clock back at most this far.
    static let maxClockOffset: TimeInterval = 23 * 60 * 60

    private let options: LittleFriend.Options
    private let key: String
    private let app: AppInfo
    private let sdk: String
    private let test: Bool
    private let storage: URL
    /// The only clock the engine, the queue and the session math read: the test offset applied.
    private let clock: Clock
    private let offset: TimeInterval
    private let transport: Transport
    private let scheduler: Scheduler
    private let serial = DispatchQueue(label: "io.littlefriend.tracker")
    private let sessions: SessionStore

    /// Guards `liveBatcher` and `optOutCalls`, which `optOut()` changes before it returns.
    private let lock = NSLock()
    private var liveBatcher: Batcher?
    private var optOutCalls = 0

    // Read and written on `serial` only.
    private var queue: EventQueue?
    private var optedOut = false
    private var journey: Bool
    private var session: Session?
    private var visit: Visit?
    private var engagement = Engagement()
    /// The screen on display: tracks are recorded under its route.
    private var route: String?
    /// The page type the screen on display was sent with.
    private var routeType: String?
    private var lastScreenAt: Int64?
    private var active = true
    private var backgroundAt: Int64?
    /// A deep link campaign waiting for the visit it opens.
    private var pendingSource: Campaign?

    /// `test` is the resolved test traffic flag: `testClockOffset` applies only when it is true.
    init(
        options: LittleFriend.Options, key: String, app: AppInfo, sdk: String, test: Bool, storage: URL,
        clock: Clock, transport: Transport, scheduler: Scheduler
    ) {
        self.options = options
        self.key = key
        self.app = app
        self.sdk = sdk
        self.test = test
        self.storage = storage
        self.transport = transport
        self.scheduler = scheduler
        let offset = Self.clockOffset(options.testClockOffset, test: test)
        self.offset = offset
        self.clock = offset == 0 ? clock : OffsetClock(base: clock, offset: offset)
        journey = options.mode == .journey && options.consent != .required
        sessions = SessionStore(directory: storage)
        serial.async { self.setUp() }
    }

    /// The offset to apply: negative, at most 23 hours, test traffic only; anything else is 0.
    static func clockOffset(_ requested: TimeInterval, test: Bool) -> TimeInterval {
        if requested == 0 { return 0 }
        guard test else {
            Log.warn("testClockOffset is ignored: it applies to test traffic only")
            return 0
        }
        guard requested.isFinite, requested < 0, requested >= -maxClockOffset else {
            Log.warn("testClockOffset is ignored: it must be negative and at most 23 hours")
            return 0
        }
        return requested
    }

    // MARK: Calls

    /// The app became active at `date` (wall clock). `coldLaunch` marks the first activation of
    /// the process; a visit an earlier call already started in this process is kept.
    func foreground(at date: Date, coldLaunch: Bool) {
        serial.async { self.enterForeground(at: self.time(date), coldLaunch: coldLaunch) }
    }

    /// The app went to the background at `date` (wall clock): the screen is closed and the queue sent.
    func background(at date: Date) {
        serial.async { self.enterBackground(at: self.time(date)) }
    }

    /// A deep link. Its UTM tags are the source of the visit it opens; a link without any is ignored.
    func handle(url: URL) {
        serial.async { self.openLink(url) }
    }

    func screen(_ route: String, type: String?) {
        serial.async { self.showScreen(route, type: type) }
    }

    func track(_ name: String, props: [String: PropValue], correlationId: String?) {
        serial.async { self.trackEvent(name, props: props, correlationId: correlationId) }
    }

    func consent(_ consent: LittleFriend.Consent) {
        serial.async { self.applyConsent(consent) }
    }

    func optOut() {
        lock.lock()
        optOutCalls += 1
        let batcher = liveBatcher
        liveBatcher = nil
        lock.unlock()
        batcher?.stop()
        serial.async { self.applyOptOut() }
    }

    func optIn() {
        lock.lock()
        let generation = optOutCalls
        lock.unlock()
        serial.async { self.applyOptIn(generation: generation) }
    }

    /// Returns once every earlier call has run and the queue is sent, or a batch has failed its retries.
    func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            serial.async { done.resume() }
        }
        await currentBatcher()?.flushNow()
    }

    /// Blocks until every earlier call has run.
    func drain() {
        serial.sync {}
    }

    // MARK: On `serial` only

    private var optOutFile: URL { storage.appendingPathComponent("opt-out") }

    private func now() -> Int64 { clock.nowMs() }

    private func time(_ date: Date) -> Int64 { date.addingTimeInterval(offset).epochMs }

    private func setUp() {
        let queue = EventQueue(directory: storage, clock: clock)
        self.queue = queue
        if FileManager.default.fileExists(atPath: optOutFile.path) {
            optedOut = true
            queue.clear()
            sessions.delete()
            return
        }
        _ = startBatcher(generation: 0)
        if journey {
            session = sessions.load()
        } else {
            // The file exists only in journey mode. Waiting for consent keeps a live session in
            // memory, for consent(.journey) to continue.
            if options.mode == .journey {
                session = sessions.load().flatMap { $0.isLive(at: now()) ? $0 : nil }
            }
            sessions.delete()
        }
    }

    /// Publishes a new batcher unless `optOut()` was called since `generation` was read.
    private func startBatcher(generation: Int) -> Bool {
        guard let queue else { return false }
        let batcher = Batcher(
            queue: queue, transport: transport, key: key, app: app, sdk: sdk, test: test, scheduler: scheduler
        )
        lock.lock()
        let current = optOutCalls == generation
        if current { liveBatcher = batcher }
        lock.unlock()
        if !current { batcher.stop() }
        return current
    }

    private func currentBatcher() -> Batcher? {
        lock.lock()
        defer { lock.unlock() }
        return liveBatcher
    }

    private func enterForeground(at t: Int64, coldLaunch: Bool) {
        guard !optedOut else { return }
        if visit == nil {
            active = true
            startColdVisit(at: t)
        } else if !active {
            active = true
            let away = backgroundAt.map { t - $0 } ?? 0
            if pendingSource != nil || away >= Visit.backgroundGapMs {
                startVisit(at: t, source: pendingSource)
                landOnShownScreen(at: t)
            } else {
                engagement.resume(at: t)
            }
        }
        backgroundAt = nil
    }

    private func enterBackground(at t: Int64) {
        guard !optedOut, active else { return }
        closeScreen(at: t)
        active = false
        backgroundAt = t
        // Foreground time is activity: a live session's last activity is the moment the app left.
        if journey, var live = session, live.isLive(at: t) {
            live.last = t
            session = live
            sessions.save(live)
        }
        if let batcher = currentBatcher() {
            Task { await batcher.flushNow() }
        }
    }

    private func openLink(_ url: URL) {
        guard !optedOut,
              let campaign = CampaignRules.fromURL(url.absoluteString, extended: options.utmExtended)
        else { return }
        if active, visit != nil {
            let t = now()
            closeScreen(at: t)
            startVisit(at: t, source: campaign)
            landOnShownScreen(at: t)
        } else {
            pendingSource = campaign
        }
    }

    private func showScreen(_ raw: String, type: String?) {
        guard !optedOut else { return }
        guard let clean = Routes.clean(raw) else {
            Log.warn("a screen was dropped: its route is over 2048 characters, or over 256 once cleaned")
            return
        }
        let t = now()
        if clean == route, let last = lastScreenAt, t - last < Self.dedupeMs { return }
        ensureVisit(at: t)
        closeScreen(at: t)
        var pageType: String?
        if let type {
            if Names.validPageType(type) {
                pageType = type
            } else {
                Log.warn("a screen type was left out: it does not match ^[a-z][a-z0-9_-]{0,31}$")
            }
        }
        sendView(clean, pageType: pageType, at: t)
    }

    /// A visit that starts while a screen is on display gets no appear callback for it, so that
    /// screen's view goes out at once as the visit's landing, with the type it was sent with, and
    /// its count starts again from `t`.
    private func landOnShownScreen(at t: Int64) {
        guard let shown = route else { return }
        sendView(shown, pageType: routeType, at: t)
    }

    /// `$pageview` for a cleaned route and a valid page type; the visit's landing when one is due.
    private func sendView(_ clean: String, pageType: String?, at t: Int64) {
        guard var current = visit else { return }
        let landing = current.landingPending
        current.landingPending = false
        visit = current
        emit(
            "$pageview", route: clean, at: t, props: pageType.map { ["page_type": .string($0)] }, landing: landing,
            source: landing ? current.source : nil, screen: true
        )
        route = clean
        routeType = pageType
        lastScreenAt = t
        engagement.open(clean, at: t, counting: active)
    }

    private func trackEvent(_ name: String, props: [String: PropValue], correlationId: String?) {
        guard !optedOut else { return }
        guard Names.valid(name) else {
            Log.warn("an event was dropped: its name does not match ^[a-z][a-z0-9_.:-]{0,63}$")
            return
        }
        let t = now()
        ensureVisit(at: t)
        var x: String?
        if journey, let id = correlationId {
            if Names.validCorrelationId(id) {
                x = id
            } else {
                Log.warn("a correlation id was left out: it fails CORRELATION_ID_RE or looks like personal data")
            }
        }
        // Aggregate mode: every track of the visit says it entered from outside (`l: 1`), with the
        // landing's source when the visit has one. A direct visit sends `l` alone.
        emit(
            name, route: route ?? "/", at: t, props: Props.clean(props), landing: !journey,
            source: journey ? nil : visit?.source, correlationId: x
        )
    }

    /// The screen open at a switch of mode is closed in the mode it was counted in, and counts on in
    /// the new one. A switch to journey continues the visit, and the session held in memory when it
    /// is still live; otherwise a new session starts with the next event. When the visit's landing
    /// already went out in aggregate mode, that landing was the entry, so no journey screen of this
    /// visit carries `l`. consent(.none) and consent(.required) always drop the session and delete
    /// the file, even when the mode is already aggregate.
    private func applyConsent(_ consent: LittleFriend.Consent) {
        if consent == .journey && options.mode != .journey {
            Log.warn("consent(.journey) is ignored: the mode option is aggregate")
            return
        }
        let t = now()
        if consent == .journey {
            guard !journey else { return }
            if !optedOut { closeScreen(at: t) }
            journey = true
            if let held = session, !held.isLive(at: t) { session = nil }
            if let live = session {
                sessions.save(live)
                if var current = visit, current.landingPending {
                    // Before the landing a live session continues as it would have at launch.
                    current.landingPending = !live.entered
                    visit = current
                }
            }
        } else {
            if journey {
                if !optedOut { closeScreen(at: t) }
                journey = false
            }
            session = nil
            sessions.delete()
        }
        if active { engagement.resume(at: t) }
    }

    private func applyOptOut() {
        optedOut = true
        queue?.clear()
        sessions.delete()
        session = nil
        visit = nil
        engagement.clear()
        route = nil
        routeType = nil
        lastScreenAt = nil
        backgroundAt = nil
        pendingSource = nil
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: optOutFile.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var url = optOutFile
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            Log.warn("the opt-out choice could not be saved")
        }
    }

    private func applyOptIn(generation: Int) {
        guard optedOut else { return }
        lock.lock()
        let current = optOutCalls == generation
        lock.unlock()
        // A later optOut() supersedes this call.
        guard current else { return }
        do {
            if FileManager.default.fileExists(atPath: optOutFile.path) {
                try FileManager.default.removeItem(at: optOutFile)
            }
        } catch {
            Log.warn("the opt-out flag could not be removed")
        }
        optedOut = false
        // The next foreground or screen starts a new visit, and in journey mode a new session.
        _ = startBatcher(generation: generation)
    }

    private func ensureVisit(at t: Int64) {
        if visit == nil { startColdVisit(at: t) }
    }

    /// A cold launch is a new visit unless, in journey mode with no deep link, a live session
    /// continues: then its landing is still due only when the session's first screen was never sent.
    private func startColdVisit(at t: Int64) {
        if journey, pendingSource == nil, let live = session, live.isLive(at: t) {
            visit = Visit(source: nil, landingPending: !live.entered)
            engagement.clear()
            lastScreenAt = nil
        } else {
            startVisit(at: t, source: pendingSource)
        }
    }

    /// The next screen is the landing. Nothing counts toward `$engage` until it. A visit with a
    /// source ends the session, so its landing is the entry of a new one; without a source a live
    /// session goes on.
    private func startVisit(at t: Int64, source: Campaign?) {
        visit = Visit(source: source, landingPending: true)
        pendingSource = nil
        engagement.clear()
        lastScreenAt = nil
        if source != nil {
            session = nil
        } else if let current = session, !current.isLive(at: t) {
            session = nil
        }
    }

    /// Sends `$engage` for the open screen when it counted at least a second. `sum` is the screen's
    /// running total, this event included.
    private func closeScreen(at t: Int64) {
        guard let open = engagement.route, visit != nil else { return }
        let ms = engagement.take(at: t)
        guard ms > 0 else { return }
        emit(
            "$engage", route: open, at: t,
            props: ["ms": .number(Double(ms)), "sum": .number(Double(engagement.emitted))], past: true
        )
    }

    /// Queues one event. In journey mode it takes the session's next sequence number; `past` events
    /// (`$engage`) describe earlier activity, so they neither roll the session nor refresh it.
    private func emit(
        _ name: String, route: String, at t: Int64, props: [String: PropValue]? = nil, landing: Bool = false,
        source: Campaign? = nil, correlationId: String? = nil, past: Bool = false, screen: Bool = false
    ) {
        var event = WireEvent(i: WireEvent.newID(), n: name, t: t, q: 0, u: route, c: source, p: props, l: landing ? 1 : nil)
        let queued: QueuedEvent
        if journey {
            var current = session.flatMap { past || $0.isLive(at: t) ? $0 : nil }
                ?? Session(id: SessionStore.newID(), start: t, last: t, seq: 0, entered: false)
            current.seq += 1
            if !past { current.last = t }
            if screen { current.entered = true }
            session = current
            sessions.save(current)
            event.q = current.seq
            event.x = correlationId
            queued = QueuedEvent(event: event, mode: "j", session: current.id)
        } else {
            queued = QueuedEvent(event: event, mode: "a", session: nil)
        }
        currentBatcher()?.enqueue(queued)
    }
}
