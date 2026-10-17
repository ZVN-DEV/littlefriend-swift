import Foundation
import XCTest
@testable import LittleFriendReplay

final class PolicyAndWireTests: XCTestCase {
    // Buckets computed with the web recorder's sampled() (packages/replay/src/journey.ts):
    // abcdefghijklmnopqrst -> 1325, session-1234567890ab -> 7320.
    func testSamplingMatchesTheWebRecorder() {
        XCTAssertFalse(ReplayPolicy.sampled(sessionID: "abcdefghijklmnopqrst", rate: 13))
        XCTAssertTrue(ReplayPolicy.sampled(sessionID: "abcdefghijklmnopqrst", rate: 14))
        XCTAssertFalse(ReplayPolicy.sampled(sessionID: "session-1234567890ab", rate: 73))
        XCTAssertTrue(ReplayPolicy.sampled(sessionID: "session-1234567890ab", rate: 74))
        XCTAssertFalse(ReplayPolicy.sampled(sessionID: "abcdefghijklmnopqrst", rate: 0))
        XCTAssertTrue(ReplayPolicy.sampled(sessionID: "session-1234567890ab", rate: 100))
    }

    func testExcludedRoutesMatchOnSegmentBoundaries() {
        let patterns = ["/account", "/orders/*/pay", "/admin/*"]
        XCTAssertTrue(ReplayPolicy.excluded(route: "/account", patterns: patterns))
        XCTAssertTrue(ReplayPolicy.excluded(route: "/account/settings", patterns: patterns))
        XCTAssertFalse(ReplayPolicy.excluded(route: "/accounting", patterns: patterns))
        XCTAssertTrue(ReplayPolicy.excluded(route: "/orders/abc/pay", patterns: patterns))
        XCTAssertTrue(ReplayPolicy.excluded(route: "/orders/abc/pay/done", patterns: patterns))
        XCTAssertFalse(ReplayPolicy.excluded(route: "/orders/pay", patterns: patterns))
        XCTAssertFalse(ReplayPolicy.excluded(route: "/orders/abc/ship", patterns: patterns))
        XCTAssertTrue(ReplayPolicy.excluded(route: "/admin", patterns: patterns))
        XCTAssertTrue(ReplayPolicy.excluded(route: "/anything/at/all", patterns: ["/"]))
        XCTAssertFalse(ReplayPolicy.excluded(route: "/home", patterns: ["relative", ""]))
    }

    func testMaskKeepsOnlyWhitespaceAndLength() {
        let secret = "Maria Okafor 4111"
        let masked = ReplayPolicy.mask(secret)
        XCTAssertEqual(masked, "█████ ██████ ████")
        XCTAssertFalse(masked.contains("Maria"))
        XCTAssertFalse(masked.contains("4111"))
        XCTAssertEqual(ReplayPolicy.mask(""), "")
        XCTAssertEqual(ReplayPolicy.mask("a\nb\tc"), "█\n█\t█")
    }

