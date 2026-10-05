import Foundation
import XCTest
@testable import LittleFriend
#if canImport(UIKit)
import UIKit
#endif

/// The static API's engine: the pre-start buffer, the key and app block checks, the app block and
/// the SDK label, test detection and the lifecycle wiring. Each test uses its own `Facade`, never the
/// process-wide one the public functions use.
final class APITests: XCTestCase {
    private let key = "lf_abcdefghijkl0123456789"
    private let minute: TimeInterval = 60
    private let campaignLink = URL(string: "lfshop://open?utm_source=Newsletter&utm_medium=email&utm_campaign=Launch")!

    private var root: URL!
    private var clock: ManualClock!
    private var scheduler: ManualScheduler!
    private var transport: RecordingTransport!
    private var facades: [Facade] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lf-api-\(UUID().uuidString)")
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        transport = RecordingTransport()
    }

    override func tearDown() {
        facades.forEach { $0.tracker?.drain() }
        facades = []
        WrapperBridge.reset()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private var dir: URL { root.appendingPathComponent("littlefriend") }

    private func makeFacade() -> Facade {
        let facade = Facade(clock: clock)
        facades.append(facade)
        return facade
    }

    private func makeEnvironment(
        host: PlatformHost = TestHost(),
        bundleID: String? = "io.littlefriend.lab.shop",
        bundleVersion: String? = "1.2.3",
        sdkSeen: Locked<[String]>? = nil
    ) -> Environment {
        let transport = self.transport!
        return Environment(
            host: host, storage: dir, bundleID: bundleID, bundleVersion: bundleVersion, clock: clock, scheduler: scheduler,
            makeTransport: { _, sdk in
                sdkSeen?.value.append(sdk)
                return transport
            },
            detectTest: { false }
        )
    }

    /// Lets the facade's engine finish the calls made so far, then moves the clock.
    private func elapse(_ facade: Facade, _ seconds: TimeInterval) {
        facade.tracker?.drain()
        clock.advance(seconds)
    }

    private func sent(_ facade: Facade) async -> [RecordingTransport.Sent] {
        await facade.flushed()
        return transport.sent
    }

    /// Waits for a start that finishes on the main thread.
    private func engine(of facade: Facade, timeout: TimeInterval = 5) async -> Tracker? {
        let deadline = Date() + timeout
        while Date() < deadline {
            if let tracker = facade.tracker { return tracker }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    // MARK: Before start

    func testCallsBeforeStartAreReplayedInOrderWithTheTimeOfEachCall() async throws {
        let facade = makeFacade()
        let t0 = clock.ms
        facade.perform(.handle(campaignLink))
        facade.perform(.screen("/a", type: "product"))
        clock.advance(3)
        facade.perform(.track("signup", props: ["plan": .string("pro")], correlationId: nil))
        clock.advance(2)
        facade.perform(.screen("/b", type: nil))
        clock.advance(10)
        facade.start(key: key, options: .init(), environment: makeEnvironment())
        facade.perform(.track("after_start", props: [:], correlationId: nil))
        let events = await sent(facade)

        XCTAssertEqual(events.map(\.name), ["$pageview", "signup", "$engage", "$pageview", "after_start"])
        guard events.count == 5 else { return }
        XCTAssertEqual(events.map(\.time), [t0, t0 + 3000, t0 + 5000, t0 + 5000, t0 + 15000], "each call keeps its own time")
        XCTAssertEqual(events[0].route, "/a")
        XCTAssertEqual(events[0].landing, 1)
        XCTAssertEqual(events[0].campaign?["c"], "launch", "the link made before start is the visit's source")
        XCTAssertEqual(events[0].props, ["page_type": .string("product")])
        XCTAssertEqual(events[2].props, ["ms": .number(5000), "sum": .number(5000)])
        XCTAssertEqual(events[3].route, "/b")
    }

    func testTheHundredAndFirstCallBeforeStartIsDroppedWithOneLogLine() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let facade = makeFacade()
        for i in 0..<103 { facade.perform(.track("e\(i)", props: [:], correlationId: nil)) }
        facade.start(key: key, options: .init(), environment: makeEnvironment())
        facade.perform(.track("after_start", props: [:], correlationId: nil))
        let events = await sent(facade)

        XCTAssertEqual(events.map(\.name), (0..<100).map { "e\($0)" } + ["after_start"])
        XCTAssertEqual(log.lines.filter { $0.contains("before start") }.count, 1, log.lines.joined(separator: "\n"))
    }

    // MARK: Refusals

    func testTheKeyRule() {
        let alnum12 = "abcdefghij12"
        XCTAssertTrue(Facade.validKey("lf_" + alnum12))
        XCTAssertTrue(Facade.validKey("lf_" + String(repeating: "Az9", count: 13) + "x"))
        for bad in [
            "", "lf_", "lf_" + "abcdefghij1", "lf_" + String(repeating: "a", count: 41), "LF_" + alnum12,
            "lfs_" + alnum12, "lf_" + alnum12 + "-", "lf_abcdéfghij12", " lf_" + alnum12, "lf_" + alnum12 + "\n",
        ] {
            XCTAssertFalse(Facade.validKey(bad), bad)
        }
    }

    func testAnInvalidKeySendsNothing() async throws {
        let log = LogCapture()
        defer { log.stop() }
        for bad in ["lf_short", "LF_abcdefghijkl0123", "lfs_abcdefghijkl0123"] {
            let facade = makeFacade()
            facade.perform(.screen("/", type: nil))
            facade.start(key: bad, options: .init(), environment: makeEnvironment())
            facade.perform(.track("signup", props: [:], correlationId: nil))
            facade.perform(.flush)
            await facade.flushed()
            XCTAssertNil(facade.tracker, bad)
        }
        scheduler.advance(by: 60)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "a disabled SDK writes nothing")
        XCTAssertEqual(log.lines.filter { $0.contains("key") }.count, 3, log.lines.joined(separator: "\n"))
        XCTAssertFalse(log.lines.joined().contains("lf_short"), "a log line never holds the key")
    }

    func testAnAppBlockTheContractRefusesSendsNothing() async throws {
        let log = LogCapture()
        defer { log.stop() }
        var refused = LittleFriend.Options()
        refused.appVersion = "jane@example.com"
        let cases: [(LittleFriend.Options, Environment)] = [
            (refused, makeEnvironment()),
            (.init(), makeEnvironment(bundleVersion: "123456789")),
            (.init(), makeEnvironment(bundleID: nil)),
            (.init(), makeEnvironment(bundleID: "shop")),
            (.init(), makeEnvironment(bundleVersion: nil)),
        ]
        for (options, environment) in cases {
            let facade = makeFacade()
            facade.start(key: key, options: options, environment: environment)
            facade.perform(.screen("/", type: nil))
            await facade.flushed()
            XCTAssertNil(facade.tracker)
        }
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(log.lines.filter { $0.contains("app block") }.count, cases.count, log.lines.joined(separator: "\n"))
        XCTAssertFalse(log.lines.joined().contains("jane"), "a log line never holds the value")
    }

    func testAnAppVersionOptionReplacesTheBundleVersion() async throws {
        var options = LittleFriend.Options()
        options.appVersion = "2026.10.5+77"
        let facade = makeFacade()
        facade.start(key: key, options: options, environment: makeEnvironment(bundleVersion: "123456789"))
        facade.perform(.screen("/", type: nil))
        _ = await sent(facade)
        XCTAssertEqual(transport.batches.first?["a"]?.object?["v"], .string("2026.10.5+77"))
    }

    func testASecondStartIsIgnoredWithOneLogLine() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let facade = makeFacade()
        facade.start(key: key, options: .init(), environment: makeEnvironment())
        let first = facade.tracker
        var journey = LittleFriend.Options()
        journey.mode = .journey
        facade.start(key: "lf_zzzzzzzzzzzzzzzz", options: journey, environment: makeEnvironment())
        facade.perform(.screen("/", type: nil))
        _ = await sent(facade)

        XCTAssertTrue(facade.tracker === first)
        XCTAssertEqual(transport.batches.first?["k"], .string(key))
        XCTAssertEqual(transport.batches.first?["m"], .string("a"))
        XCTAssertEqual(log.lines.filter { $0.contains("start") }.count, 1)
    }

    // MARK: App block, label and test traffic

    func testTheAppBlockReadsTheBundle() async throws {
        let live = Environment.live()
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(live.bundleID, bundleID)
        XCTAssertEqual(live.bundleVersion, version)
        #if os(macOS)
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(live.storage, support.appendingPathComponent(bundleID).appendingPathComponent("littlefriend"))
        #endif

        var environment = live
        // The engine's own storage and network, with the live host, bundle and test detection.
        environment.storage = dir
        environment.clock = clock
        environment.scheduler = scheduler
        let transport = self.transport!
        environment.makeTransport = { _, _ in transport }
        let facade = makeFacade()
        facade.start(key: key, options: .init(), environment: environment)
        let tracker = await engine(of: facade)
        XCTAssertNotNil(tracker)
        facade.perform(.screen("/", type: nil))
        _ = await sent(facade)

        let batch = try XCTUnwrap(transport.batches.first)
        #if os(macOS)
        let (platform, device, label) = ("macos", "desktop", "macos-0.1.0")
        #else
        let idiom = await MainActor.run { UIDevice.current.userInterfaceIdiom }
        let (platform, device, label) = ("ios", idiom == .pad ? "tablet" : "mobile", "ios-0.1.0")
        #endif
        XCTAssertEqual(batch["a"]?.object, [
            "i": .string(bundleID), "p": .string(platform), "d": .string(device), "v": .string(version),
        ])
        XCTAssertEqual(batch["sv"], .string(label))
        XCTAssertEqual(batch["d"], .number(1), "test traffic is detected under XCTest")
    }

    func testTestDetectionIsTrueInTheTestRun() {
        XCTAssertTrue(TestDetection.isTestTraffic())
        XCTAssertTrue(TestDetection.isTestTraffic(environment: [:]), "the XCTest runtime is loaded")
    }

    func testTheTestOptionOverridesDetection() async throws {
        var options = LittleFriend.Options()
        options.test = false
        var environment = makeEnvironment()
        environment.detectTest = { true }
        let facade = makeFacade()
        facade.start(key: key, options: options, environment: environment)
        facade.perform(.screen("/", type: nil))
        _ = await sent(facade)
        XCTAssertNil(transport.batches.first?["d"])
    }

    func testAWrapperLabelIsReadWhenTheEngineIsBuilt() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let platformDefault = SDKLabel.platformDefault
        #if os(macOS)
        XCTAssertEqual(platformDefault, "macos-0.1.0")
        #else
        XCTAssertEqual(platformDefault, "ios-0.1.0")
        #endif
        XCTAssertEqual(WrapperBridge.sdkLabel, platformDefault)
        WrapperBridge.sdkLabel = "flutter-0.3.1"
        let seen = Locked<[String]>([])
        let facade = makeFacade()
        facade.start(key: key, options: .init(), environment: makeEnvironment(sdkSeen: seen))
        WrapperBridge.sdkLabel = "react-native-9.9.9"
        facade.perform(.screen("/", type: nil))
        _ = await sent(facade)
        XCTAssertEqual(seen.value, ["flutter-0.3.1"], "the transport's user agent carries the label")
        XCTAssertEqual(transport.batches.first?["sv"], .string("flutter-0.3.1"), "read once, when start builds the engine")

        for bad in ["", "1.0", "flutter 0.3", "flutter-0.3.1\r\nX: y", String(repeating: "a", count: 25)] {
            WrapperBridge.sdkLabel = bad
            XCTAssertEqual(WrapperBridge.resolvedLabel(), platformDefault, bad)
        }
        XCTAssertEqual(log.lines.filter { $0.contains("sdkLabel") }.count, 5)
        XCTAssertFalse(log.lines.joined().contains("flutter 0.3"), "a log line never holds the value")
    }

    // MARK: Lifecycle

    func testTheLifecycleTurnsNotificationsIntoTrackerCalls() async throws {
        let target = RecordingTarget()
        let center = NotificationCenter()
        let lifecycle = Lifecycle(
            target: target, clock: clock, center: center, names: TestHost.names,
            sendInBackground: { $0.background(at: .distantPast) }
        )
        // A start while the app is active, as the host does it.
        lifecycle.becameActive()
        center.post(name: TestHost.names.active, object: nil)
        center.post(name: TestHost.names.background, object: nil)
        center.post(name: TestHost.names.terminate, object: nil)

        XCTAssertEqual(target.calls, [
            "foreground cold", "foreground", "background", "background (sent)", "background", "flush",
        ], "the start counts as the cold launch; termination waits for the flush")
        withExtendedLifetime(lifecycle) {}
    }

    func testTerminationWaitsAtMostTwoSecondsForTheFlush() async throws {
        let target = RecordingTarget(flushDelay: 30)
        let lifecycle = Lifecycle(
            target: target, clock: clock, center: NotificationCenter(), names: TestHost.names, sendInBackground: { _ in }
        )
        let start = Date()
        lifecycle.willTerminate()
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, Lifecycle.terminateWait - 0.05)
        XCTAssertLessThan(waited, Lifecycle.terminateWait + 1)
    }

    func testTheLifecycleDrivesTheEngineFromStart() async throws {
        let host = TestHost(active: true)
        let facade = makeFacade()
        facade.start(key: key, options: .init(), environment: makeEnvironment(host: host))
        facade.perform(.screen("/article", type: "article"))
        elapse(facade, 5)
        host.center.post(name: TestHost.names.background, object: nil)
        await transport.waitForRequests(1)
        XCTAssertEqual(transport.sent.map(\.name), ["$pageview", "$engage"], "the background sends without a flush call")
        XCTAssertEqual(transport.sent.last?.props, ["ms": .number(5000), "sum": .number(5000)])

        elapse(facade, 31 * minute)
        host.center.post(name: TestHost.names.active, object: nil)
        let events = await sent(facade)
        XCTAssertEqual(events.map(\.name), ["$pageview", "$engage", "$pageview"])
        XCTAssertEqual(events.last?.landing, 1, "a return after 30 minutes lands the screen on display")
        XCTAssertEqual(events.last?.props, ["page_type": .string("article")])
    }
}

