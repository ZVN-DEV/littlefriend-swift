import Foundation
import XCTest
@_spi(LittleFriendReplay) @testable import LittleFriend

/// The replay bridge: configuration, screen, session, foreground, consent and the synchronous
/// opt-out, as the add-on observes them. The session id it carries is the analytics session id.
final class BridgeTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private var clock: ManualClock!
    private var scheduler: ManualScheduler!
    private var transport: RecordingTransport!
    private var hub: ReplayBridgeHub!
    private var events: EventLog!
    private var subscription: ReplayBridgeSubscription?
    private var tracker: Tracker?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lf-bridge-\(UUID().uuidString)")
        dir = root.appendingPathComponent("littlefriend")
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        transport = RecordingTransport()
        hub = ReplayBridgeHub()
        events = EventLog()
    }

    override func tearDown() {
        subscription?.cancel()
        tracker?.drain()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeJourneyTracker() -> Tracker {
        var options = LittleFriend.Options()
        options.mode = .journey
        let tracker = Tracker(
            options: options, key: "lf_abcdefghijkl0123456789",
            app: AppInfo(i: "io.littlefriend.lab.shop", p: "ios", d: "mobile", v: "1.2.3"),
            sdk: "ios-0.1.0", test: true, storage: dir,
            clock: clock, transport: transport, scheduler: scheduler, replayObservers: hub
        )
        self.tracker = tracker
        return tracker
    }

    private func passWindow(_ tracker: Tracker) {
        tracker.drain()
        scheduler.advance(by: TimeInterval(Tracker.landingWindowMs) / 1000)
        tracker.drain()
    }

    func testBridgeCarriesConfigurationScreenAndTheAnalyticsSessionID() async {
        let log = events!
        subscription = hub.add { log.add($0) }
        let tracker = makeJourneyTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        passWindow(tracker)
        tracker.screen("/home", type: nil)
        passWindow(tracker)
        await tracker.flush()

        guard case let .configuration(configuration) = log.all.first else {
            return XCTFail("first bridge event is not the configuration: \(log.all)")
        }
        XCTAssertEqual(configuration.key, "lf_abcdefghijkl0123456789")
        XCTAssertEqual(configuration.app.i, "io.littlefriend.lab.shop")
        XCTAssertEqual(configuration.sdkLabel, "ios-0.1.0")
        XCTAssertTrue(configuration.test)

        let screens = log.states(for: "screen")
        XCTAssertEqual(screens.map(\.route), ["/home"])
        let bridgeSession = screens.first?.sessionID
        XCTAssertNotNil(bridgeSession)
        XCTAssertEqual(bridgeSession, transport.sent.first?.session)
        XCTAssertEqual(screens.first?.journey, true)
        XCTAssertEqual(screens.first?.foreground, true)
        XCTAssertFalse(log.states(for: "foreground").isEmpty)
        XCTAssertFalse(log.states(for: "session").isEmpty)
    }

    func testLateObserverReceivesConfigurationAndCurrentScreen() async {
        let tracker = makeJourneyTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        passWindow(tracker)
        tracker.screen("/orders", type: nil)
        passWindow(tracker)
        await tracker.flush()

        let log = events!
        subscription = hub.add { log.add($0) }
        XCTAssertEqual(log.kinds.first, "configuration")
        let screens = log.states(for: "screen")
        XCTAssertEqual(screens.map(\.route), ["/orders"])
        XCTAssertEqual(screens.first?.sessionID, transport.sent.first?.session)
    }

    func testConsentWithdrawalPublishesANilSessionAndAggregateContinues() async {
        let log = events!
        subscription = hub.add { log.add($0) }
        let tracker = makeJourneyTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        passWindow(tracker)
        tracker.screen("/home", type: nil)
        passWindow(tracker)

        tracker.consent(.none)
        tracker.drain()
        let sessions = log.states(for: "session")
        XCTAssertNil(sessions.last?.sessionID)
        XCTAssertEqual(sessions.last?.journey, false)
        XCTAssertFalse(log.states(for: "consent").isEmpty)
    }

    func testOptOutReachesTheObserverBeforeItReturns() async {
        let log = events!
        subscription = hub.add { log.add($0) }
        let tracker = makeJourneyTracker()
        tracker.foreground(at: clock.now(), coldLaunch: true)
        passWindow(tracker)
        tracker.screen("/home", type: nil)
        passWindow(tracker)

        tracker.optOut()
        // No drain: the add-on has already been told, synchronously, so it can cancel capture and
        // clear pending chunks before optOut() returns.
        XCTAssertEqual(log.kinds.last, "optOut")
        tracker.drain()
        tracker.screen("/after", type: nil)
        passWindow(tracker)
        XCTAssertEqual(log.states(for: "screen").map(\.route), ["/home"])

        tracker.optIn()
        tracker.drain()
        XCTAssertTrue(log.kinds.contains("optIn"))
    }

    func testAggregateModeNeverPublishesASessionID() async {
        let log = events!
        subscription = hub.add { log.add($0) }
        var options = LittleFriend.Options()
        options.mode = .aggregate
        let tracker = Tracker(
            options: options, key: "lf_abcdefghijkl0123456789",
            app: AppInfo(i: "io.littlefriend.lab.shop", p: "ios", d: "mobile", v: "1.2.3"),
            sdk: "ios-0.1.0", test: false, storage: dir,
            clock: clock, transport: transport, scheduler: scheduler, replayObservers: hub
        )
        self.tracker = tracker
        tracker.foreground(at: clock.now(), coldLaunch: true)
        passWindow(tracker)
        tracker.screen("/home", type: nil)
        passWindow(tracker)
        await tracker.flush()

        let screens = log.states(for: "screen")
        XCTAssertEqual(screens.map(\.route), ["/home"])
        XCTAssertNil(screens.first?.sessionID)
        XCTAssertEqual(screens.first?.journey, false)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ReplayBridgeEvent] = []

    func add(_ event: ReplayBridgeEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var all: [ReplayBridgeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var kinds: [String] { all.map(Self.kind) }

    func states(for kind: String) -> [ReplayBridgeState] {
        all.compactMap { event in
            guard Self.kind(event) == kind else { return nil }
            switch event {
            case let .screen(state), let .session(state), let .foreground(state),
                 let .background(state), let .consent(state), let .optIn(state):
                return state
            default:
                return nil
            }
        }
    }

    private static func kind(_ event: ReplayBridgeEvent) -> String {
        switch event {
        case .configuration: return "configuration"
        case .screen: return "screen"
        case .session: return "session"
        case .foreground: return "foreground"
        case .background: return "background"
        case .consent: return "consent"
        case .optIn: return "optIn"
        case .optOut: return "optOut"
        }
    }
}
