import Foundation
import XCTest
@testable import LittleFriend

/// The hand-written JSON: the writer's bytes against JSONEncoder with `.withoutEscapingSlashes`, the
/// encoder the SDK used before, and the reader's refusals. JSONEncoder writes an object's keys in
/// hash order, which changes from process to process; the writer keeps the declared order.
final class JSONTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private var awkward: String {
        var s = ""
        for v in 0..<0x20 { s.unicodeScalars.append(Unicode.Scalar(v)!) }
        return s + "\u{7F}\"\\/ /orders/:id \u{2028}\u{2029} é ü 😀 \u{FEFF}"
    }

    private func text(_ data: Data?) -> String {
        data.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
    }

    /// The same members with the same values, and the same number of bytes: only the key order may differ.
    private func assertSameJSON(_ written: Data?, _ encoded: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let written = try XCTUnwrap(written, file: file, line: line)
        XCTAssertEqual(written.count, encoded.count, text(written), file: file, line: line)
        let a = try JSONSerialization.jsonObject(with: written) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        XCTAssertNotNil(a, file: file, line: line)
        XCTAssertEqual(a, b, text(written), file: file, line: line)
    }

    // MARK: Writer

    func testStringsAndNumbersAreWrittenAsJSONEncoderWritesThem() throws {
        for value in ["", "plain", awkward, String(repeating: "x/", count: 300)] {
            var writer = JSONWriter()
            writer.string(value)
            XCTAssertEqual(text(Data(writer.bytes)), text(try encoder.encode(value)))
        }
        let numbers: [Double] = [
            0, -0.0, 1, -1, 1.5, 0.1, 12.5, 1e15, 1e16, 1e21, 1.2345678901234568e17, 1e-7, 5e-324,
            1.7976931348623157e308, 9007199254740992, 2.5e-5, 0.30000000000000004, -123456.789,
        ]
        for value in numbers {
            var writer = JSONWriter()
            writer.number(value)
            XCTAssertEqual(text(Data(writer.bytes)), text(try encoder.encode(value)), "\(value)")
        }
    }

    func testEveryShapeIsWrittenAsTheSynthesizedEncoderWroteIt() throws {
        let campaign = Campaign(s: "news/letter", m: "email", c: nil, t: "shoes", n: nil)
        let full = WireEvent(
            i: "abcdef0123456789abcdef0123456789", n: "signup", t: 1_790_000_000_123, q: 7, u: "/orders/:id",
            r: "https://partner.example/a/b", c: campaign, p: ["plan": .number(12.5)], l: 1, x: "checkout_7Hq2LmX9pR4t"
        )
        let bare = WireEvent(i: "e1", n: "$pageview", t: 1, q: 0, u: awkward)
        for event in [full, bare] {
            try assertSameJSON(event.json(), encoder.encode(OldEvent(event)))
            let queued = QueuedEvent(event: event, mode: "j", session: "abcdefghij234567abcd", test: true)
            try assertSameJSON(queued.json(), encoder.encode(OldQueued(queued)))
            let aggregate = QueuedEvent(event: event, mode: "a", session: nil)
            try assertSameJSON(aggregate.json(), encoder.encode(OldQueued(aggregate)))
        }
        let app = AppInfo(i: "io.littlefriend.lab.shop", p: "ios", d: "mobile", v: "1.2.3")
        for batch in [
            WireBatch(k: "lf_abcdefghijkl0123456789", m: "j", s: "abcdefghij234567abcd", sv: "ios-0.1.0", d: 1, a: app, e: [full, bare]),
            WireBatch(k: "lf_abcdefghijkl0123456789", m: "a", sv: "ios-0.1.0", a: app, e: []),
        ] {
            try assertSameJSON(batch.json(), encoder.encode(OldBatch(batch)))
        }
        let session = Session(id: "abcdefghij234567abcd", start: 1_790_000_000_000, last: 1_790_000_060_000, seq: 4, entered: false)
        try assertSameJSON(session.json(), encoder.encode(OldSession(session)))
        XCTAssertEqual(
            text(session.json()), #"{"id":"abcdefghij234567abcd","start":1790000000000,"last":1790000060000,"seq":4,"entered":false}"#,
            "in the declared order"
        )
        XCTAssertEqual(
            text(WireBatch(k: "lf_abcdefghijkl0123456789", m: "a", sv: "ios-0.1.0", a: app, e: [bare]).json()),
            #"{"v":1,"k":"lf_abcdefghijkl0123456789","m":"a","sv":"ios-0.1.0","a":{"i":"io.littlefriend.lab.shop","p":"ios","d":"mobile","v":"1.2.3"},"e":["#
                + text(bare.json()) + "]}"
        )
    }

    func testPropsAreWrittenInAscendingKeyOrder() {
        let event = WireEvent(
            i: "e1", n: "signup", t: 1, q: 0, u: "/",
            p: ["zeta": .bool(false), "alpha": .string("a"), "mid": .number(3), "Beta": .number(-0.5)]
        )
        XCTAssertEqual(
            text(event.json()),
            #"{"i":"e1","n":"signup","t":1,"q":0,"u":"/","p":{"Beta":-0.5,"alpha":"a","mid":3,"zeta":false}}"#
        )
    }

    func testANumberThatIsNotFiniteWritesNothing() {
        for value in [Double.nan, .infinity, -.infinity] {
            let event = WireEvent(i: "e1", n: "signup", t: 1, q: 0, u: "/", p: ["n": .number(value)])
            XCTAssertNil(event.json(), "\(value)")
            XCTAssertNil(QueuedEvent(event: event, mode: "a").json())
        }
    }

    // MARK: Reader

    func testAQueueLineReadsBackAsItWasWritten() throws {
        let event = WireEvent(
            i: "abcdef0123456789abcdef0123456789", n: "signup", t: 1_790_000_000_123, q: 7, u: awkward,
            c: Campaign(s: "a", n: "b"), p: ["s": .string(awkward), "n": .number(-12.5), "b": .bool(true), "i": .number(3)],
            l: 1, x: "checkout_7Hq2LmX9pR4t"
        )
        for queued in [
            QueuedEvent(event: event, mode: "j", session: "abcdefghij234567abcd", test: true),
            QueuedEvent(event: WireEvent(i: "e", n: "n", t: -5, q: 0, u: "/"), mode: "a"),
        ] {
            XCTAssertEqual(QueuedEvent(json: try XCTUnwrap(queued.json())), queued)
        }
    }

    func testTheReaderTakesWhatJSONDecoderTook() throws {
        let base = #"{"event":{"i":"e","n":"n","t":T,"q":0,"u":"/"},"mode":"a"}"#
        func read(_ t: String) -> Int64? { QueuedEvent(json: Data(base.replacingOccurrences(of: "T", with: t).utf8))?.event.t }
        XCTAssertEqual(read("1790000000123"), 1_790_000_000_123)
        XCTAssertEqual(read("-0"), 0)
        XCTAssertEqual(read("1.0"), 1, "a whole number written with a fraction")
        XCTAssertEqual(read("1e3"), 1000)
        XCTAssertEqual(read(" 12 "), 12, "with spaces around")
        for refused in ["1.5", "9223372036854775808", "1e30", "01", "-", "1.", ".5", "1e", "+1", "\"1\"", "true", "null", "NaN"] {
            XCTAssertNil(read(refused), refused)
        }

        let escaped = #"{"event":{"i":"A😀\/\"\\\b\f\n\r\t","n":"n","t":1,"q":0,"u":"/"},"mode":"a","later":[1,{"x":null}]}"#
        XCTAssertEqual(QueuedEvent(json: Data(escaped.utf8))?.event.i, "A😀/\"\\\u{8}\u{C}\n\r\t", "escapes, and fields a later version added")

        let nulls = #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/","r":null,"c":null,"p":null,"l":null,"x":null},"mode":"a","session":null,"test":null}"#
        let read = try XCTUnwrap(QueuedEvent(json: Data(nulls.utf8)), "null is the same as missing for an optional field")
        XCTAssertNil(read.event.p)
        XCTAssertNil(read.session)
        XCTAssertFalse(read.test)
    }

    /// A line the writer never produces only has to be refused when its values would be wrong.
    func testTheReaderRefusesWhatJSONDecoderRefused() {
        let good = #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/"},"mode":"a"}"#
        XCTAssertNotNil(QueuedEvent(json: Data(good.utf8)))
        let refused: [String] = [
            #"{"event":{"i":"e","n":"n","t":1,"q":0},"mode":"a"}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/"}}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/"},"mode":"a","test":1}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/"},"mode":"a","session":5}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/","p":{"a":null}},"mode":"a"}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/","p":{"a":[1]}},"mode":"a"}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/","c":{"s":1}},"mode":"a"}"#,
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/","l":"1"},"mode":"a"}"#,
            #"{"event":{"i":"\ud83d","n":"n","t":1,"q":0,"u":"/"},"mode":"a"}"#,
            #"{"event":{"i":"\ude00","n":"n","t":1,"q":0,"u":"/"},"mode":"a"}"#,
            #"{"event":{"i":"\u00G1","n":"n","t":1,"q":0,"u":"/"},"mode":"a"}"#,
            #"{"event":{"i":"\x","n":"n","t":1,"q":0,"u":"/"},"mode":"a"}"#,
            "{\"event\":{\"i\":\"a\tb\",\"n\":\"n\",\"t\":1,\"q\":0,\"u\":\"/\"},\"mode\":\"a\"}",
            good + " x",
            good + good,
            String(good.dropLast()),
            #"{"event":{"i":"e","n":"n","t":1,"q":0,"u":"/"} "mode":"a"}"#,
            #"["event"]"#,
            "",
            String(repeating: "[", count: 40) + String(repeating: "]", count: 40),
        ]
        for line in refused {
            XCTAssertNil(QueuedEvent(json: Data(line.utf8)), line)
        }
        var invalid = Data(good.utf8)
        invalid.insert(0xFF, at: 20)
        XCTAssertNil(QueuedEvent(json: invalid), "bytes that are not UTF-8")
    }

}

