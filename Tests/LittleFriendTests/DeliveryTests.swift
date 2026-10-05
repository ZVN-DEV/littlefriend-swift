import Foundation
import XCTest
@testable import LittleFriend

/// The file queue, the batcher and the HTTP transport against a stub collector. Time moves only
/// through the manual clock and scheduler; no test sleeps.
final class DeliveryTests: XCTestCase {
    private let key = "lf_abcdefghijkl0123456789"
    private let app = AppInfo(i: "io.littlefriend.lab.shop", p: "ios", d: "mobile", v: "1.2.3")
    private let sdk = "ios-0.1.0"
    private let sessionA = "abcdefghij0123456789"
    private let sessionB = "zyxwvutsrq9876543210"

    private var root: URL!
    private var dir: URL!
    private var clock: ManualClock!
    private var scheduler: ManualScheduler!
    private var stub: StubServer!
    private var batchers: [Batcher] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lf-\(UUID().uuidString)")
        dir = root.appendingPathComponent("littlefriend")
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        stub = StubServer()
    }

    override func tearDown() {
        batchers.forEach { $0.stop() }
        batchers = []
        stub.close()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private var file: URL { dir.appendingPathComponent("queue.jsonl") }

    private func makeQueue() -> EventQueue { EventQueue(directory: dir, clock: clock) }

    private func makeTransport() -> URLSessionTransport {
        URLSessionTransport(endpoint: stub.endpoint, sdk: sdk, configuration: stub.configuration())
    }

    private func makeBatcher(_ queue: EventQueue, test: Bool = false) -> Batcher {
        let batcher = Batcher(
            queue: queue, transport: makeTransport(), key: key, app: app, sdk: sdk, test: test, scheduler: scheduler
        )
        batchers.append(batcher)
        return batcher
    }

    private func event(
        _ seq: Int, mode: String = "a", session: String? = nil, t: Int64? = nil, props: [String: PropValue]? = nil
    ) -> QueuedEvent {
        QueuedEvent(
            event: WireEvent(i: WireEvent.newID(), n: "$pageview", t: t ?? clock.ms, q: seq, u: "/products/:id", p: props),
            mode: mode,
            session: session
        )
    }

    private func ids(_ events: some Sequence<QueuedEvent>) -> [String] { events.map(\.event.i) }

    /// Starts a flush that the test finishes with `finished(_:)`.
    private func startFlush(_ batcher: Batcher) -> Task<Void, Never> {
        Task { await batcher.flushNow() }
    }

    /// Waits for a flush to return, failing the test after 5 seconds instead of hanging it.
    private func finished(_ flush: Task<Void, Never>) async {
        let done = expectation(description: "flush returned")
        Task {
            await flush.value
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }

    private func flushAndWait(_ batcher: Batcher) async {
        await finished(startFlush(batcher))
    }

    private func everything(_ queue: EventQueue) -> [QueuedEvent] {
        queue.peekBatch(maxEvents: 10_000, maxBytes: .max)
    }

    /// The item's own backup exclusion flag. The resource value also reads true for anything inside
    /// an excluded directory, so it cannot show that a rewritten file kept its own flag.
    private func ownBackupExclusion(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) > 0
    }

    private func line(_ e: QueuedEvent) throws -> Data {
        try JSONEncoder().encode(e) + Data("\n".utf8)
    }

    // MARK: Batch shape

    func testAggregateBatchMatchesTheContract() async throws {
        let queue = makeQueue()
        let batcher = makeBatcher(queue)
        var e = event(0)
        e.event.c = Campaign(s: "newsletter", m: "email")
        e.event.l = 1
        e.event.p = ["page_type": .string("product"), "price": .number(12.5), "member": .bool(true)]
        batcher.enqueue(e)
        await flushAndWait(batcher)

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://\(stub.host)/v1/e")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.header("User-Agent"), "LittleFriend/ios-0.1.0")
        XCTAssertEqual(request.header("Accept-Language"), "*")
        XCTAssertNil(request.header("Origin"))
        XCTAssertNil(request.header("Cookie"))
        XCTAssertFalse(request.shouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeout, 10)

        let json = request.json
        XCTAssertEqual(Set(json.keys), ["v", "k", "m", "sv", "a", "e"], "aggregate: no s, and no d without test traffic")
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["k"] as? String, key)
        XCTAssertEqual(json["m"] as? String, "a")
        XCTAssertEqual(json["sv"] as? String, "ios-0.1.0")
        XCTAssertEqual(json["a"] as? [String: String], ["i": "io.littlefriend.lab.shop", "p": "ios", "d": "mobile", "v": "1.2.3"])
        let wire = try XCTUnwrap((json["e"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(wire.keys), ["i", "n", "t", "q", "u", "c", "p", "l"])
        XCTAssertEqual(wire["i"] as? String, e.event.i)
        XCTAssertEqual(wire["n"] as? String, "$pageview")
        XCTAssertEqual((wire["t"] as? NSNumber)?.int64Value, clock.ms)
        XCTAssertEqual(wire["q"] as? Int, 0)
        XCTAssertEqual(wire["u"] as? String, "/products/:id")
        XCTAssertEqual(wire["c"] as? [String: String], ["s": "newsletter", "m": "email"])
        XCTAssertEqual(wire["l"] as? Int, 1)
        let props = try XCTUnwrap(wire["p"] as? [String: Any])
        XCTAssertEqual(props["page_type"] as? String, "product")
        XCTAssertEqual(props["price"] as? Double, 12.5)
        XCTAssertEqual(props["member"] as? Bool, true)
        XCTAssertEqual(request.batch?.e, [e.event])
        // Slashes are not escaped, so routes cost their own length in the byte budget.
        XCTAssertTrue(String(decoding: request.body, as: UTF8.self).contains("\"u\":\"/products/:id\""))
        XCTAssertEqual(queue.count, 0)
    }

    func testJourneyTestTrafficBatchCarriesSessionAndTestFlag() async throws {
        let queue = makeQueue()
        let batcher = makeBatcher(queue, test: true)
        batcher.enqueue(event(0, mode: "j", session: sessionA))
        await flushAndWait(batcher)

        let json = try XCTUnwrap(stub.requests.first).json
        XCTAssertEqual(Set(json.keys), ["v", "k", "m", "s", "sv", "d", "a", "e"])
        XCTAssertEqual(json["m"] as? String, "j")
        XCTAssertEqual(json["s"] as? String, sessionA)
        XCTAssertEqual(json["d"] as? Int, 1)
    }

    func testAnAggregateEventNeverCarriesASession() async throws {
        let queue = makeQueue()
        let batcher = makeBatcher(queue)
        queue.append(event(0, mode: "a", session: sessionA))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(sessionA), "not on disk")
        await flushAndWait(batcher)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertNil(request.json["s"])
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains(sessionA), "not on the wire")
    }

    func testTransportSessionKeepsNoCookiesAndNoCache() {
        let config = makeTransport().configuration
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(config.timeoutIntervalForRequest, 10)
    }

    func testEventIDsAreLowercaseUUIDsThatPassTheContract() {
        let all = (0..<1000).map { _ in WireEvent.newID() }
        XCTAssertEqual(Set(all).count, 1000)
        for id in all {
            let u = Array(id.utf8)
            // 32 lowercase hex digits: a UUID v4 without its dashes, inside EVENT_ID_RE's 8 to 32.
            XCTAssertEqual(u.count, 32, id)
            XCTAssertTrue(u.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }, id)
            XCTAssertEqual(u[12], UInt8(ascii: "4"), "version 4: \(id)")
            XCTAssertTrue([UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(u[16]), "variant: \(id)")
        }
    }

    // MARK: Triggers

    func testTenEventsSendAtOnce() async {
        let queue = makeQueue()
        let batcher = makeBatcher(queue)
        let events = (0..<10).map { event($0) }
        events.prefix(9).forEach(batcher.enqueue)
        XCTAssertEqual(scheduler.pendingDelays, [5], "nine events wait for the timer")
        XCTAssertEqual(stub.requests.count, 0)

        batcher.enqueue(events[9])
        let sent = await stub.waitForRequests(1)
        XCTAssertEqual(sent.first?.ids, ids(events))
        XCTAssertEqual(scheduler.pendingDelays, [], "the timer is cancelled")
        await flushAndWait(batcher)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testFiveSecondsAfterTheFirstEventTheTimerSends() async {
        let batcher = makeBatcher(makeQueue())
        let first = event(0)
        batcher.enqueue(first)
        scheduler.advance(by: 2)
        let second = event(1)
        batcher.enqueue(second)
        XCTAssertEqual(scheduler.pendingDelays, [5], "one timer, from the first event")

        scheduler.advance(by: 2.5)
        XCTAssertEqual(scheduler.ranCount, 0)
        XCTAssertEqual(stub.requests.count, 0)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(scheduler.ranCount, 1)
        let sent = await stub.waitForRequests(1)
        XCTAssertEqual(sent.first?.ids, [first.event.i, second.event.i])
    }

    // MARK: Batch limits

    func testFiftyOneEventsSplitIntoTwoBatches() async {
        let queue = makeQueue()
        let events = (0..<51).map { event($0) }
        events.forEach(queue.append)
        await flushAndWait(makeBatcher(queue))

        let sent = stub.requests
        XCTAssertEqual(sent.map(\.ids.count), [50, 1])
        XCTAssertEqual(sent.flatMap(\.ids), ids(events))
        XCTAssertEqual(queue.count, 0)
    }

    func testFifteenThousandBytesSplitBySize() async throws {
        let queue = makeQueue()
        let text = String(repeating: "x", count: 60)
        let props = Dictionary(uniqueKeysWithValues: (0..<8).map { ("prop_\($0)", PropValue.string(text)) })
        let events = (0..<50).map { event($0, props: props) }
        events.forEach(queue.append)
        await flushAndWait(makeBatcher(queue))

        let sent = stub.requests
        XCTAssertGreaterThan(sent.count, 1)
        XCTAssertEqual(sent.flatMap(\.ids), ids(events))
        let encoder = WireJSON.encoder()
        var offset = 0
        for (index, request) in sent.enumerated() {
            XCTAssertLessThanOrEqual(request.body.count, 15_000)
            offset += request.ids.count
            if index < sent.count - 1 {
                // The cut is tight: the next event would have pushed this body past 15,000 bytes.
                let next = try encoder.encode(events[offset].event).count
                XCTAssertGreaterThan(request.body.count + 1 + next, 15_000)
            }
        }
    }

    /// An event whose encoded size is exactly `size` bytes, padded through its route.
    private func event(_ seq: Int, encodedSize size: Int) throws -> QueuedEvent {
        var e = event(seq)
        let encoder = WireJSON.encoder()
        let base = try encoder.encode(e.event).count
        e.event.u += String(repeating: "a", count: size - base)
        XCTAssertEqual(try encoder.encode(e.event).count, size)
        return e
    }

    /// The body size counts the envelope, every event and the commas between them, exactly.
    func testTheByteBudgetIsExact() async throws {
        for spare in [0, 1] {
            stub.close()
            stub = StubServer()
            let queue = makeQueue()
            queue.clear()
            let events = try (0..<20).map { try event($0, encodedSize: 700) }
            let wire = WireBatch(k: key, m: "a", sv: sdk, a: app, e: events.map(\.event))
            let twenty = try WireJSON.encoder().encode(wire).count
            // The 21st event fills the body to exactly 15,000 bytes, comma included, or one byte past.
            let last = try event(20, encodedSize: 15_000 - twenty - 1 + spare)
            (events + [last]).forEach(queue.append)
            await flushAndWait(makeBatcher(queue))

            let sent = stub.requests
            if spare == 0 {
                XCTAssertEqual(sent.map(\.ids.count), [21])
                XCTAssertEqual(sent.first?.body.count, 15_000)
            } else {
                XCTAssertEqual(sent.map(\.ids.count), [20, 1])
                XCTAssertEqual(sent.first?.body.count, twenty)
            }
        }
    }

    func testABatchAlwaysHoldsOneEvent() {
        let queue = makeQueue()
        queue.append(event(0))
        queue.append(event(1))
        XCTAssertEqual(queue.peekBatch(maxEvents: 50, maxBytes: 10).count, 1)
    }

    func testJourneyAndAggregateNeverShareABatch() async {
        let queue = makeQueue()
        let events = [
            event(0, mode: "a"), event(1, mode: "a"),
            event(2, mode: "j", session: sessionA), event(3, mode: "j", session: sessionA),
            event(4, mode: "j", session: sessionB),
            event(5, mode: "a"),
        ]
        events.forEach(queue.append)
        await flushAndWait(makeBatcher(queue))

        let sent = stub.requests
        XCTAssertEqual(sent.map(\.ids), [ids(events[0...1]), ids(events[2...3]), ids(events[4...4]), ids(events[5...5])])
        XCTAssertEqual(sent.map { $0.json["m"] as? String }, ["a", "j", "j", "a"])
        XCTAssertEqual(sent.map { $0.json["s"] as? String }, [nil, sessionA, sessionB, nil])
    }

    // MARK: Retries

    func testA503ThenA202ResendsTheSameIDs() async {
        let queue = makeQueue()
        let events = (0..<3).map { event($0) }
        events.forEach(queue.append)
        stub.reply(.status(503), .status(202))
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)

        _ = await stub.waitForRequests(1)
        let delays = await scheduler.waitForPending()
        XCTAssertEqual(delays, [1])
        scheduler.advance(by: 1)
        let sent = await stub.waitForRequests(2)
        await finished(flush)

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].ids, ids(events))
        XCTAssertEqual(sent[1].ids, ids(events))
        XCTAssertEqual(sent[0].body, sent[1].body)
        XCTAssertEqual(queue.count, 0)
    }

    func testANetworkErrorRetries() async {
        let queue = makeQueue()
        queue.append(event(0))
        stub.reply(.networkError)
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)

        _ = await stub.waitForRequests(1)
        let delays = await scheduler.waitForPending()
        XCTAssertEqual(delays, [1])
        scheduler.advance(by: 1)
        _ = await stub.waitForRequests(2)
        await finished(flush)
        XCTAssertEqual(queue.count, 0)
    }

    func testA400DropsTheBatchWithoutRetrying() async {
        let log = LogCapture()
        defer { log.stop() }
        let queue = makeQueue()
        queue.append(event(0))
        queue.append(event(1))
        stub.reply(.status(400))
        await flushAndWait(makeBatcher(queue))

        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(scheduler.pendingDelays, [])
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(makeQueue().count, 0, "removed from disk")
        XCTAssertEqual(log.lines.filter { $0.contains("400") }.count, 1)
    }

    func testRetryAfterTwoWaitsTwoSeconds() async {
        let queue = makeQueue()
        queue.append(event(0))
        stub.reply(.status(429, headers: ["Retry-After": "2"]))
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)

        _ = await stub.waitForRequests(1)
        let delays = await scheduler.waitForPending()
        XCTAssertEqual(delays, [2])
        scheduler.advance(by: 1.5)
        XCTAssertEqual(scheduler.ranCount, 0)
        XCTAssertEqual(stub.requests.count, 1)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(scheduler.ranCount, 1)
        _ = await stub.waitForRequests(2)
        await finished(flush)
        XCTAssertEqual(queue.count, 0)
    }

    func testThreeRetriesThenTheEventsWaitForTheNextTrigger() async {
        let queue = makeQueue()
        let events = (0..<60).map { event($0) }
        events.forEach(queue.append)
        stub.reply(.status(503), .status(500), .networkError, .status(503))
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)

        var seen: [TimeInterval] = []
        for attempt in 1...3 {
            _ = await stub.waitForRequests(attempt)
            let delays = await scheduler.waitForPending()
            seen += delays
            scheduler.advance(by: delays.first ?? 0)
        }
        _ = await stub.waitForRequests(4)
        await finished(flush)

        XCTAssertEqual(seen, [1, 4, 16])
        XCTAssertEqual(stub.requests.count, 4, "the second batch is not tried after the first fails")
        XCTAssertEqual(Set(stub.requests.map(\.ids)), [ids(events[0..<50])])
        XCTAssertEqual(scheduler.pendingDelays, [], "no timer and no retry after the cycle stops")
        XCTAssertEqual(queue.count, 60, "nothing is dropped for a network or 5xx failure")
        XCTAssertEqual(makeQueue().count, 60, "and nothing is dropped on disk")

        await flushAndWait(batcher)
        XCTAssertEqual(stub.requests.dropFirst(4).flatMap(\.ids), ids(events), "the next trigger sends them, same ids")
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: The collector's time window before sending

    func testAnEventOlderThan23HoursIsDroppedBeforeSending() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let queue = makeQueue()
        let batcher = makeBatcher(queue)
        batcher.enqueue(event(0))
        clock.advance(24 * 60 * 60)
        await flushAndWait(batcher)

        XCTAssertEqual(stub.requests.count, 0, "nothing reaches the transport")
        XCTAssertEqual(queue.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the file is gone with its last event")
        XCTAssertEqual(log.lines.filter { $0.contains("time window") }, ["1 queued event was outside the collector's time window and was dropped before sending"])
    }

    func testAnEventMoreThan10MinutesAheadIsDroppedBeforeSending() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let queue = makeQueue()
        let batcher = makeBatcher(queue)
        batcher.enqueue(event(0))
        batcher.enqueue(event(1))
        // The device clock moves back 11 minutes: the queued events now look 11 minutes ahead.
        clock.advance(-11 * 60)
        await flushAndWait(batcher)

        XCTAssertEqual(stub.requests.count, 0, "nothing reaches the transport")
        XCTAssertEqual(queue.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(log.lines.filter { $0.contains("time window") }.count, 1, "one line for both")
    }

    func testTheWindowIsCheckedBeforeEveryBatchOfACycle() async throws {
        let queue = makeQueue()
        let fresh = (0..<50).map { event($0) }
        // Ten seconds inside the window when the cycle starts, outside it after the retries.
        let edge = event(50, t: clock.ms - EventQueue.maxAgeMs + 10_000)
        (fresh + [edge]).forEach(queue.append)
        stub.reply(.status(503), .status(503), .status(503), .status(202))
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)
        for attempt in 1...3 {
            _ = await stub.waitForRequests(attempt)
            let delays = await scheduler.waitForPending()
            scheduler.advance(by: delays.first ?? 0)
        }
        await finished(flush)

        XCTAssertEqual(stub.requests.map(\.ids), Array(repeating: ids(fresh), count: 4))
        XCTAssertEqual(queue.count, 0, "the edge event aged out during the retries and was never sent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRetryDelaysAreClampedToOneToThirtySeconds() {
        XCTAssertEqual(Batcher.retryDelay(attempt: 0, retryAfter: nil), 1)
        XCTAssertEqual(Batcher.retryDelay(attempt: 1, retryAfter: nil), 4)
        XCTAssertEqual(Batcher.retryDelay(attempt: 2, retryAfter: nil), 16)
        XCTAssertEqual(Batcher.retryDelay(attempt: 0, retryAfter: 2), 2)
        XCTAssertEqual(Batcher.retryDelay(attempt: 2, retryAfter: 0), 1)
        XCTAssertEqual(Batcher.retryDelay(attempt: 0, retryAfter: 120), 30)
    }

    func testStatusesMapToAcceptRetryOrDrop() {
        for status in [200, 202, 204] {
            XCTAssertEqual(URLSessionTransport.result(status: status, retryAfter: nil), .accepted, "\(status)")
        }
        for status in [429, 500, 502, 503, 599] {
            XCTAssertEqual(URLSessionTransport.result(status: status, retryAfter: nil), .retry(after: nil), "\(status)")
        }
        for status in [301, 304, 400, 401, 403, 404, 413, 422] {
            XCTAssertEqual(URLSessionTransport.result(status: status, retryAfter: "5"), .drop(status: status), "\(status)")
        }
        XCTAssertEqual(URLSessionTransport.result(status: 503, retryAfter: "2"), .retry(after: 2))
        XCTAssertEqual(URLSessionTransport.result(status: 429, retryAfter: " 7 "), .retry(after: 7))
        for header in ["Wed, 21 Oct 2026 07:28:00 GMT", "-1", "1.5", "", "two"] {
            XCTAssertEqual(URLSessionTransport.result(status: 503, retryAfter: header), .retry(after: nil), header)
        }
    }

    // MARK: Relaunch and the file

    func testRelaunchAfterACrashMidSendResendsTheRestExactlyOnce() async {
        let queue = makeQueue()
        let events = (0..<60).map { event($0) }
        events.forEach(queue.append)
        stub.reply(.status(202), .hang)
        let crashed = makeBatcher(queue)
        let flush = startFlush(crashed)
        let inFlight = await stub.waitForRequests(2)
        XCTAssertEqual(inFlight.map(\.ids), [ids(events[0..<50]), ids(events[50...])])

        // The app dies here, with the second batch sent and never answered.
        let relaunched = makeQueue()
        XCTAssertEqual(ids(everything(relaunched)), ids(events[50...]))
        await flushAndWait(makeBatcher(relaunched))

        let sent = stub.requests
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[2].ids, ids(events[50...]), "the rest, once, with the same ids")
        XCTAssertEqual(sent[0].ids + sent[2].ids, ids(events), "every event accepted exactly once")
        XCTAssertEqual(relaunched.count, 0)
        XCTAssertEqual(makeQueue().count, 0)
        crashed.stop()
        await finished(flush)
    }

    func testAHalfWrittenLineAndAGarbageLineLoadTheGoodLines() throws {
        let good = [event(0), event(1), event(2)]
        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good[2])) as! [String: Any]
        future["added_later"] = ["x": 1]
        var data = try line(good[0])
        data += Data([0xFF, 0x00, 0xFE]) + Data("not json\n".utf8)
        data += Data("{\"event\":{\"i\":\"abc\"},\"mode\":\"a\"}\n".utf8)
        data += try line(QueuedEvent(event: good[1].event, mode: "x", session: nil))
        data += try line(good[1])
        data += try JSONSerialization.data(withJSONObject: future) + Data("\n".utf8)
        data += try line(event(3)).prefix(40)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: file)

        let queue = makeQueue()
        XCTAssertEqual(ids(everything(queue)), ids(good), "unreadable lines, unknown modes and a cut line are dropped")

        // The next append starts on a line of its own.
        let later = event(4)
        queue.append(later)
        XCTAssertEqual(ids(everything(makeQueue())), ids(good + [later]))
    }

    func testACutLastLineDoesNotSwallowTheNextAppend() throws {
        let good = [event(0), event(1)]
        var data = try line(good[0]) + line(good[1])
        data += try line(event(2)).prefix(25)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: file)

        let queue = makeQueue()
        XCTAssertEqual(ids(everything(queue)), ids(good))
        let later = event(3)
        queue.append(later)
        XCTAssertEqual(ids(everything(makeQueue())), ids(good + [later]))
    }

    func testACompleteLastLineWithoutItsNewlineKeepsTheNextAppendApart() throws {
        let good = [event(0), event(1)]
        let data = try line(good[0]) + line(good[1]).dropLast()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: file)

        let queue = makeQueue()
        XCTAssertEqual(ids(everything(queue)), ids(good))
        let later = event(2)
        queue.append(later)
        XCTAssertEqual(ids(everything(makeQueue())), ids(good + [later]))
    }

    func testAnEntirelyUnreadableFileIsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)
        let queue = makeQueue()
        XCTAssertEqual(queue.count, 0)
        let e = event(0)
        queue.append(e)
        XCTAssertEqual(ids(everything(makeQueue())), [e.event.i])
    }

    func testLoadDropsEventsOlderThan23HoursOrMoreThan10MinutesAhead() {
        let queue = makeQueue()
        let now = clock.ms
        let hour: Int64 = 3_600_000
        let tooOld = event(0, t: now - 23 * hour - 1)
        let oldest = event(1, t: now - 23 * hour)
        let latest = event(2, t: now + 600_000)
        let tooNew = event(3, t: now + 600_001)
        [tooOld, oldest, latest, tooNew].forEach(queue.append)
        XCTAssertEqual(queue.count, 4, "the window applies on load")

        let loaded = makeQueue()
        XCTAssertEqual(ids(everything(loaded)), ids([oldest, latest]))
        XCTAssertEqual(makeQueue().count, 2, "and the file is rewritten without them")
    }

    func testTheQueueKeepsTheNewestThousand() throws {
        let queue = makeQueue()
        let events = (0..<1005).map { event($0) }
        events.forEach(queue.append)
        XCTAssertEqual(queue.count, 1000)
        XCTAssertEqual(ids(everything(queue)), ids(events[5...]))
        XCTAssertEqual(ids(everything(makeQueue())), ids(events[5...]))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1000)
    }

    func testQueueFileLinesHoldEventModeAndSession() throws {
        let queue = makeQueue()
        let journey = event(0, mode: "j", session: sessionA)
        let aggregate = event(1, mode: "a")
        queue.append(journey)
        queue.append(aggregate)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(Set(lines[0].keys), ["event", "mode", "session"])
        XCTAssertEqual(lines[0]["mode"] as? String, "j")
        XCTAssertEqual(lines[0]["session"] as? String, sessionA)
        XCTAssertEqual((lines[0]["event"] as? [String: Any])?["i"] as? String, journey.event.i)
        XCTAssertEqual(Set(lines[1].keys), ["event", "mode"])
    }

    func testClearEmptiesMemoryAndDisk() {
        let queue = makeQueue()
        (0..<3).forEach { queue.append(event($0)) }
        queue.clear()
        XCTAssertEqual(queue.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path) && ((try? Data(contentsOf: file))?.isEmpty == false))
        XCTAssertEqual(makeQueue().count, 0)
    }

    func testTheQueueIsExcludedFromBackup() throws {
        let queue = makeQueue()
        let events = (0..<3).map { event($0) }
        events.forEach(queue.append)
        XCTAssertTrue(ownBackupExclusion(dir))
        XCTAssertTrue(ownBackupExclusion(file))
        queue.remove(ids: [events[0].event.i])
        XCTAssertTrue(ownBackupExclusion(file), "an atomic rewrite replaces the file; the flag is set again")
        var fresh = URL(fileURLWithPath: file.path)
        fresh.removeAllCachedResourceValues()
        XCTAssertEqual(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    // MARK: Stop

    func testStopCancelsTheTimer() {
        let queue = makeQueue()
        let batcher = makeBatcher(queue)
        batcher.enqueue(event(0))
        XCTAssertEqual(scheduler.pendingDelays, [5])
        batcher.stop()
        XCTAssertEqual(scheduler.pendingDelays, [])
        scheduler.advance(by: 60)
        batcher.enqueue(event(1))
        XCTAssertEqual(scheduler.pendingDelays, [])
        XCTAssertEqual(stub.requests.count, 0)
    }

    func testStopCancelsAPendingRetryAndNothingIsSentAfter() async {
        let queue = makeQueue()
        queue.append(event(0))
        stub.reply(.status(503))
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)
        _ = await stub.waitForRequests(1)
        _ = await scheduler.waitForPending()

        batcher.stop()
        await finished(flush)
        XCTAssertEqual(scheduler.pendingDelays, [])
        scheduler.advance(by: 60)
        await flushAndWait(batcher)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(queue.count, 1, "stop leaves the queue to its owner")
    }

    func testStopDuringASendIgnoresTheAnswer() async {
        let queue = makeQueue()
        queue.append(event(0))
        stub.reply(.hang)
        let batcher = makeBatcher(queue)
        let flush = startFlush(batcher)
        _ = await stub.waitForRequests(1)

        batcher.stop()
        await finished(flush)
        scheduler.advance(by: 60)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(scheduler.pendingDelays, [])
    }
}
