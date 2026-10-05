import Foundation
import XCTest
@testable import LittleFriend

/// Visits, sessions, landing source, engagement, consent and opt-out, read from the events a
/// recording transport receives. Time moves only through the manual clock and scheduler.
final class EngineTests: XCTestCase {
    private let key = "lf_abcdefghijkl0123456789"
    private let app = AppInfo(i: "io.littlefriend.lab.shop", p: "ios", d: "mobile", v: "1.2.3")
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600
    private let campaignLink = URL(string: "lfshop://open?utm_source=Newsletter&utm_medium=email&utm_campaign=Launch&gclid=abc")!

    private var root: URL!
    private var dir: URL!
    private var clock: ManualClock!
    private var scheduler: ManualScheduler!
    private var transport: RecordingTransport!
    private var trackers: [Tracker] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID().uuidString)")
        dir = root.appendingPathComponent("littlefriend")
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        transport = RecordingTransport()
    }

    override func tearDown() {
        trackers.forEach { $0.drain() }
        trackers = []
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private var sessionFile: URL { dir.appendingPathComponent("session.json") }
    private var queueFile: URL { dir.appendingPathComponent("queue.jsonl") }
    private var optOutFile: URL { dir.appendingPathComponent("opt-out") }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A second app's directory: two trackers never share one.
    private var otherDir: URL { root.appendingPathComponent("other") }

    private func makeTracker(
        test: Bool = false,
        storage: URL? = nil,
        clock trackerClock: Clock? = nil,
        _ configure: (inout LittleFriend.Options) -> Void = { _ in }
    ) -> Tracker {
        var options = LittleFriend.Options()
        configure(&options)
        let tracker = Tracker(
            options: options, key: key, app: app, sdk: "ios-0.1.0", test: test, storage: storage ?? dir,
            clock: trackerClock ?? clock, transport: transport, scheduler: scheduler
        )
        trackers.append(tracker)
        return tracker
    }

    private func journey(_ options: inout LittleFriend.Options) { options.mode = .journey }

    /// Lets every tracker finish the calls made so far, then moves the clock: a tracker reads the
    /// clock when it runs a call.
    private func elapse(_ seconds: TimeInterval) {
        trackers.forEach { $0.drain() }
        clock.advance(seconds)
    }

    /// The landing window, in seconds.
    private let window = TimeInterval(Tracker.landingWindowMs) / 1000

    /// The cold launch foreground, then the landing window passes with nothing held: later calls go
    /// out as they are made.
    private func launch(_ launched: Tracker...) {
        for tracker in launched { tracker.foreground(at: clock.now(), coldLaunch: true) }
        passWindow()
    }

    /// Lets every tracker finish its calls, then runs the scheduler, and the clock with it, past
    /// the landing window.
    private func passWindow() {
        trackers.forEach { $0.drain() }
        scheduler.advance(by: window)
        trackers.forEach { $0.drain() }
    }

    /// Sends everything queued, then returns every event the transport has received.
    private func sent(_ tracker: Tracker) async -> [RecordingTransport.Sent] {
        await tracker.flush()
        return transport.sent
    }

    private func views(_ events: [RecordingTransport.Sent]) -> [RecordingTransport.Sent] {
        events.filter { $0.name == "$pageview" }
    }

    private func engages(_ events: [RecordingTransport.Sent]) -> [RecordingTransport.Sent] {
        events.filter { $0.name == "$engage" }
    }

    private func readSession() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile)) as? [String: Any] ?? [:]
    }

    private func writeSession(id: String, start: Date, last: Date, seq: Int, entered: Bool) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ms = { (d: Date) in Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }
        let object: [String: Any] = ["id": id, "start": ms(start), "last": ms(last), "seq": seq, "entered": entered]
        try JSONSerialization.data(withJSONObject: object).write(to: sessionFile)
    }

    private func ownBackupExclusion(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) > 0
    }

    /// Waits for a task, failing the test after 5 seconds instead of hanging it.
    private func finished(_ task: Task<Void, Never>) async {
        let done = expectation(description: "task returned")
        Task {
            await task.value
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }

    // MARK: Aggregate mode

    func testAggregateDeepLinkLandingAndItsSourceOnLaterEvents() async throws {
        let tracker = makeTracker()
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        tracker.screen("/cart", type: nil)
        tracker.track("checkout", props: ["plan": .string("pro")], correlationId: nil)
        let events = await sent(tracker)

        let source = ["s": "newsletter", "m": "email", "c": "launch"]
        XCTAssertEqual(events.map(\.name), ["$pageview", "signup", "$pageview", "checkout"])
        XCTAssertEqual(events[0].landing, 1, "the deep link's landing")
        XCTAssertEqual(events[0].campaign, source)
        XCTAssertEqual(events[1].landing, 1, "a later track carries the landing's source")
        XCTAssertEqual(events[1].campaign, source)
        XCTAssertNil(events[2].landing, "a later screen is not an entry")
        XCTAssertNil(events[2].campaign)
        XCTAssertEqual(events[3].landing, 1)
        XCTAssertEqual(events[3].campaign, source)
        XCTAssertEqual(events[3].props?["plan"], .string("pro"))
        for batch in transport.batches {
            XCTAssertEqual(batch["m"], .string("a"))
            XCTAssertNil(batch["s"], "no session in aggregate mode")
        }
        XCTAssertEqual(Set(events.map(\.seq)), [0], "q is 0 in aggregate mode")
        XCTAssertFalse(exists(sessionFile), "aggregate mode stores no session")
    }

    func testAggregateNewVisitAfterThirtyMinutesInTheBackgroundIsDirect() async throws {
        let tracker = makeTracker()
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        tracker.background(at: clock.now())
        elapse(29 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        tracker.screen("/a", type: nil)
        tracker.track("same_visit", props: [:], correlationId: nil)
        tracker.background(at: clock.now())
        elapse(30 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        tracker.screen("/b", type: nil)
        tracker.track("new_visit", props: [:], correlationId: nil)
        passWindow()
        tracker.screen("/c", type: nil)
        let events = await sent(tracker).filter { $0.name != "$engage" }

        XCTAssertEqual(events.map(\.name), ["$pageview", "$pageview", "same_visit", "$pageview", "new_visit", "$pageview"])
        XCTAssertEqual(events.map(\.route), ["/", "/a", "/a", "/b", "/b", "/c"])
        guard events.count == 6 else { return }
        XCTAssertEqual(events[1].landing, nil, "29 minutes away is the same visit")
        XCTAssertEqual(events[2].campaign?["s"], "newsletter", "and keeps its source")
        XCTAssertEqual(events[3].landing, 1, "30 minutes away: the screen shown in the window is a new landing")
        XCTAssertNil(events[3].campaign, "with no source")
        XCTAssertEqual(events[4].landing, 1, "a track after a direct landing says it entered from outside")
        XCTAssertNil(events[4].campaign, "with no source")
        XCTAssertNil(events[5].landing, "the next screen is not an entry")
    }

    func testEveryAggregateTrackInADirectVisitCarriesTheLandingFlag() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.track("early", props: [:], correlationId: nil)
        tracker.screen("/a", type: nil)
        elapse(2)
        tracker.track("signup", props: [:], correlationId: nil)
        tracker.screen("/b", type: nil)
        tracker.track("checkout", props: [:], correlationId: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["early", "$pageview", "signup", "$engage", "$pageview", "checkout"])
        XCTAssertEqual(events.map(\.landing), [1, 1, 1, nil, nil, 1], "tracks carry l, $engage and later screens do not")
        XCTAssertEqual(events.compactMap(\.campaign), [], "a direct visit has no c")
        XCTAssertNil(events[2].event["r"], "and iOS has no referrer")
    }

    func testADeepLinkWhileActiveStartsANewVisitAtOnce() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        elapse(5)
        tracker.handle(url: URL(string: "lfshop://open?ref=x")!)
        tracker.screen("/a", type: nil)
        elapse(5)
        tracker.handle(url: campaignLink)
        tracker.screen("/a", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        passWindow()
        let events = await sent(tracker)

        XCTAssertEqual(views(events).map(\.route), ["/", "/a", "/a"])
        XCTAssertEqual(views(events).map(\.landing), [1, nil, 1], "a link without UTM tags is ignored")
        XCTAssertEqual(views(events)[2].campaign, ["s": "newsletter", "m": "email", "c": "launch"])
        XCTAssertEqual(events.last?.campaign?["c"], "launch")
        // The screen open when the link arrived is closed in its own visit.
        XCTAssertEqual(engages(events).map(\.route), ["/", "/a"])
    }

    func testADeepLinkThatOpensTheAppFromTheBackgroundLandsOnTheScreenItOpens() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/", type: nil)
        tracker.background(at: clock.now())
        elapse(2 * minute)
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        let back = clock.ms
        elapse(0.2)
        tracker.screen("/products/:id", type: "product")
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(views(transport.sent).count, 1, "the link's visit waits for its landing window")
        passWindow()
        let events = views(await sent(tracker))

        XCTAssertEqual(events.map(\.route), ["/", "/products/:id"])
        guard events.count == 2 else { return }
        XCTAssertEqual(events.map(\.landing), [1, 1], "the screen the link opened lands its visit")
        XCTAssertEqual(events[1].campaign?["s"], "newsletter")
        XCTAssertEqual(events[1].time, back + 200)
    }

    func testAReturnAfterThirtyMinutesSendsTheScreenOnDisplayAsTheLanding() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/article", type: "article")
        elapse(5)
        tracker.background(at: clock.now())
        elapse(31 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        // An app that sends the screen again as it returns: held in the window, it is the landing.
        tracker.screen("/article", type: "article")
        elapse(3)
        tracker.track("share", props: [:], correlationId: nil)
        tracker.background(at: clock.now())
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview", "share", "$engage"])
        guard events.count == 5 else { return }
        XCTAssertEqual(events.map(\.route), ["/article", "/article", "/article", "/article", "/article"])
        XCTAssertEqual(events[2].landing, 1, "the second visit has its own landing")
        XCTAssertEqual(events[2].props, ["page_type": .string("article")], "with the screen's type")
        XCTAssertEqual(events[2].time, events[0].time.map { $0 + (5 + 31 * 60) * 1000 })
        XCTAssertEqual(events[3].landing, 1)
        XCTAssertNil(events[3].campaign)
        XCTAssertEqual(events[4].props, ["ms": .number(3000), "sum": .number(3000)], "counted from the return")
    }

    func testAJourneyReturnAfterThirtyMinutesLandsTheScreenOnDisplayInANewSession() async throws {
        let tracker = makeTracker(journey)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/article", type: "article")
        elapse(5)
        tracker.background(at: clock.now())
        elapse(31 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        elapse(3)
        tracker.track("share", props: [:], correlationId: nil)
        tracker.background(at: clock.now())
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview", "share", "$engage"])
        guard events.count == 5 else { return }
        XCTAssertEqual(events[1].session, events[0].session)
        XCTAssertNotEqual(events[2].session, events[0].session, "the second visit is a new session")
        XCTAssertEqual(events[2...4].map(\.session), [events[2].session, events[2].session, events[2].session])
        XCTAssertEqual(events[2...4].map(\.seq), [1, 2, 3], "with that pageview as q 1")
        XCTAssertEqual(events[2].landing, 1)
        XCTAssertEqual(events[2].props, ["page_type": .string("article")])
        XCTAssertNil(events[3].landing)
    }

    func testAUTMLinkWhileActiveLandsTheScreenOnDisplayWhenNoScreenFollowsInTheWindow() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(5)
        tracker.handle(url: campaignLink)
        let linked = clock.ms
        elapse(2)
        tracker.screen("/b", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        let events = await sent(tracker)

        let source = ["s": "newsletter", "m": "email", "c": "launch"]
        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview", "$engage", "$pageview", "signup"])
        guard events.count == 6 else { return }
        XCTAssertEqual(events.map(\.route), ["/a", "/a", "/a", "/a", "/b", "/b"])
        XCTAssertEqual(events[1].props, ["ms": .number(5000), "sum": .number(5000)], "closed in its own visit")
        XCTAssertEqual(events[2].landing, 1, "the screen on display lands the new visit at the window's end")
        XCTAssertEqual(events[2].campaign, source)
        XCTAssertEqual(events[2].time, linked + Tracker.landingWindowMs)
        XCTAssertEqual(events[3].props, ["ms": .number(1500), "sum": .number(1500)], "counted from the landing")
        XCTAssertNil(events[4].landing, "then /b is a plain screen")
        XCTAssertNil(events[4].campaign)
        XCTAssertEqual(events[5].campaign, source)
    }

    // MARK: Landing window

    func testAColdLaunchLinkAfterTheFirstScreenIsThatScreensSource() async throws {
        for mode in [LittleFriend.Mode.aggregate, .journey] {
            transport = RecordingTransport()
            let tracker = makeTracker(storage: root.appendingPathComponent("\(mode)")) { $0.mode = mode }
            let launched = clock.ms
            tracker.screen("/", type: nil)
            tracker.foreground(at: clock.now(), coldLaunch: true)
            elapse(0.05)
            tracker.handle(url: campaignLink)
            passWindow()
            elapse(2)
            let events = await sent(tracker)

            XCTAssertEqual(events.map(\.name), ["$pageview"], "\(mode): one landing for one launch")
            XCTAssertEqual(events.first?.landing, 1, "\(mode)")
            XCTAssertEqual(events.first?.campaign, ["s": "newsletter", "m": "email", "c": "launch"], "\(mode)")
            XCTAssertEqual(events.first?.time, launched, "\(mode): with the screen's own time")
            if mode == .journey {
                XCTAssertNotNil(events.first?.session)
                XCTAssertEqual(events.first?.seq, 1, "the landing is the session's first event")
            }
        }
    }

    func testAColdLaunchWithoutALinkSendsNothingUntilTheWindowEnds() async throws {
        let tracker = makeTracker()
        let launched = clock.ms
        tracker.screen("/", type: nil)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(transport.requestCount, 0, "the landing waits for a link")
        XCTAssertEqual(scheduler.pendingDelays, [window], "for 500 ms from the foreground")

        scheduler.advance(by: window)
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(transport.sent.map(\.name), ["$pageview"])
        XCTAssertEqual(transport.sent.first?.landing, 1)
        XCTAssertNil(transport.sent.first?.campaign, "a direct landing")
        XCTAssertEqual(transport.sent.first?.time, launched, "with the screen's own time")

        scheduler.advance(by: 0.1)
        tracker.handle(url: campaignLink)
        passWindow()
        let events = views(await sent(tracker))
        XCTAssertEqual(events.map(\.route), ["/", "/"], "a link at 600 ms starts a new visit")
        XCTAssertEqual(events.map(\.landing), [1, 1])
        XCTAssertEqual(events.last?.campaign?["s"], "newsletter")
        XCTAssertEqual(events.last?.time, launched + 600 + Tracker.landingWindowMs)
    }

    func testAUTMLinkWhileActiveLandsOnTheScreenItOpens() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/cart", type: nil)
        elapse(3)
        tracker.handle(url: campaignLink)
        elapse(0.1)
        let opened = clock.ms
        tracker.screen("/products/:id", type: "product")
        passWindow()
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        guard events.count == 3 else { return }
        XCTAssertEqual(events.map(\.route), ["/cart", "/cart", "/products/:id"], "no /cart view in the link's visit")
        XCTAssertEqual(events[1].props, ["ms": .number(3000), "sum": .number(3000)], "/cart closes in its own visit")
        XCTAssertNil(events[1].landing)
        XCTAssertNil(events[1].campaign)
        XCTAssertEqual(events[2].landing, 1)
        XCTAssertEqual(events[2].campaign, ["s": "newsletter", "m": "email", "c": "launch"])
        XCTAssertEqual(events[2].props, ["page_type": .string("product")])
        XCTAssertEqual(events[2].time, opened)
    }

    func testAUTMLinkWhileActiveWithNoScreenLandsTheScreenOnDisplayAtTheWindowsEnd() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/cart", type: "cart")
        elapse(3)
        tracker.handle(url: campaignLink)
        let linked = clock.ms
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(views(transport.sent).count, 1, "nothing lands before the window ends")
        passWindow()
        elapse(2)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview", "$engage", "$pageview"])
        guard events.count == 5 else { return }
        XCTAssertEqual(events[2].route, "/cart")
        XCTAssertEqual(events[2].landing, 1)
        XCTAssertEqual(events[2].campaign?["c"], "launch")
        XCTAssertEqual(events[2].props, ["page_type": .string("cart")], "with the type it was shown with")
        XCTAssertEqual(events[2].time, linked + Tracker.landingWindowMs)
        XCTAssertEqual(events[3].props, ["ms": .number(2000), "sum": .number(2000)], "counting from the window's end")
        XCTAssertNil(events[4].landing)
    }

    func testAReturnAfterThirtyMinutesLandsTheScreenOnDisplayOrTheScreenShownInTheWindow() async throws {
        for (shown, mode) in [(false, LittleFriend.Mode.aggregate), (true, .aggregate), (false, .journey), (true, .journey)] {
            transport = RecordingTransport()
            let tracker = makeTracker(storage: root.appendingPathComponent("\(shown)-\(mode)")) { $0.mode = mode }
            launch(tracker)
            tracker.screen("/article", type: "article")
            elapse(5)
            tracker.background(at: clock.now())
            elapse(31 * minute)
            tracker.foreground(at: clock.now(), coldLaunch: false)
            let back = clock.ms
            if shown {
                elapse(0.1)
                tracker.screen("/b", type: nil)
            }
            passWindow()
            let label = "\(mode), screen in the window: \(shown)"
            let events = await sent(tracker).filter { $0.name != "$engage" }

            XCTAssertEqual(events.map(\.route), ["/article", shown ? "/b" : "/article"], label)
            guard events.count == 2 else { continue }
            XCTAssertEqual(events[1].landing, 1, label)
            XCTAssertEqual(events[1].time, shown ? back + 100 : back + Tracker.landingWindowMs, label)
            XCTAssertEqual(events[1].props, shown ? nil : ["page_type": .string("article")], label)
            if mode == .journey {
                XCTAssertNotEqual(events[1].session, events[0].session, "\(label): a new session")
                XCTAssertEqual(events[1].seq, 1, "\(label): with the landing as q 1")
            }
        }
    }

    func testATrackHeldInTheWindowCarriesTheCampaignOfTheLinkThatEndsIt() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        tracker.track("app_open", props: [:], correlationId: nil)
        elapse(0.05)
        tracker.handle(url: campaignLink)
        passWindow()
        tracker.screen("/a", type: nil)
        elapse(2)
        tracker.handle(url: URL(string: "lfshop://open?utm_source=partner")!)
        tracker.track("shared", props: [:], correlationId: nil)
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(transport.sent.map(\.name), ["$pageview", "app_open", "$pageview", "$engage"], "held until the window ends")
        passWindow()
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "app_open", "$pageview", "$engage", "shared", "$pageview"])
        guard events.count == 6 else { return }
        XCTAssertEqual(events[1].landing, 1)
        XCTAssertEqual(events[1].campaign?["s"], "newsletter", "the cold launch's link")
        XCTAssertEqual(events[4].landing, 1)
        XCTAssertEqual(events[4].campaign, ["s": "partner"], "the link while active")
        XCTAssertEqual(events[5].route, "/a")
        XCTAssertEqual(events[5].campaign, ["s": "partner"])
    }

    func testASecondLinkInTheWindowReplacesTheSourceAndEndsTheWindow() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(2)
        tracker.handle(url: campaignLink)
        elapse(0.1)
        tracker.handle(url: URL(string: "lfshop://open?utm_source=partner")!)
        let second = clock.ms
        tracker.drain()
        let events = views(await sent(tracker))

        XCTAssertEqual(events.map(\.route), ["/a", "/a"], "one visit for the two links")
        XCTAssertEqual(events.last?.campaign, ["s": "partner"])
        XCTAssertEqual(events.last?.time, second, "the second link ends the window at once")
    }

    func testTheHundredAndFirstCallInTheWindowIsDroppedWithOneLogLine() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let tracker = makeTracker()
        for i in 0..<102 { tracker.track("e\(i)", props: [:], correlationId: nil) }
        tracker.foreground(at: clock.now(), coldLaunch: true)
        passWindow()
        tracker.track("after", props: [:], correlationId: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), (0..<100).map { "e\($0)" } + ["after"])
        XCTAssertEqual(log.lines.filter { $0.contains("landing") }.count, 1, log.lines.joined(separator: "\n"))
    }

    func testABackgroundBeforeTheWindowEndsLandsTheVisitAtOnce() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(3)
        tracker.background(at: clock.now())
        elapse(31 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        elapse(0.2)
        let left = clock.ms
        tracker.background(at: clock.now())
        let events = await sent(tracker)

        XCTAssertEqual(views(events).map(\.route), ["/a", "/a"])
        XCTAssertEqual(views(events).last?.landing, 1)
        XCTAssertEqual(views(events).last?.time, left, "the window ends when the app leaves")
        XCTAssertEqual(scheduler.pendingDelays, [], "and its timer is cancelled")
    }

    func testAStartInTheBackgroundHoldsCallsUntilTheFirstForeground() async throws {
        let tracker = makeTracker()
        tracker.background(at: clock.now())
        tracker.track("refresh", props: [:], correlationId: nil)
        elapse(10 * minute)
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(transport.requestCount, 0, "the window stays open in the background")
        XCTAssertEqual(scheduler.pendingDelays, [])

        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        elapse(0.1)
        tracker.handle(url: campaignLink)
        let events = await sent(tracker)
        XCTAssertEqual(events.map(\.name), ["refresh", "$pageview"])
        XCTAssertEqual(events.map(\.landing), [1, 1])
        XCTAssertEqual(events.map { $0.campaign?["s"] }, ["newsletter", "newsletter"])
    }

    func testConsentHeldInTheWindowKeepsItsPlaceAmongTheCalls() async throws {
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        tracker.track("browse", props: [:], correlationId: "checkout_7Hq2LmX9pR4t")
        tracker.consent(.journey)
        tracker.track("signup", props: [:], correlationId: "checkout_7Hq2LmX9pR4t")
        passWindow()
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "browse", "signup"])
        XCTAssertEqual(events.map(\.mode), ["a", "a", "j"], "each call in the mode it was made in")
        XCTAssertEqual(events.map(\.correlationId), [nil, nil, "checkout_7Hq2LmX9pR4t"])
        XCTAssertEqual(events.first?.landing, 1)
    }

    func testOptInOpensAWindowForTheNextVisit() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.optOut()
        tracker.optIn()
        tracker.screen("/a", type: nil)
        elapse(0.1)
        tracker.handle(url: campaignLink)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.route), ["/a"])
        XCTAssertEqual(events.first?.landing, 1)
        XCTAssertEqual(events.first?.campaign?["s"], "newsletter")
    }

    func testExtendedUTMTagsOnlyWithTheOption() async throws {
        let link = URL(string: "lfshop://open?utm_source=a&utm_term=shoes&utm_content=hero")!
        let plain = makeTracker()
        plain.handle(url: link)
        plain.screen("/", type: nil)
        let extended = makeTracker(storage: otherDir) { $0.utmExtended = true }
        extended.handle(url: link)
        extended.screen("/", type: nil)
        await plain.flush()
        let events = await sent(extended)

        XCTAssertEqual(events.map(\.campaign), [["s": "a"], ["s": "a", "t": "shoes", "n": "hero"]])
    }

    // MARK: Journey mode

    func testJourneyKeepsOneSessionAcrossScreensWithSequenceNumbers() async throws {
        let tracker = makeTracker(journey)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        elapse(3)
        tracker.screen("/products/:id", type: "product")
        tracker.track("add_to_cart", props: [:], correlationId: nil)
        elapse(2)
        tracker.screen("/cart", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview", "add_to_cart", "$engage", "$pageview"])
        let session = try XCTUnwrap(events.first?.session)
        XCTAssertEqual(Set(events.map(\.session)), [session])
        XCTAssertEqual(Set(events.map(\.mode)), ["j"])
        XCTAssertEqual(events.map(\.seq), [1, 2, 3, 4, 5, 6], "seq counts every event of the session from 1")
        XCTAssertEqual(events.map(\.landing), [1, nil, nil, nil, nil, nil], "a direct landing, then nothing")
        XCTAssertNil(events[3].campaign, "journey events leave the source to the session")

        let u = Array(session.utf8)
        XCTAssertEqual(u.count, 20)
        XCTAssertTrue(u.allSatisfy { Array("abcdefghijklmnopqrstuvwxyz234567".utf8).contains($0) }, session)

        let stored = try readSession()
        XCTAssertEqual(Set(stored.keys), ["id", "start", "last", "seq", "entered"])
        XCTAssertEqual(stored["id"] as? String, session)
        XCTAssertEqual(stored["seq"] as? Int, 6)
        XCTAssertEqual(stored["entered"] as? Bool, true)
        XCTAssertEqual((stored["start"] as? NSNumber)?.int64Value, events[0].time)
        XCTAssertEqual((stored["last"] as? NSNumber)?.int64Value, events[5].time)
    }

    func testJourneyRelaunchWithinThirtyMinutesContinuesTheSession() async throws {
        let first = makeTracker(journey)
        launch(first)
        first.screen("/", type: nil)
        first.track("signup", props: [:], correlationId: nil)
        await first.flush()
        // The app is killed: no background call.

        elapse(10 * minute)
        let second = makeTracker(journey)
        launch(second)
        second.screen("/cart", type: nil)
        await second.flush()

        elapse(31 * minute)
        let third = makeTracker(journey)
        launch(third)
        third.screen("/", type: nil)
        let events = await sent(third)

        XCTAssertEqual(events.map(\.route), ["/", "/", "/cart", "/"])
        XCTAssertEqual(events[2].session, events[0].session, "10 minutes later: the same session")
        XCTAssertEqual(events[2].seq, 3, "seq continues")
        XCTAssertNil(events[2].landing, "a relaunch that continues a session is not a new visit")
        XCTAssertNotEqual(events[3].session, events[0].session, "31 minutes after the last activity: a new session")
        XCTAssertEqual(events[3].seq, 1)
        XCTAssertEqual(events[3].landing, 1)
    }

    func testADeepLinkWithUTMStartsANewSessionWhileTheAppLives() async throws {
        let tracker = makeTracker(journey)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(2)
        tracker.background(at: clock.now())
        elapse(10 * minute)
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        tracker.screen("/a", type: nil)
        elapse(2)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview", "$engage", "$pageview"])
        guard events.count == 5 else { return }
        let first = try XCTUnwrap(events[0].session)
        XCTAssertEqual(events[1].session, first, "the first session's events keep their s")
        XCTAssertEqual(events[0...1].map(\.seq), [1, 2])
        let second = try XCTUnwrap(events[2].session)
        XCTAssertNotEqual(second, first, "a live session ends when a link with UTM opens a visit")
        XCTAssertEqual(events[2...4].map(\.session), [second, second, second])
        XCTAssertEqual(events[2...4].map(\.seq), [1, 2, 3])
        XCTAssertEqual(events[2].landing, 1, "the link's landing is the new session's entry")
        XCTAssertEqual(events[2].campaign, ["s": "newsletter", "m": "email", "c": "launch"])
        XCTAssertNil(events[4].landing)
        XCTAssertEqual(try readSession()["id"] as? String, second)
    }

    func testADeepLinkWithUTMAtAColdLaunchStartsANewSession() async throws {
        let first = makeTracker(journey)
        first.foreground(at: clock.now(), coldLaunch: true)
        first.screen("/a", type: nil)
        elapse(2)
        first.background(at: clock.now())
        await first.flush()
        // Killed in the background; relaunched by a link 10 minutes later, inside the session's 30.
        elapse(10 * minute)
        let second = makeTracker(journey)
        second.handle(url: campaignLink)
        second.foreground(at: clock.now(), coldLaunch: true)
        second.screen("/a", type: nil)
        let events = await sent(second)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        guard events.count == 3 else { return }
        XCTAssertEqual(events[1].session, events[0].session)
        XCTAssertNotEqual(events[2].session, events[0].session)
        XCTAssertEqual(events[2].seq, 1)
        XCTAssertEqual(events[2].landing, 1)
        XCTAssertEqual(events[2].campaign?["c"], "launch")
    }

    func testAColdLaunchOrAReturnWithoutALinkKeepsTheLiveSession() async throws {
        let first = makeTracker(journey)
        first.foreground(at: clock.now(), coldLaunch: true)
        first.screen("/a", type: nil)
        first.background(at: clock.now())
        elapse(10 * minute)
        first.handle(url: URL(string: "lfshop://open?ref=x")!)
        first.foreground(at: clock.now(), coldLaunch: false)
        first.screen("/b", type: nil)
        await first.flush()
        elapse(10 * minute)
        let second = makeTracker(journey)
        launch(second)
        second.screen("/c", type: nil)
        let events = views(await sent(second))

        XCTAssertEqual(events.map(\.route), ["/a", "/b", "/c"])
        XCTAssertEqual(Set(events.map(\.session)).count, 1, "a link without UTM tags is no source")
        XCTAssertEqual(events.map(\.landing), [1, nil, nil])
    }

    func testForegroundTimeKeepsTheSessionAliveUntilTheBackground() async throws {
        let first = makeTracker(journey)
        first.foreground(at: clock.now(), coldLaunch: true)
        first.screen("/", type: nil)
        elapse(25 * minute)
        first.background(at: clock.now())
        await first.flush()
        // Killed in the background; 35 minutes after the screen, 10 after the app left.
        elapse(10 * minute)
        let second = makeTracker(journey)
        launch(second)
        second.screen("/cart", type: nil)
        let events = await sent(second)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        XCTAssertEqual(Set(events.map(\.session)).count, 1, "the session's last activity is the background")
        XCTAssertEqual(events.map(\.seq), [1, 2, 3])
    }

    func testTheEngageOfAScreenThatOutlivedItsSessionStaysInThatSession() async throws {
        let tracker = makeTracker(journey)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(40 * minute)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        XCTAssertEqual(events[1].session, events[0].session, "engagement describes the screen it closes")
        XCTAssertEqual(events[1].seq, 2)
        XCTAssertEqual(events[1].props?["ms"], .number(1_800_000))
        XCTAssertNotEqual(events[2].session, events[0].session, "40 minutes without an event: a new session")
        XCTAssertEqual(events[2].seq, 1)
        XCTAssertNil(events[2].landing, "inside the same visit")
    }

    func testARelaunchBeforeTheFirstScreenWasSentStillSendsTheLanding() async throws {
        let id = "abcdefghij234567abcd"
        try writeSession(id: id, start: clock.now() - 60, last: clock.now() - 60, seq: 0, entered: false)
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.session), [id])
        XCTAssertEqual(events.map(\.landing), [1], "the session's entry had not been sent")
        XCTAssertEqual(events.map(\.seq), [1])
    }

    func testJourneySessionRollsAfter24HoursEvenWhileActive() async throws {
        let tracker = makeTracker(journey)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        for _ in 0..<73 {
            elapse(20 * minute)
            tracker.track("tick", props: [:], correlationId: nil)
        }
        let events = await sent(tracker)
        let start = try XCTUnwrap(events.first?.time)
        let first = try XCTUnwrap(events.first?.session)

        let before = events.filter { $0.time! - start < 24 * 3_600_000 }
        let after = events.filter { $0.time! - start >= 24 * 3_600_000 }
        XCTAssertEqual(Set(before.map(\.session)), [first])
        XCTAssertEqual(after.count, 2)
        XCTAssertNotEqual(after[0].session, first, "24 hours after it started")
        XCTAssertEqual(after.map(\.seq), [1, 2])
        XCTAssertEqual(after[1].session, after[0].session)
        XCTAssertNil(after[0].landing, "a session that rolls mid-visit has no landing")
    }

    func testTheSessionFileIsExcludedFromBackup() async throws {
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        tracker.drain()
        XCTAssertTrue(ownBackupExclusion(dir))
        XCTAssertTrue(ownBackupExclusion(sessionFile))
        tracker.screen("/a", type: nil)
        tracker.drain()
        XCTAssertTrue(ownBackupExclusion(sessionFile), "an atomic write replaces the file; the flag is set again")
    }

    func testACorruptedSessionFileStartsANewSession() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x7B, 0x22]).write(to: sessionFile)
        let tracker = makeTracker(journey)
        tracker.drain()
        XCTAssertFalse(exists(sessionFile), "an unreadable session file is deleted")
        launch(tracker)
        tracker.screen("/", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.seq), [1])
        XCTAssertEqual(events.map(\.landing), [1])
        XCTAssertEqual(try readSession()["id"] as? String, events.first?.session)
    }

    func testASessionFileThatCannotBeReadIsKeptAndNotOverwritten() async throws {
        let log = LogCapture()
        defer { log.stop() }
        try writeSession(id: "abcdefghij234567abcd", start: clock.now() - 60, last: clock.now() - 60, seq: 4, entered: true)
        let bytes = try Data(contentsOf: sessionFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sessionFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sessionFile.path) }
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.seq), [1, 2], "this launch runs a session of its own")
        XCTAssertNotEqual(events.first?.session, "abcdefghij234567abcd")
        XCTAssertEqual(events.first?.landing, 1)
        XCTAssertTrue(exists(sessionFile), "a read error keeps the file")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sessionFile.path)
        XCTAssertEqual(try Data(contentsOf: sessionFile), bytes, "and never writes over it")
        XCTAssertEqual(log.lines.filter { $0.contains("session file") }.count, 1, log.lines.joined(separator: "\n"))
    }

    func testAWrongShapedSessionFileStartsANewSession() async throws {
        let live = clock.now() - 60
        let shapes: [[String: Any]] = [
            ["id": "short", "start": 1, "last": 1, "seq": 1, "entered": true],
            ["id": "abcdefghij234567abcd", "start": "1", "last": 1, "seq": 1, "entered": true],
            ["id": "abcdefghij234567abcd", "start": 1, "last": 1, "seq": -1, "entered": true],
            ["id": "abcdefghij234567abcd", "last": 1, "seq": 1, "entered": true],
            ["id": "abcdefghij234567abcd", "start": 1, "last": 1, "seq": 1, "entered": 1],
            ["id": "abcdefghij234567abcd", "start": 2, "last": 1, "seq": 1, "entered": true],
        ]
        for (index, shape) in shapes.enumerated() {
            var object = shape
            // Live times, so only the shape decides.
            for key in ["start", "last"] where object[key] is Int {
                object[key] = Int64((live.timeIntervalSince1970 * 1000).rounded(.down)) + Int64(object[key] as! Int)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: sessionFile)
            let tracker = makeTracker(journey)
            tracker.drain()
            XCTAssertFalse(exists(sessionFile), "shape \(index) is deleted")
        }
    }

    func testASessionFileWithFieldsFromALaterVersionIsKept() async throws {
        try writeSession(id: "abcdefghij234567abcd", start: clock.now() - 60, last: clock.now() - 60, seq: 4, entered: true)
        var object = try readSession()
        object["added_later"] = ["x": 1]
        try JSONSerialization.data(withJSONObject: object).write(to: sessionFile)
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.session), ["abcdefghij234567abcd"])
        XCTAssertEqual(events.map(\.seq), [5])
        XCTAssertEqual(events.map(\.landing), [nil])
    }

    func testAClockMovedBackPastTheSessionStartEndsTheSession() async throws {
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        // Sent first: once the clock is back, this event would look two hours ahead and be dropped.
        await tracker.flush()
        elapse(-2 * hour)
        tracker.screen("/a", type: nil)
        let events = views(await sent(tracker))

        XCTAssertEqual(events.map(\.route), ["/", "/a"])
        XCTAssertNotEqual(events.first?.session, events.last?.session)
        XCTAssertEqual(events.last?.seq, 1)
        XCTAssertEqual(events.last?.landing, nil, "the visit goes on")
    }

    func testJourneyCorrelationIdFollowsTheContract() async throws {
        let tracker = makeTracker(journey)
        let aggregate = makeTracker(storage: otherDir)
        launch(tracker, aggregate)
        tracker.track("signup", props: [:], correlationId: "checkout_7Hq2LmX9pR4t")
        tracker.track("signup", props: [:], correlationId: "1234567890123456")
        tracker.track("signup", props: [:], correlationId: "user-555-010-9999")
        tracker.track("signup", props: [:], correlationId: "short")
        aggregate.track("signup", props: [:], correlationId: "checkout_7Hq2LmX9pR4t")
        await tracker.flush()
        let events = await sent(aggregate)

        XCTAssertEqual(events.map(\.correlationId), ["checkout_7Hq2LmX9pR4t", nil, nil, nil, nil])
        XCTAssertEqual(events.map(\.mode), ["j", "j", "j", "j", "a"])
    }

    // MARK: Consent

    func testConsentRequiredRunsAggregateUntilJourney() async throws {
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        tracker.track("browse", props: [:], correlationId: "checkout_7Hq2LmX9pR4t")
        tracker.drain()
        XCTAssertFalse(exists(sessionFile))
        elapse(4)
        tracker.consent(.journey)
        tracker.screen("/b", type: nil)
        tracker.track("signup", props: [:], correlationId: "checkout_7Hq2LmX9pR4t")
        let events = await sent(tracker)

        let source = ["s": "newsletter", "m": "email", "c": "launch"]
        XCTAssertEqual(events.map(\.name), ["$pageview", "browse", "$engage", "$pageview", "signup"])
        guard events.count == 5 else { return }
        XCTAssertEqual(events.map(\.mode), ["a", "a", "a", "j", "j"])
        XCTAssertEqual(events[0].route, "/a")
        XCTAssertEqual(events[0].landing, 1, "the aggregate landing is the visit's entry")
        XCTAssertEqual(events[0].campaign, source)
        XCTAssertNil(events[0].session)
        XCTAssertEqual(events[1].landing, 1)
        XCTAssertNil(events[1].correlationId, "no correlation id before consent")
        XCTAssertEqual(events[2].route, "/a", "the screen open at consent is closed in aggregate mode")
        XCTAssertEqual(events[3].route, "/b")
        let session = try XCTUnwrap(events[3].session)
        XCTAssertEqual(events[3].seq, 1, "a fresh session starts at the next screen")
        XCTAssertNil(events[3].landing, "it is not an entry: the aggregate landing was")
        XCTAssertNil(events[3].campaign)
        XCTAssertEqual(events[4].session, session)
        XCTAssertEqual(events[4].seq, 2)
        XCTAssertNil(events[4].landing)
        XCTAssertNil(events[4].campaign)
        XCTAssertEqual(events[4].correlationId, "checkout_7Hq2LmX9pR4t")
        XCTAssertTrue(exists(sessionFile))
    }

    func testConsentBeforeTheLandingMakesTheFirstJourneyScreenTheLanding() async throws {
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.track("browse", props: [:], correlationId: nil)
        tracker.consent(.journey)
        tracker.screen("/a", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["browse", "$pageview"])
        guard events.count == 2 else { return }
        XCTAssertEqual(events.map(\.mode), ["a", "j"])
        XCTAssertEqual(events[1].seq, 1)
        XCTAssertEqual(events[1].landing, 1, "no landing was sent yet in this visit")
        XCTAssertEqual(events[1].campaign?["c"], "launch")
    }

    func testTheScreenOpenAtConsentCountsOnInTheSession() async throws {
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(4)
        tracker.consent(.journey)
        elapse(10)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$engage", "$pageview"])
        guard events.count == 4 else { return }
        XCTAssertEqual(events.map(\.mode), ["a", "a", "j", "j"])
        XCTAssertEqual(engages(events).map(\.route), ["/a", "/a"])
        XCTAssertEqual(engages(events).map(\.props), [
            ["ms": .number(4000), "sum": .number(4000)],
            ["ms": .number(10000), "sum": .number(14000)],
        ], "the time after consent is journey activity on the same screen")
        XCTAssertEqual(events[2...3].map(\.seq), [1, 2])
        XCTAssertEqual(events[3].session, events[2].session)
        XCTAssertNil(events[3].landing)
    }

    func testConsentBeforeTheFirstScreenContinuesALiveSession() async throws {
        try writeSession(id: "abcdefghij234567abcd", start: clock.now() - 300, last: clock.now() - 60, seq: 7, entered: true)
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        launch(tracker)
        tracker.consent(.journey)
        tracker.screen("/", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.session), ["abcdefghij234567abcd"])
        XCTAssertEqual(events.map(\.seq), [8])
        XCTAssertEqual(events.map(\.landing), [nil], "a relaunch that continues a session is not a new visit")
    }

    func testWaitingForConsentKeepsNoSessionFile() async throws {
        let required: (inout LittleFriend.Options) -> Void = {
            $0.mode = .journey
            $0.consent = .required
        }
        try writeSession(id: "abcdefghij234567abcd", start: clock.now() - 300, last: clock.now() - 60, seq: 2, entered: true)
        makeTracker(required).drain()
        XCTAssertFalse(exists(sessionFile), "a live session waits in memory only")

        try writeSession(id: "abcdefghij234567abcd", start: clock.now() - 3 * hour, last: clock.now() - 31 * minute, seq: 2, entered: true)
        makeTracker(required).drain()
        XCTAssertFalse(exists(sessionFile))

        try writeSession(id: "abcdefghij234567abcd", start: clock.now() - 300, last: clock.now() - 60, seq: 2, entered: true)
        makeTracker().drain()
        XCTAssertFalse(exists(sessionFile), "an aggregate mode app keeps none at all")
    }

    func testConsentContinuesTheSessionALaunchThatWaitedHeldInMemory() async throws {
        let id = "abcdefghij234567abcd"
        try writeSession(id: id, start: clock.now() - 300, last: clock.now() - 60, seq: 7, entered: true)
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        tracker.drain()
        XCTAssertFalse(exists(sessionFile), "no session file while the mode is aggregate")
        elapse(5 * minute)
        tracker.consent(.journey)
        tracker.drain()
        XCTAssertEqual(try readSession()["id"] as? String, id, "journey mode writes it back")
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        guard events.count == 3 else { return }
        XCTAssertEqual(events.map(\.mode), ["a", "a", "j"])
        XCTAssertEqual(events[2].session, id, "5 minutes later the session is still live and continues")
        XCTAssertEqual(events[2].seq, 8)
        XCTAssertNil(events[2].landing)
        XCTAssertEqual(try readSession()["seq"] as? Int, 8)
    }

    func testConsentWithdrawnOrRequiredDeletesTheSessionFile() async throws {
        for withdrawn in [LittleFriend.Consent.none, .required] {
            let tracker = makeTracker(storage: root.appendingPathComponent("\(withdrawn)"), journey)
            let file = root.appendingPathComponent("\(withdrawn)").appendingPathComponent("session.json")
            launch(tracker)
            tracker.screen("/", type: nil)
            tracker.drain()
            XCTAssertTrue(exists(file))
            tracker.consent(withdrawn)
            tracker.drain()
            XCTAssertFalse(exists(file), "consent(.\(withdrawn)) deletes the session file")
            tracker.screen("/a", type: nil)
            tracker.drain()
            XCTAssertFalse(exists(file), "and aggregate mode writes none")
        }
    }

    func testConsentNoneWhileWaitingDropsTheSessionInMemory() async throws {
        let id = "abcdefghij234567abcd"
        try writeSession(id: id, start: clock.now() - 300, last: clock.now() - 60, seq: 7, entered: true)
        let tracker = makeTracker {
            $0.mode = .journey
            $0.consent = .required
        }
        launch(tracker)
        tracker.consent(.none)
        tracker.consent(.journey)
        tracker.screen("/a", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.mode, "j")
        XCTAssertNotEqual(events.first?.session, id, "consent(.none) dropped the session the launch held")
        XCTAssertEqual(events.first?.seq, 1)
        XCTAssertEqual(events.first?.landing, 1)
    }

    func testConsentWithdrawnStopsTheSessionAndContinuesInAggregate() async throws {
        let tracker = makeTracker(journey)
        tracker.handle(url: campaignLink)
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/", type: nil)
        tracker.drain()
        XCTAssertTrue(exists(sessionFile))
        elapse(3)
        tracker.consent(.none)
        tracker.drain()
        XCTAssertFalse(exists(sessionFile), "the session file is deleted")
        elapse(2)
        tracker.screen("/a", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$engage", "$pageview", "signup"])
        XCTAssertEqual(events.map(\.mode), ["j", "j", "a", "a", "a"])
        XCTAssertEqual(engages(events).map { $0.props?["ms"] }, [.number(3000), .number(2000)])
        XCTAssertNil(events[3].landing, "the visit continues")
        XCTAssertEqual(events[4].landing, 1, "with its source on later events")
        XCTAssertEqual(events[4].campaign?["s"], "newsletter")
        XCTAssertFalse(exists(sessionFile))
    }

    func testConsentToJourneyInAggregateModeIsIgnoredWithOneLogLine() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let tracker = makeTracker()
        launch(tracker)
        tracker.consent(.journey)
        tracker.screen("/", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.mode), ["a"])
        XCTAssertFalse(exists(sessionFile))
        XCTAssertEqual(log.lines.filter { $0.contains("consent") }.count, 1)
    }

    // MARK: Screens

    func testTheSameScreenWithinOneSecondIsIgnored() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(0.9)
        tracker.screen("/a", type: nil)
        elapse(11.1)
        tracker.screen("/b", type: nil)
        elapse(0.5)
        tracker.screen("/a", type: nil)
        elapse(1)
        tracker.screen("/a", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(views(events).map(\.route), ["/a", "/b", "/a", "/a"])
        XCTAssertEqual(engages(events).first?.props?["ms"], .number(12000), "the ignored call did not close the screen")
    }

    func testAClockMovedBackDoesNotDedupeTheSameScreen() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(-5 * minute)
        tracker.screen("/a", type: nil)
        elapse(0.5)
        tracker.screen("/a", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(views(events).map(\.route), ["/a", "/a"], "5 minutes back is not within 1 second")
        XCTAssertEqual(views(events).map(\.time), [clock.ms - 500 + 5 * 60_000, clock.ms - 500])
    }

    func testScreenTypeIsSentOnlyWhenItIsAValidKey() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/products/:id", type: "product")
        tracker.screen("/a", type: "Product Page")
        tracker.screen("/b", type: "")
        tracker.screen("/c", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.props), [["page_type": .string("product")], nil, nil, nil])
    }

    func testRoutesAreCleanedOnTheDevice() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("orders/8812?tab=1", type: nil)
        tracker.screen("/u/jane@example.com", type: nil)
        let events = await sent(tracker)
        XCTAssertEqual(events.map(\.route), ["/orders/:id", "/u/:redacted"])
    }

    func testAnInvalidNameOrRouteIsDroppedWithOneLogLine() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let tracker = makeTracker()
        launch(tracker)
        tracker.track("Sign Up", props: [:], correlationId: nil)
        tracker.screen("/" + String(repeating: "x", count: 300), type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(log.lines.count, 2, log.lines.joined(separator: "\n"))
        XCTAssertEqual(log.lines.filter { $0.contains("name") }.count, 1)
        XCTAssertEqual(log.lines.filter { $0.contains("route") }.count, 1)
        XCTAssertFalse(log.lines.joined().contains("Sign Up"), "a log line never holds event content")
    }

    func testReservedNamesAreNotCustomEvents() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.track("$pageview", props: [:], correlationId: nil)
        tracker.track("signup", props: ["plan": .string("pro"), "Bad Key": .bool(true), "email": .string("a@b.co")], correlationId: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["signup"])
        XCTAssertEqual(events.first?.props, ["plan": .string("pro")])
        XCTAssertEqual(events.first?.route, "/", "a track before any screen is recorded under /")
    }

    // MARK: Engagement

    func testTwelveSecondsOnAScreenSendsEngageUnderThatRoute() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(12)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        XCTAssertEqual(events[1].route, "/a")
        XCTAssertEqual(events[1].props, ["ms": .number(12000), "sum": .number(12000)])
        XCTAssertNil(events[1].landing, "engagement never carries the source")
    }

    func testHalfASecondSendsNoEngage() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(0.5)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)
        XCTAssertEqual(events.map(\.name), ["$pageview", "$pageview"])
    }

    func testBackgroundClosesTheScreenAndPausesTheCount() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(12)
        tracker.background(at: clock.now())
        elapse(10 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        elapse(3)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$engage", "$pageview"], "no new view on return")
        XCTAssertEqual(events[1].props, ["ms": .number(12000), "sum": .number(12000)])
        XCTAssertEqual(events[2].route, "/a", "the screen reopened on return")
        XCTAssertEqual(events[2].props, ["ms": .number(3000), "sum": .number(15000)], "the background time is not counted")
    }

    func testFortyFiveMinutesOnOneScreenIsCappedAtThirty() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(45 * minute)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)
        XCTAssertEqual(engages(events).map(\.props), [["ms": .number(1_800_000), "sum": .number(1_800_000)]])
    }

    func testAClockMovedBackAddsNothing() async throws {
        let tracker = makeTracker()
        launch(tracker)
        tracker.screen("/a", type: nil)
        elapse(4)
        tracker.screen("/b", type: nil)
        elapse(-5 * minute)
        tracker.screen("/c", type: nil)
        elapse(2)
        tracker.screen("/d", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(engages(events).map(\.route), ["/a", "/c"])
        XCTAssertEqual(engages(events).map(\.props), [
            ["ms": .number(4000), "sum": .number(4000)],
            ["ms": .number(2000), "sum": .number(2000)],
        ])
    }

    func testSumIsTheScreensRunningTotal() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(4)
        tracker.screen("/b", type: nil)
        elapse(8)
        tracker.screen("/c", type: nil)
        elapse(30)
        tracker.screen("/d", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(engages(events).map(\.route), ["/a", "/b", "/c"])
        XCTAssertEqual(engages(events).map(\.props), [
            ["ms": .number(4000), "sum": .number(4000)],
            ["ms": .number(8000), "sum": .number(8000)],
            ["ms": .number(30000), "sum": .number(30000)],
        ], "each screen starts its own total")
    }

    func testSumRunsOnForTheSameScreenAcrossABackgroundPause() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(12)
        tracker.background(at: clock.now())
        elapse(2 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        elapse(15)
        tracker.screen("/b", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(engages(events).map(\.route), ["/a", "/a"])
        XCTAssertEqual(engages(events).map(\.props), [
            ["ms": .number(12000), "sum": .number(12000)],
            ["ms": .number(15000), "sum": .number(27000)],
        ])
    }

    func testTheCapHoldsForOneScreenAcrossBackgroundPauses() async throws {
        let tracker = makeTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(20 * minute)
        tracker.background(at: clock.now())
        elapse(1 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        elapse(20 * minute)
        tracker.background(at: clock.now())
        elapse(1 * minute)
        tracker.foreground(at: clock.now(), coldLaunch: false)
        elapse(5 * minute)
        tracker.screen("/b", type: nil)
        elapse(3)
        tracker.screen("/c", type: nil)
        let events = await sent(tracker)

        XCTAssertEqual(engages(events).map(\.route), ["/a", "/a", "/b"], "nothing past the cap on /a")
        XCTAssertEqual(engages(events).map(\.props), [
            ["ms": .number(1_200_000), "sum": .number(1_200_000)],
            ["ms": .number(600_000), "sum": .number(1_800_000)],
            ["ms": .number(3000), "sum": .number(3000)],
        ], "30 minutes for the screen in all, then a new screen counts afresh")
    }

    // MARK: Opt-out

    func testOptOutDuringARetryingSendSendsNothingMoreAndOptInResumes() async throws {
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        transport.reply(.retry(after: nil))
        let flushing = Task { await tracker.flush() }
        await transport.waitForRequests(1)
        let delays = await scheduler.waitForPending()
        XCTAssertEqual(delays, [1], "the batch waits for its first retry")
        let firstSession = try XCTUnwrap(transport.sent.first?.session)

        tracker.optOut()
        await finished(flushing)
        scheduler.advance(by: 60)
        XCTAssertEqual(transport.requestCount, 1, "the waiting retry never goes out")
        tracker.drain()
        XCTAssertFalse(exists(queueFile))
        XCTAssertFalse(exists(sessionFile))
        XCTAssertTrue(exists(optOutFile))

        tracker.screen("/a", type: nil)
        tracker.track("after", props: [:], correlationId: nil)
        await tracker.flush()
        scheduler.advance(by: 60)
        XCTAssertEqual(transport.requestCount, 1, "every later call is a no-op")
        XCTAssertFalse(exists(queueFile))
        XCTAssertFalse(exists(sessionFile))

        let relaunched = makeTracker(journey)
        relaunched.screen("/b", type: nil)
        await relaunched.flush()
        XCTAssertEqual(transport.requestCount, 1, "the choice survives a relaunch")

        relaunched.optIn()
        relaunched.screen("/c", type: nil)
        passWindow()
        let events = await sent(relaunched)
        XCTAssertFalse(exists(optOutFile))
        XCTAssertEqual(events.dropFirst(2).map(\.route), ["/c"])
        let resumed = try XCTUnwrap(events.last)
        XCTAssertEqual(resumed.landing, 1, "a new visit")
        XCTAssertEqual(resumed.seq, 1)
        XCTAssertNotEqual(resumed.session, firstSession, "and a new session")
    }

    func testTheOptOutFlagIsOnDiskWhenOptOutReturns() async throws {
        let gate = GateClock(clock)
        let tracker = makeTracker(clock: gate)
        launch(tracker)
        tracker.track("before", props: [:], correlationId: nil)
        tracker.drain()
        XCTAssertTrue(exists(queueFile))
        gate.close()
        defer { gate.open() }
        tracker.screen("/a", type: nil)
        XCTAssertTrue(gate.waitForReader(), "the tracker's queue is held inside screen()")

        tracker.optOut()
        XCTAssertTrue(exists(optOutFile), "written before optOut() returns, on the caller's thread")

        // Killed now: the next launch finds the flag and sends nothing.
        let relaunched = makeTracker()
        relaunched.foreground(at: clock.now(), coldLaunch: true)
        relaunched.screen("/b", type: nil)
        relaunched.track("after", props: [:], correlationId: nil)
        await relaunched.flush()
        scheduler.advance(by: 60)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertTrue(exists(optOutFile))
        XCTAssertFalse(exists(queueFile), "the next launch clears what was queued")

        gate.open()
        tracker.drain()
        await tracker.flush()
        XCTAssertEqual(transport.requestCount, 0, "the held call sends nothing either")
        XCTAssertFalse(exists(queueFile))
    }

    func testOptOutLeavesNoQueueOrSessionFileWhenItReturns() async throws {
        let gate = GateClock(clock)
        let tracker = makeTracker(clock: gate, journey)
        launch(tracker)
        tracker.screen("/", type: nil)
        tracker.track("signup", props: [:], correlationId: nil)
        tracker.drain()
        XCTAssertTrue(exists(queueFile))
        XCTAssertTrue(exists(sessionFile))
        gate.close()
        defer { gate.open() }
        tracker.screen("/a", type: nil)
        XCTAssertTrue(gate.waitForReader(), "the tracker's queue is held inside screen()")

        tracker.optOut()
        XCTAssertTrue(exists(optOutFile))
        XCTAssertFalse(exists(queueFile), "deleted before optOut() returns, on the caller's thread")
        XCTAssertFalse(exists(sessionFile), "deleted before optOut() returns, on the caller's thread")

        gate.open()
        tracker.drain()
        await tracker.flush()
        scheduler.advance(by: 60)
        XCTAssertFalse(exists(queueFile), "the held screen writes nothing")
        XCTAssertFalse(exists(sessionFile))
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testOptOutBeforeTheFirstSendDropsWhatWasQueued() async throws {
        let tracker = makeTracker()
        launch(tracker)
        for i in 0..<9 { tracker.track("e\(i)", props: [:], correlationId: nil) }
        tracker.optOut()
        await tracker.flush()
        scheduler.advance(by: 60)
        tracker.drain()
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertFalse(exists(queueFile))
    }

    // MARK: Threads

    func testEightThreadsLoseNothingAndSeqStaysInOrder() async throws {
        let tracker = makeTracker(journey)
        launch(tracker)
        let calls = 1000
        let clock = self.clock!
        DispatchQueue.concurrentPerform(iterations: 9) { thread in
            if thread == 8 {
                // The app goes to the background and back meanwhile, well inside 30 minutes.
                for _ in 0..<50 {
                    tracker.background(at: clock.now())
                    tracker.foreground(at: clock.now(), coldLaunch: false)
                }
                return
            }
            for i in 0..<calls {
                if i % 2 == 0 {
                    tracker.screen("/t\(thread)/s\(i)", type: nil)
                } else {
                    tracker.track("tap", props: ["n": .number(Double(i))], correlationId: nil)
                }
            }
        }
        let events = await sent(tracker)

        XCTAssertEqual(events.count, 8 * calls, "every event delivered")
        XCTAssertEqual(Set(events.compactMap(\.id)).count, 8 * calls, "each once")
        XCTAssertEqual(Set(events.map(\.session)).count, 1)
        XCTAssertEqual(events.map(\.seq), Array(1...(8 * calls)).map { Optional($0) }, "seq strictly increasing")
        XCTAssertEqual(views(events).count, 4 * calls)
    }

    // MARK: Delivery from the engine

    func testTenEventsSendWithoutWaitingForTheTimer() async throws {
        let tracker = makeTracker()
        launch(tracker)
        for i in 0..<10 { tracker.track("e\(i)", props: [:], correlationId: nil) }
        await transport.waitForRequests(1)
        XCTAssertEqual(transport.sent.count, 10)
        XCTAssertEqual(scheduler.pendingDelays, [])
    }

    func testAnEventQueuedADayAgoIsDroppedNotSent() async throws {
        let tracker = makeTracker(journey)
        launch(tracker)
        tracker.track("signup", props: [:], correlationId: nil)
        tracker.drain()
        elapse(24 * hour)
        await tracker.flush()
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertFalse(exists(queueFile))
    }

    func testTestTrafficMarksTheBatch() async throws {
        let tracker = makeTracker(test: true)
        launch(tracker)
        tracker.screen("/", type: nil)
        await tracker.flush()
        XCTAssertEqual(transport.batches.first?["d"], .number(1))
        XCTAssertEqual(transport.batches.first?["sv"], .string("ios-0.1.0"))
        XCTAssertEqual(transport.batches.first?["k"], .string(key))
    }

    // MARK: Test clock offset

    func testClockOffsetMovesTheClockBackOnlyForTestTraffic() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let offset = makeTracker(test: true) { $0.testClockOffset = -31 * self.minute }
        let ignored = makeTracker(test: false, storage: otherDir) { $0.testClockOffset = -31 * self.minute }
        launch(offset, ignored)
        offset.screen("/", type: nil)
        await offset.flush()
        ignored.screen("/", type: nil)
        let events = await sent(ignored)

        XCTAssertEqual(events.map(\.time), [clock.ms - 31 * 60_000, clock.ms])
        XCTAssertEqual(log.lines.filter { $0.contains("testClockOffset") }.count, 1, "the ignored offset logs one line")
    }

    func testAPositiveOrTooLargeOffsetIsIgnoredWithOneLogLine() async throws {
        for value in [60, -23 * hour - 1, .nan] {
            let log = LogCapture()
            transport = RecordingTransport()
            let tracker = makeTracker(test: true) { $0.testClockOffset = value }
            launch(tracker)
            tracker.screen("/", type: nil)
            let events = await sent(tracker)
            log.stop()
            XCTAssertEqual(events.map(\.time), [clock.ms], "\(value)")
            XCTAssertEqual(log.lines.filter { $0.contains("testClockOffset") }.count, 1, "\(value)")
        }
        transport = RecordingTransport()
        let longest = makeTracker(test: true) { $0.testClockOffset = -23 * self.hour }
        launch(longest)
        longest.screen("/", type: nil)
        let events = await sent(longest)
        XCTAssertEqual(events.map(\.time), [clock.ms - 23 * 3_600_000], "23 hours is allowed")
    }

    func testASessionWrittenUnderTheOffsetStartsANewOneWithoutIt() async throws {
        let offset = makeTracker(test: true) {
            $0.mode = .journey
            $0.testClockOffset = -31 * self.minute
        }
        launch(offset)
        offset.screen("/", type: nil)
        await offset.flush()
        let relaunched = makeTracker(test: true, journey)
        launch(relaunched)
        relaunched.screen("/", type: nil)
        let events = await sent(relaunched)

        XCTAssertEqual(events.count, 2)
        XCTAssertNotEqual(events[1].session, events[0].session)
        XCTAssertEqual(events[1].landing, 1)
        XCTAssertEqual(events[1].seq, 1)
    }

    func testTheOffsetAppliesToTheCallersLifecycleDates() async throws {
        let tracker = makeTracker(test: true) { $0.testClockOffset = -10 * self.minute }
        tracker.foreground(at: clock.now(), coldLaunch: true)
        tracker.screen("/a", type: nil)
        elapse(4)
        tracker.background(at: clock.now())
        let events = await sent(tracker)
        XCTAssertEqual(engages(events).map(\.props), [["ms": .number(4000), "sum": .number(4000)]])
        XCTAssertEqual(engages(events).first?.time, clock.ms - 10 * 60_000)
    }
}