// MARK: The shapes as the synthesized Codable wrote them

private struct OldEvent: Encodable {
    var i: String
    var n: String
    var t: Int64
    var q: Int
    var u: String
    var r: String?
    var c: OldCampaign?
    var p: [String: OldProp]?
    var l: Int?
    var x: String?

    init(_ e: WireEvent) {
        (i, n, t, q, u, r, l, x) = (e.i, e.n, e.t, e.q, e.u, e.r, e.l, e.x)
        c = e.c.map(OldCampaign.init)
        p = e.p?.mapValues(OldProp.init)
    }
}

private struct OldProp: Encodable {
    let value: PropValue

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        }
    }
}

private struct OldCampaign: Encodable {
    var s, m, c, t, n: String?

    init(_ campaign: Campaign) {
        (s, m, c, t, n) = (campaign.s, campaign.m, campaign.c, campaign.t, campaign.n)
    }
}

private struct OldQueued: Encodable {
    var event: OldEvent
    var mode: String
    var session: String?
    var test: Bool

    init(_ q: QueuedEvent) {
        (event, mode, session, test) = (OldEvent(q.event), q.mode, q.session, q.test)
    }
}

private struct OldApp: Encodable {
    var i, p, d, v: String

    init(_ a: AppInfo) {
        (i, p, d, v) = (a.i, a.p, a.d, a.v)
    }
}

private struct OldBatch: Encodable {
    var v: Int
    var k: String
    var m: String
    var s: String?
    var sv: String
    var d: Int?
    var a: OldApp?
    var e: [OldEvent]

    init(_ b: WireBatch) {
        (v, k, m, s, sv, d) = (b.v, b.k, b.m, b.s, b.sv, b.d)
        a = b.a.map(OldApp.init)
        e = b.e.map(OldEvent.init)
    }
}

private struct OldSession: Encodable {
    var id: String
    var start: Int64
    var last: Int64
    var seq: Int
    var entered: Bool

    init(_ s: Session) {
        (id, start, last, seq, entered) = (s.id, s.start, s.last, s.seq, s.entered)
    }
}
