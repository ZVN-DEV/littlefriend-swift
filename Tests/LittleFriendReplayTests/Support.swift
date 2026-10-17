@_spi(LittleFriendReplay) import LittleFriend
import Foundation
@testable import LittleFriendReplay

let testTimestamp: Int64 = 1_700_000_000_000

func makeCore(test: Bool = false) -> ReplayBridgeConfiguration {
    ReplayBridgeConfiguration(
        key: "lf_abcdefghijkl0123456789",
        app: ReplayBridgeApp(i: "io.littlefriend.lab.shop", p: "ios", d: "mobile", v: "1.2.3"),
        endpoint: URL(string: "https://in.example.test")!,
        sdkLabel: "ios-0.1.0",
        test: test,
        timestamp: { testTimestamp }
    )
}

func makeState(
    session: String? = "abcdefghijklmnopqrst", route: String? = "/home",
    foreground: Bool = true, journey: Bool = true
) -> ReplayBridgeState {
    ReplayBridgeState(
        sessionID: session, route: route, timestamp: testTimestamp,
        foreground: foreground, journey: journey
    )
}

/// A capture that returns one fixed snapshot: Meta of a 390 by 844 viewport and a document with
/// one box, plus a hit target the tap tests press.
final class FakeCaptureDriver: ReplayCaptureDriver, @unchecked Sendable {
    static let target = ReplayHitTarget(nodeID: 42, x: 10, y: 20, width: 100, height: 50)

    private let lock = NSLock()
    private(set) var captures = 0
    private(set) var cancels = 0
    private(set) var detaches = 0

    func capture(
        route: String, timestamp: Int64,
        completion: @escaping @Sendable (ReplayCapturedSnapshot?) -> Void
    ) {
        lock.lock()
        captures += 1
        lock.unlock()
        let box = ReplayNode(
            type: 2, id: Self.target.nodeID, tagName: "div",
            attributes: ["class": "lf-n lf-b", "style": "left:10px;top:20px;width:100px;height:50px"],
            childNodes: []
        )
        completion(ReplayCapturedSnapshot(
            events: [
                .meta(timestamp: timestamp, data: ReplayMetaData(href: route, width: 390, height: 844)),
                .fullSnapshot(timestamp: timestamp, data: ReplayFullSnapshotData(
                    node: ReplayWire.document(children: [box], viewportHeight: 844),
                    initialOffset: ReplayOffset(left: 0, top: 0)
                )),
            ],
            hitTargets: [Self.target]
        ))
    }

    func cancel() {
        lock.lock()
        cancels += 1
        lock.unlock()
    }

    func detach() {
        lock.lock()
        detaches += 1
        lock.unlock()
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captures
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }
}

/// Answers config loads immediately and records every chunk body it is handed.
final class FakeReplayTransport: ReplayTransport, @unchecked Sendable {
    private let lock = NSLock()
    var config: ReplayClientConfig? = ReplayClientConfig(on: true, rate: 100, exclude: [])
    var results: [ReplayTransportResult] = []
    var fallback: ReplayTransportResult = .accepted
    private var bodiesStorage: [Data] = []

    func loadConfig(key: String, appID: String) async -> ReplayClientConfig? {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    func send(_ body: Data) async -> ReplayTransportResult {
        lock.lock()
        bodiesStorage.append(body)
        let result = results.isEmpty ? fallback : results.removeFirst()
        lock.unlock()
        return result
    }

    var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodiesStorage
    }
}

struct ImmediateWaiting: ReplayRetryWaiting {
    func wait(_ delay: TimeInterval) async {}
}

/// Polls until `condition` holds or 5 seconds pass. Returns the last reading.
func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date() + 5
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}