    func testConfigParseAcceptsTheCollectorShapeAndRefusesTheRest() {
        let on = Data(#"{"v":1,"on":true,"rate":25,"unmask":[],"block":[],"exclude":["/account"],"version":3}"#.utf8)
        XCTAssertEqual(
            ReplayClientConfig.parse(on),
            ReplayClientConfig(on: true, rate: 25, exclude: ["/account"])
        )
        let off = Data(#"{"v":1,"on":false,"rate":0,"unmask":[],"block":[],"exclude":[],"version":0}"#.utf8)
        XCTAssertEqual(ReplayClientConfig.parse(off)?.on, false)
        XCTAssertNil(ReplayClientConfig.parse(Data(#"{"v":2,"on":true,"rate":1,"exclude":[]}"#.utf8)))
        XCTAssertNil(ReplayClientConfig.parse(Data(#"{"v":1,"on":true,"rate":101,"exclude":[]}"#.utf8)))
        XCTAssertNil(ReplayClientConfig.parse(Data("not json".utf8)))
    }

    func testTransportResultMapping() {
        XCTAssertEqual(ReplayURLSessionTransport.result(status: 202, retryAfter: nil), .accepted)
        XCTAssertEqual(ReplayURLSessionTransport.result(status: 429, retryAfter: "5"), .retry(after: 5))
        XCTAssertEqual(ReplayURLSessionTransport.result(status: 503, retryAfter: nil), .retry(after: nil))
        XCTAssertEqual(ReplayURLSessionTransport.result(status: 402, retryAfter: nil), .terminal(status: 402))
        XCTAssertEqual(ReplayURLSessionTransport.result(status: 400, retryAfter: nil), .terminal(status: 400))
        XCTAssertNil(ReplayURLSessionTransport.seconds("soon"))
        XCTAssertEqual(ReplayURLSessionTransport.seconds(" 30\t"), 30)
    }

    func testChunkEnvelopeCarriesAppBlockAndTestFlagOnlyForTestTraffic() throws {
        let events: [ReplayEvent] = [
            .meta(timestamp: testTimestamp, data: ReplayMetaData(href: "/home", width: 390, height: 844)),
        ]
        let plain = try ReplayChunkFactory.make(
            core: makeCore(), sessionID: "abcdefghijklmnopqrst", pageID: "pagepagepagepagepage",
            sequence: 0, route: "/home", events: events
        )
        let object = jsonObject(plain.body)
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["k"] as? String, "lf_abcdefghijkl0123456789")
        XCTAssertEqual(object["s"] as? String, "abcdefghijklmnopqrst")
        XCTAssertEqual(object["p"] as? String, "pagepagepagepagepage")
        XCTAssertEqual(object["q"] as? Int, 0)
        XCTAssertEqual(object["u"] as? String, "/home")
        XCTAssertEqual(object["sv"] as? String, "ios-replay-0.1.0")
        XCTAssertNil(object["d"])
        XCTAssertNil(object["w"])
        let app = object["a"] as? [String: Any]
        XCTAssertEqual(app?["i"] as? String, "io.littlefriend.lab.shop")
        XCTAssertEqual(app?["p"] as? String, "ios")
        XCTAssertEqual(app?["d"] as? String, "mobile")
        XCTAssertEqual(app?["v"] as? String, "1.2.3")
        let sent = object["e"] as? [[String: Any]]
        XCTAssertEqual(sent?.first?["type"] as? Int, 4)
        let meta = sent?.first?["data"] as? [String: Any]
        XCTAssertEqual(meta?["width"] as? Double, 390)
        XCTAssertEqual(meta?["height"] as? Double, 844)

        let test = try ReplayChunkFactory.make(
            core: makeCore(test: true), sessionID: "abcdefghijklmnopqrst", pageID: "pagepagepagepagepage",
            sequence: 0, route: "/home", events: events
        )
        XCTAssertEqual(jsonObject(test.body)["d"] as? Int, 1)
    }

    func testTapEncodingIsTouchStartTouchEndClickWithPointerTypeTouch() throws {
        let events = ReplayEvent.taps(at: testTimestamp, x: 12.5, y: 40, id: 42)
        XCTAssertEqual(events.count, 3)
        let encoded = try ReplayWire.encoded(events)
        let list = (try? JSONSerialization.jsonObject(with: encoded)) as? [[String: Any]]
        XCTAssertEqual(list?.map { $0["type"] as? Int }, [3, 3, 3])
        let data = list?.map { $0["data"] as? [String: Any] }
        XCTAssertEqual(data?.map { $0?["type"] as? Int }, [7, 9, 2])
        XCTAssertEqual(data?.map { $0?["source"] as? Int }, [2, 2, 2])
        XCTAssertEqual(data?.map { $0?["pointerType"] as? Int }, [2, 2, 2])
        XCTAssertEqual(data?.map { $0?["id"] as? Int }, [42, 42, 42])
        XCTAssertEqual(data?.first??["x"] as? Double, 12.5)
        XCTAssertEqual(data?.first??["y"] as? Double, 40)
    }

    func testPageIDsFitTheSessionIDShape() {
        for _ in 0..<20 {
            let id = ReplayID.make()
            XCTAssertEqual(id.count, 20)
            XCTAssertTrue(id.allSatisfy { $0.isLetter || $0.isNumber })
        }
        XCTAssertNotEqual(ReplayID.make(), ReplayID.make())
    }
}
