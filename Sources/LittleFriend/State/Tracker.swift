import Foundation

/// The engine: visits, journey sessions, landing source, engagement, consent and opt-out. Every
/// method other than `optOut()` dispatches onto one private serial queue and returns at once;
/// `optOut()` also stops the batcher, writes the opt-out flag and deletes the queue and session
/// files before it returns, so nothing is sent or kept after it, even by a later launch.
///
/// Every new visit opens a landing window: until it ends, the visit's landing is unresolved and its
/// screen, track and consent calls are held in order, with the time of each. The window ends at a
/// deep link with UTM tags, which becomes the visit's source, or 500 ms after the window's
/// foreground, or when the app leaves the foreground before that. The cold visit's window opens
/// when the tracker is created and its 500 ms run from the first foreground; a visit started by a
/// return after 30 minutes, or by a link, opens its window at that foreground or that link. At the
/// end the held calls replay in order: the first screen among them is the landing; with none, the
/// screen on display from before the visit is sent as the landing at the window's end.
///
/// A screen shown while the app is in the background becomes the screen on display and sends
/// nothing. At the next foreground it is sent, if it differs from the screen sent last in the
/// visit, at the foreground time, or through the window when that foreground starts a new visit.
///
/// Storage, all in `storage` (Application Support/littlefriend, excluded from backup): the event
/// queue, `session.json` in journey mode only, and the empty `opt-out` flag file.
final class Tracker: LifecycleTarget, @unchecked Sendable {
    /// The same route again within this long is the same screen.
    static let dedupeMs: Int64 = 1000
    /// How long a new visit waits for its deep link and its landing screen.
    static let landingWindowMs: Int64 = 500
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

    /// Guards `liveBatcher`, `liveQueue`, `optOutCalls`, `filesStopped`, the opt-out flag file and
    /// the session file, which `optOut()` changes before it returns.
    private let lock = NSLock()
    private var liveBatcher: Batcher?
    private var liveQueue: EventQueue?
    private var optOutCalls = 0
    /// True from `optOut()` until the `optIn()` that follows it: the session file is not written.
    private var filesStopped = false

    // Read and written on `serial` only.
    private var queue: EventQueue?
    private var optedOut = false
    private var journey: Bool
    private var session: Session?
    /// Nil only while the cold visit's landing window is open, and while opted out.
    private var visit: Visit?
    /// Open while a new visit's landing is unresolved.
    private var window: LandingWindow?
    private var windowsOpened = 0
    private var engagement = Engagement()
    /// The screen on display: tracks are recorded under its route.
    private var route: String?
    /// The page type the screen on display was sent with.
    private var routeType: String?
    /// The route of this visit's latest `$pageview`; nil until the visit sends one.
    private var sentRoute: String?
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
    /// `date` (wall clock) is the time of the call when it was made earlier, before `start`; nil reads
    /// the clock when the call runs. The same holds for `screen`, `track` and `consent`.
    func handle(url: URL, at date: Date? = nil) {
        serial.async { self.openLink(url, at: date.map(self.time)) }
    }

    func screen(_ route: String, type: String?, at date: Date? = nil) {
        serial.async { self.screenCall(route, type: type, at: date.map(self.time)) }
    }

    func track(_ name: String, props: [String: PropValue], correlationId: String?, at date: Date? = nil) {
        serial.async { self.trackCall(name, props: props, correlationId: correlationId, at: date.map(self.time)) }
    }

    func consent(_ consent: LittleFriend.Consent, at date: Date? = nil) {
        serial.async { self.consentCall(consent, at: date.map(self.time)) }
    }

