@_spi(LittleFriendReplay) import LittleFriend
import Foundation
import XCTest
@testable import LittleFriendReplay

final class CoordinatorTests: XCTestCase {
    private var capture: FakeCaptureDriver!
    private var transport: FakeReplayTransport!
    private var coordinator: ReplayCoordinator!
    private var clock: MutableClock!

    override func setUp() {
        super.setUp()
        capture = FakeCaptureDriver()
        transport = FakeReplayTransport()
        clock = MutableClock()
        let transport = self.transport!
        coordinator = ReplayCoordinator(capture: capture) { _ in transport }
        coordinator.handle(.configuration(makeCore(clock: clock)))
    }

    override func tearDown() {
        coordinator?.stop()
        super.tearDown()
    }

    /// Drives the bridge events a real screen produces, then waits for chunk zero to be sent.
    private func showScreen(
        session: String = "abcdefghijklmnopqrst", route: String = "/home"
    ) async -> Bool {
        let transport = self.transport!
        let before = transport.bodies.count
        coordinator.handle(.session(makeState(session: session, route: route)))
        coordinator.handle(.screen(makeState(session: session, route: route)))
        return await eventually { transport.bodies.count > before }
    }

    func testChunkZeroCarriesMetaAndFullSnapshotUnderTheAnalyticsSession() async {
        let shown = await showScreen()
        XCTAssertTrue(shown)
        XCTAssertEqual(capture.captureCount, 1)
        let first = jsonObject(transport.bodies[0])
        XCTAssertEqual(first["s"] as? String, "abcdefghijklmnopqrst")
        XCTAssertEqual(first["q"] as? Int, 0)
        XCTAssertEqual(first["u"] as? String, "/home")
        XCTAssertEqual((first["p"] as? String)?.count, 20)
        XCTAssertEqual(first["p"] as? String, coordinator.activePageID)
        let events = first["e"] as? [[String: Any]]
        XCTAssertEqual(events?.map { $0["type"] as? Int }, [4, 2])
        XCTAssertEqual(events?.map { $0["timestamp"] as? Int64 }, [testTimestamp, testTimestamp])
    }

    func testTapInsideTargetSealsAsSecondChunk() async {
        let shown = await showScreen()
        XCTAssertTrue(shown)
        coordinator.recordTapAt(x: 30, y: 30)
        coordinator.recordTapAt(x: 300, y: 700)
        coordinator.flush()
        let transport = self.transport!
        let sent = await eventually { transport.bodies.count >= 2 }
        XCTAssertTrue(sent)
        let second = jsonObject(transport.bodies[1])
        XCTAssertEqual(second["q"] as? Int, 1)
        XCTAssertEqual(second["p"] as? String, coordinator.activePageID)
        let events = second["e"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 3)
        let data = events?.map { $0["data"] as? [String: Any] }
        XCTAssertEqual(data?.map { $0?["type"] as? Int }, [7, 9, 2])
        XCTAssertEqual(data?.map { $0?["id"] as? Int }, [42, 42, 42])
        XCTAssertEqual(data?.first??["x"] as? Double, 30)
        XCTAssertEqual(data?.first??["y"] as? Double, 30)
    }