/// A host for tests: work runs at once, and the lifecycle listens on its own notification center.
final class TestHost: PlatformHost, @unchecked Sendable {
    static let names = Lifecycle.Names(
        active: .init("io.littlefriend.test.active"),
        background: .init("io.littlefriend.test.background"),
        terminate: .init("io.littlefriend.test.terminate")
    )

    let platform = "ios"
    let center = NotificationCenter()
    private let active: Bool

    init(active: Bool = false) {
        self.active = active
    }

    func onMain(_ work: @escaping @Sendable () -> Void) { work() }

    func device() -> String { "mobile" }

    func attach(_ tracker: Tracker, clock: Clock, autoScreens: Bool) -> AnyObject? {
        let lifecycle = Lifecycle(
            target: tracker, clock: clock, center: center, names: Self.names,
            sendInBackground: { target in Task { await target.flush() } }
        )
        if active { lifecycle.becameActive() }
        return lifecycle
    }
}

/// Records the lifecycle's calls in order.
final class RecordingTarget: LifecycleTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let flushDelay: TimeInterval

    init(flushDelay: TimeInterval = 0) {
        self.flushDelay = flushDelay
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: String) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }

    func foreground(at date: Date, coldLaunch: Bool) { record(coldLaunch ? "foreground cold" : "foreground") }

    func background(at date: Date) { record(date == .distantPast ? "background (sent)" : "background") }

    func flush() async {
        if flushDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(flushDelay * 1_000_000_000)) }
        record("flush")
    }
}