    /// Stops sending at once, then writes the opt-out flag and deletes `queue.jsonl` and
    /// `session.json` before it returns: the only call with file operations on the caller's thread,
    /// three small ones, so a process killed right after it starts opted out with nothing kept. The
    /// in-memory state is cleared on the serial queue.
    func optOut() {
        lock.lock()
        optOutCalls += 1
        filesStopped = true
        let batcher = liveBatcher
        liveBatcher = nil
        // Stopped first: once stop() returns no send is in flight and nothing is appended to the queue.
        batcher?.stop()
        writeOptOutFlag()
        if let liveQueue {
            liveQueue.clear()
        } else {
            removeFile(storage.appendingPathComponent("queue.jsonl"))
        }
        removeFile(sessions.fileURL)
        lock.unlock()
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
        lock.lock()
        liveQueue = queue
        let stopped = filesStopped
        lock.unlock()
        if stopped || FileManager.default.fileExists(atPath: optOutFile.path) {
            optedOut = true
            queue.clear()
            sessions.delete()
            return
        }
        _ = startBatcher(generation: 0)
        openWindow(at: nil, startsVisit: true)
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
        let returning = !active
        let away = backgroundAt.map { t - $0 } ?? 0
        active = true
        backgroundAt = nil
        guard !optedOut else { return }
        if let open = window {
            // The cold visit's window, or the one opt-in opened, counts from the first foreground.
            if open.since == nil { runWindow(from: t) }
            return
        }
        guard returning else { return }
        if pendingSource != nil || away >= Visit.backgroundGapMs {
            startVisit(at: t, source: pendingSource)
            openWindow(at: t)
        } else if let shown = route, shown != sentRoute {
            // A screen shown in the background.
            closeScreen(at: t)
            sendView(shown, pageType: routeType, at: t)
        } else {
            engagement.resume(at: t)
        }
    }

    private func enterBackground(at t: Int64) {
        guard active else { return }
        if !optedOut {
            if let end = window?.end { closeWindow(at: min(t, end)) }
            closeScreen(at: t)
        }
        active = false
        backgroundAt = t
        guard !optedOut else { return }
        // Foreground time is activity: a live session's last activity is the moment the app left. A
        // process launched in the background has had none.
        if journey, visit != nil, var live = session, live.isLive(at: t) {
            live.last = t
            session = live
            saveSession(live)
        }
        if let batcher = currentBatcher() {
            Task { await batcher.flushNow() }
        }
    }

    /// A link with UTM tags in an open window is the source of that window's visit and ends the
    /// window; while active it starts a new visit with a window of its own; in the background it
    /// waits for the next foreground.
    private func openLink(_ url: URL, at time: Int64?) {
        guard !optedOut,
              let campaign = CampaignRules.fromURL(url.absoluteString, extended: options.utmExtended)
        else { return }
        let t = time ?? now()
        closeWindowIfDue(by: t)
        if window != nil {
            closeWindow(at: t, link: campaign)
        } else if active {
            closeScreen(at: t)
            startVisit(at: t, source: campaign)
            openWindow(at: t)
        } else {
            pendingSource = campaign
        }
    }

    private func screenCall(_ raw: String, type: String?, at time: Int64?) {
        guard !optedOut else { return }
        guard let clean = Routes.clean(raw) else {
            Log.warn("a screen was dropped: its route is over 2048 characters, or over 256 once cleaned")
            return
        }
        var pageType: String?
        if let type {
            if Names.validPageType(type) {
                pageType = type
            } else {
                Log.warn("a screen type was left out: it does not match ^[a-z][a-z0-9_-]{0,31}$")
            }
        }
        let t = time ?? now()
        if hold(.screen(clean, type: pageType, at: t, background: !active)) { return }
        if active {
            showScreen(clean, pageType: pageType, at: t)
        } else {
            route = clean
            routeType = pageType
        }
    }

    private func showScreen(_ clean: String, pageType: String?, at t: Int64) {
        // A clock moved back is not within the second.
        if clean == route, let last = lastScreenAt, t - last >= 0, t - last < Self.dedupeMs { return }
        closeScreen(at: t)
        sendView(clean, pageType: pageType, at: t)
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
        sentRoute = clean
        lastScreenAt = t
        engagement.open(clean, at: t, counting: active)
    }