    func testNoCaptureWhenSampledOutOrAggregateOrBackground() async {
        transport.config = ReplayClientConfig(on: true, rate: 0, exclude: [])
        coordinator.handle(.session(makeState()))
        coordinator.handle(.screen(makeState()))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertNil(coordinator.activePageID)

        transport.config = ReplayClientConfig(on: true, rate: 100, exclude: [])
        coordinator.handle(.screen(makeState(session: nil, journey: false)))
        coordinator.handle(.screen(makeState(foreground: false)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(capture.captureCount, 0)
    }

    func testMovingToAnExcludedRouteEndsThePageAndRecordsNothingThere() async {
        transport.config = ReplayClientConfig(on: true, rate: 100, exclude: ["/account"])
        let shown = await showScreen()
        XCTAssertTrue(shown)
        let page = coordinator.activePageID
        XCTAssertNotNil(page)

        coordinator.handle(.screen(makeState(route: "/account/settings")))
        XCTAssertNil(coordinator.activePageID)
        XCTAssertEqual(capture.captureCount, 1)
        coordinator.recordTapAt(x: 30, y: 30)
        coordinator.flush()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.bodies.count, 1)

        coordinator.handle(.screen(makeState(route: "/orders")))
        let transport = self.transport!
        let resumed = await eventually { transport.bodies.count >= 2 }
        XCTAssertTrue(resumed)
        XCTAssertNotEqual(coordinator.activePageID, page)
        XCTAssertEqual(jsonObject(transport.bodies[1])["u"] as? String, "/orders")
    }

    func testSessionRotationStartsANewPageUnderTheNewSession() async {
        let shown = await showScreen()
        XCTAssertTrue(shown)
        let firstPage = coordinator.activePageID

        let rotated = await showScreen(session: "session-1234567890ab", route: "/orders")
        XCTAssertTrue(rotated)
        XCTAssertNotEqual(coordinator.activePageID, firstPage)
        let bodies = transport.bodies.map(jsonObject)
        XCTAssertEqual(bodies.last?["s"] as? String, "session-1234567890ab")
        XCTAssertEqual(bodies.last?["q"] as? Int, 0)
        XCTAssertEqual(bodies.last?["u"] as? String, "/orders")
    }

    func testConsentWithdrawalDiscardsPendingChunksAndThePage() async {
        transport.fallback = .retry(after: nil)
        coordinator.handle(.session(makeState()))
        coordinator.handle(.screen(makeState()))
        let coordinator = self.coordinator!
        let pending = await eventually { coordinator.pendingChunkCount >= 1 }
        XCTAssertTrue(pending)

        coordinator.handle(.session(makeState(session: nil, route: "/home", journey: false)))
        XCTAssertEqual(coordinator.pendingChunkCount, 0)
        XCTAssertNil(coordinator.activePageID)
    }

    func testOptOutSynchronouslyCancelsCaptureAndClearsPendingChunks() async {
        transport.fallback = .retry(after: nil)
        coordinator.handle(.session(makeState()))
        coordinator.handle(.screen(makeState()))
        let coordinator = self.coordinator!
        let pending = await eventually { coordinator.pendingChunkCount >= 1 }
        XCTAssertTrue(pending)
        let cancelsBefore = capture.cancelCount

        coordinator.handle(.optOut)
        // No waiting: core optOut() publishes this on the caller's thread and must not return
        // while replay work or pending chunks survive.
        XCTAssertTrue(coordinator.isOptedOut)
        XCTAssertEqual(coordinator.pendingChunkCount, 0)
        XCTAssertNil(coordinator.activePageID)
        XCTAssertGreaterThan(capture.cancelCount, cancelsBefore)

        coordinator.handle(.optIn(makeState(session: nil, route: nil)))
        transport.fallback = .accepted
        let shown = await showScreen(session: "session-1234567890ab", route: "/back")
        XCTAssertTrue(shown)
        XCTAssertEqual(jsonObject(transport.bodies.last ?? Data())["s"] as? String, "session-1234567890ab")
    }

    func testReplayOffConfigAndTerminalResponseStopRecording() async {
        transport.config = ReplayClientConfig(on: false, rate: 0, exclude: [])
        coordinator.handle(.session(makeState()))
        coordinator.handle(.screen(makeState()))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertNil(coordinator.activePageID)
    }

    func testTapAfterIdleExpiryRecordsNothingAndDropsThePage() async {
        let shown = await showScreen()
        XCTAssertTrue(shown)
        // No analytics activity for 31 minutes: the core session is expired (30 minute idle).
        clock.advance(by: 31 * 60 * 1000)
        coordinator.recordTapAt(x: 30, y: 30)
        coordinator.flush()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertNil(coordinator.activePageID)
    }

    func testTapAfterMaxAgeExpiryRecordsNothing() async {
        // Session started 24h ago, last activity just now: the 24 hour cap still expires it.
        coordinator.handle(.session(makeState(sessionStartedAt: testTimestamp - 24 * 60 * 60 * 1000)))
        coordinator.handle(.screen(makeState(sessionStartedAt: testTimestamp - 24 * 60 * 60 * 1000)))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertNil(coordinator.activePageID)
    }

    func testStaleConfigRefreshesOnForegroundAndNewExclusionStopsThePage() async {
        let shown = await showScreen()
        XCTAssertTrue(shown)
        XCTAssertEqual(transport.loadCount, 1)
        // Within the TTL, foreground does not refetch.
        clock.advance(by: 30_000)
        coordinator.handle(.foreground(makeState(timestamp: clock.now(), sessionLastActivityAt: clock.now())))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.loadCount, 1)
        XCTAssertNotNil(coordinator.activePageID)
        // Past the TTL, foreground revalidates; the route is now excluded, so the page ends.
        transport.config = ReplayClientConfig(on: true, rate: 100, exclude: ["/home"])
        clock.advance(by: 60_000)
        coordinator.handle(.foreground(makeState(timestamp: clock.now(), sessionLastActivityAt: clock.now())))
        let transport = self.transport!
        let refreshed = await eventually { transport.loadCount >= 2 }
        XCTAssertTrue(refreshed)
        let ended = await eventually { self.coordinator.activePageID == nil }
        XCTAssertTrue(ended)
        coordinator.recordTapAt(x: 30, y: 30)
        coordinator.flush()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.bodies.count, 1)
    }

    func testFailedInitialSnapshotRetriesOnForeground() async {
        capture.failNextCaptures = 1
        coordinator.handle(.session(makeState()))
        coordinator.handle(.screen(makeState()))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.bodies.count, 0)
        XCTAssertNil(coordinator.activePageID)
        coordinator.handle(.foreground(makeState()))
        let transport = self.transport!
        let sent = await eventually { transport.bodies.count >= 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(capture.captureCount, 2)
        XCTAssertNotNil(coordinator.activePageID)
    }

    func testCoordinatorRefIsWeakSoStaleTapCallbacksDieWithTheirOwner() {
        let ref = ReplayCoordinatorRef()
        do {
            let transport = FakeReplayTransport()
            let owner = ReplayCoordinator(capture: FakeCaptureDriver()) { _ in transport }
            ref.bind(owner)
            XCTAssertTrue(ref.isBound)
        }
        // The owning coordinator is gone: its driver's callback resolves nothing instead of
        // reaching whatever coordinator a later start() installs.
        XCTAssertFalse(ref.isBound)
        ref.recordTapAt(x: 1, y: 1)
    }

    func testStopDetachesCaptureAndClearsEverything() async {
        let shown = await showScreen()
        XCTAssertTrue(shown)
        coordinator.stop()
        XCTAssertNil(coordinator.activePageID)
        XCTAssertEqual(coordinator.pendingChunkCount, 0)
        XCTAssertEqual(capture.detaches, 1)
        coordinator.handle(.screen(makeState(route: "/again")))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(capture.captureCount, 1)
    }
}