    private func trackCall(_ name: String, props: [String: PropValue], correlationId: String?, at time: Int64?) {
        guard !optedOut else { return }
        guard Names.valid(name) else {
            Log.warn("an event was dropped: its name does not match ^[a-z][a-z0-9_.:-]{0,63}$")
            return
        }
        let t = time ?? now()
        let cleaned = Props.clean(props)
        if hold(.track(name, props: cleaned, correlationId: correlationId, at: t)) { return }
        sendTrack(name, props: cleaned, correlationId: correlationId, at: t)
    }

    /// `props` are cleaned already.
    private func sendTrack(_ name: String, props: [String: PropValue]?, correlationId: String?, at t: Int64) {
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
            name, route: route ?? "/", at: t, props: props, landing: !journey,
            source: journey ? nil : visit?.source, correlationId: x
        )
    }

    /// Held in an open window; consent(.none) and consent(.required) delete the session file at once
    /// all the same.
    private func consentCall(_ consent: LittleFriend.Consent, at time: Int64?) {
        if consent == .journey && options.mode != .journey {
            Log.warn("consent(.journey) is ignored: the mode option is aggregate")
            return
        }
        let t = time ?? now()
        if !optedOut, hold(.consent(consent, at: t)) {
            if consent != .journey { sessions.delete() }
            return
        }
        applyConsent(consent, at: t)
    }

    // MARK: Landing window

    /// Opens a window. With `t` its 500 ms run from `t`; without, from the next foreground.
    /// `startsVisit`: the visit itself is created when the window ends.
    private func openWindow(at t: Int64?, startsVisit: Bool = false) {
        window?.timer?.cancel()
        windowsOpened += 1
        window = LandingWindow(id: windowsOpened, startsVisit: startsVisit)
        if let t { runWindow(from: t) }
    }

    private func runWindow(from t: Int64) {
        guard let id = window?.id else { return }
        window?.since = t
        window?.timer = scheduler.schedule(after: TimeInterval(Self.landingWindowMs) / 1000) { [weak self] in
            self?.serial.async { self?.windowTimerFired(id) }
        }
    }

    private func windowTimerFired(_ id: Int) {
        guard let open = window, open.id == id, let end = open.end else { return }
        closeWindow(at: end)
    }

    /// A call made at or after the window's end finds it closed, however late its timer runs.
    private func closeWindowIfDue(by t: Int64) {
        if let end = window?.end, t >= end { closeWindow(at: end) }
    }

    /// Holds a call while a window is open; false when there is none. The 101st call is dropped.
    private func hold(_ call: LandingWindow.Call) -> Bool {
        closeWindowIfDue(by: call.time)
        guard let open = window else { return false }
        if open.held.count < LandingWindow.limit {
            window?.held.append(call)
        } else if !open.dropLogged {
            window?.dropLogged = true
            Log.warn("a call was dropped: at most 100 are held while a new visit's landing is settled")
        }
        return true
    }

    /// Ends the window at `end`. `link` is the source of its visit. The held calls replay in
    /// order; then the screen on display, when this visit has not sent it, is the landing at `end`.
    private func closeWindow(at end: Int64, link: Campaign? = nil) {
        guard let closing = window else { return }
        window = nil
        closing.timer?.cancel()
        if closing.startsVisit {
            let start = min(closing.since ?? end, closing.held.first?.time ?? end)
            if let link { startVisit(at: start, source: link) } else { startColdVisit(at: start) }
        } else if let link, var current = visit {
            current.source = link
            visit = current
            // A visit with a source ends the session; none of this visit's events went out yet.
            session = nil
        }
        for call in closing.held {
            switch call {
            case let .screen(clean, type, t, background):
                if background {
                    route = clean
                    routeType = type
                } else {
                    showScreen(clean, pageType: type, at: t)
                }
            case let .track(name, props, correlationId, t): sendTrack(name, props: props, correlationId: correlationId, at: t)
            case let .consent(consent, t): applyConsent(consent, at: t)
            }
        }
        if active, let shown = route, shown != sentRoute {
            closeScreen(at: end)
            sendView(shown, pageType: routeType, at: end)
        }
    }

    /// The screen open at a switch of mode is closed in the mode it was counted in, and counts on in
    /// the new one. A switch to journey continues the visit, and the session held in memory when it
    /// is still live; otherwise a new session starts with the next event. When the visit's landing
    /// already went out in aggregate mode, that landing was the entry, so no journey screen of this
    /// visit carries `l`. consent(.none) and consent(.required) always drop the session and delete
    /// the file, even when the mode is already aggregate.
    private func applyConsent(_ consent: LittleFriend.Consent, at t: Int64) {
        if consent == .journey {
            guard !journey else { return }
            if !optedOut { closeScreen(at: t) }
            journey = true
            if let held = session, !held.isLive(at: t) { session = nil }
            if let live = session {
                saveSession(live)
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
        window?.timer?.cancel()
        window = nil
        engagement.clear()
        route = nil
        routeType = nil
        sentRoute = nil
        lastScreenAt = nil
        pendingSource = nil
    }

    /// Writes the session file unless `optOut()` has run since the last opt-in.
    private func saveSession(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }
        guard !filesStopped else { return }
        sessions.save(session)
    }

    private func removeFile(_ url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
            Log.warn("a file of the SDK could not be deleted at opt-out")
        }
    }

    /// One atomic create of the empty flag file. Called with `lock` held.
    private func writeOptOutFlag() {
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try Data().write(to: optOutFile, options: .atomic)
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
        // A later optOut() supersedes this call; the flag is removed under the lock it was written under.
        let current = optOutCalls == generation
        if current {
            filesStopped = false
            do {
                if FileManager.default.fileExists(atPath: optOutFile.path) {
                    try FileManager.default.removeItem(at: optOutFile)
                }
            } catch {
                Log.warn("the opt-out flag could not be removed")
            }
        }
        lock.unlock()
        guard current else { return }
        optedOut = false
        // A new visit, and in journey mode a new session, with a window of its own: counting from
        // now in the foreground, else from the next foreground.
        _ = startBatcher(generation: generation)
        openWindow(at: active ? now() : nil, startsVisit: true)
    }

    /// A cold launch with no deep link continues a live journey session: then its landing is still
    /// due only when the session's first screen was never sent. Otherwise it is a new visit.
    private func startColdVisit(at t: Int64) {
        if journey, let live = session, live.isLive(at: t) {
            visit = Visit(source: nil, landingPending: !live.entered)
            engagement.clear()
            lastScreenAt = nil
            sentRoute = nil
        } else {
            startVisit(at: t, source: nil)
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
        sentRoute = nil
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
            saveSession(current)
            event.q = current.seq
            event.x = correlationId
            queued = QueuedEvent(event: event, mode: "j", session: current.id)
        } else {
            queued = QueuedEvent(event: event, mode: "a", session: nil)
        }
        currentBatcher()?.enqueue(queued)
    }
}

/// A new visit's landing window. Its calls are held until it ends.
private struct LandingWindow {
    static let limit = 100

    enum Call {
        /// `background`: shown while the app was in the background.
        case screen(String, type: String?, at: Int64, background: Bool)
        case track(String, props: [String: PropValue]?, correlationId: String?, at: Int64)
        case consent(LittleFriend.Consent, at: Int64)

        var time: Int64 {
            switch self {
            case let .screen(_, _, t, _), let .track(_, _, _, t), let .consent(_, t): return t
            }
        }
    }

    let id: Int
    let startsVisit: Bool
    /// The window's foreground: the 500 ms run from it. Nil until then.
    var since: Int64?
    var timer: ScheduledWork?
    var held: [Call] = []
    var dropLogged = false

    var end: Int64? { since.map { $0 + Tracker.landingWindowMs } }
}
