@_spi(LittleFriendReplay) import LittleFriend
import Foundation

let replayVersion = "0.1.0"
let replayRecorderLabel = "ios-replay-\(replayVersion)"

enum ReplayWire {
    static let firstNativeNodeID = 10

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func document(children: [ReplayNode], viewportHeight: Double) -> ReplayNode {
        let css = "html,body{margin:0}body{font:14px/1.3 -apple-system,BlinkMacSystemFont,sans-serif}.lf-n{position:absolute;box-sizing:border-box;overflow:hidden;margin:0}.lf-t{color:#111827;white-space:pre-wrap}.lf-b{border:1px solid #d1d5db;background:#f3f4f6}.lf-i{background:#e5e7eb}"
        let head = ReplayNode(
            type: 2, id: 4, tagName: "head", attributes: [:], childNodes: [
                ReplayNode(type: 2, id: 7, tagName: "meta", attributes: ["charset": "utf-8"], childNodes: []),
                ReplayNode(type: 2, id: 8, tagName: "style", attributes: [:], childNodes: [
                    ReplayNode(type: 3, id: 9, textContent: css, isStyle: true),
                ]),
            ]
        )
        let main = ReplayNode(
            type: 2, id: 6, tagName: "main",
            attributes: ["style": "position:relative;height:\(ReplayWireNumber.string(viewportHeight))px;overflow:hidden"],
            childNodes: children
        )
        let body = ReplayNode(type: 2, id: 5, tagName: "body", attributes: [:], childNodes: [main])
        let html = ReplayNode(type: 2, id: 3, tagName: "html", attributes: ["lang": "en"], childNodes: [head, body])
        return ReplayNode(type: 0, id: 1, childNodes: [
            ReplayNode(type: 1, id: 2, name: "html", publicId: "", systemId: ""),
            html,
        ])
    }
}

enum ReplayWireNumber {
    static func string(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded(.down) { return String(Int64(rounded)) }
        return String(rounded)
    }
}

struct ReplayWireApp: Encodable, Sendable, Equatable {
    let i: String
    let p: String
    let d: String
    let v: String

    init(_ app: ReplayBridgeApp) {
        i = app.i
        p = app.p
        d = app.d
        v = app.v
    }
}

struct ReplayWireChunk: Encodable, Sendable {
    let v = 1
    let k: String
    let s: String
    let p: String
    let q: Int
    let sv: String
    let u: String
    let d: Int?
    let a: ReplayWireApp
    let e: [ReplayEvent]
}

struct ReplayNode: Encodable, Sendable, Equatable {
    let type: Int
    let id: Int
    let tagName: String?
    let attributes: [String: String]?
    let childNodes: [ReplayNode]?
    let textContent: String?
    let isStyle: Bool?
    let name: String?
    let publicId: String?
    let systemId: String?

    init(
        type: Int, id: Int, tagName: String? = nil, attributes: [String: String]? = nil,
        childNodes: [ReplayNode]? = nil, textContent: String? = nil, isStyle: Bool? = nil,
        name: String? = nil, publicId: String? = nil, systemId: String? = nil
    ) {
        self.type = type
        self.id = id
        self.tagName = tagName
        self.attributes = attributes
        self.childNodes = childNodes
        self.textContent = textContent
        self.isStyle = isStyle
        self.name = name
        self.publicId = publicId
        self.systemId = systemId
    }
}

struct ReplayMetaData: Encodable, Sendable, Equatable {
    let href: String
    let width: Double
    let height: Double
}

struct ReplayOffset: Encodable, Sendable, Equatable {
    let left: Double
    let top: Double
}

struct ReplayFullSnapshotData: Encodable, Sendable, Equatable {
    let node: ReplayNode
    let initialOffset: ReplayOffset
}

struct ReplayTouchData: Encodable, Sendable, Equatable {
    let source = 2
    let type: Int
    let id: Int
    let x: Double
    let y: Double
    let pointerType = 2
}

enum ReplayEvent: Encodable, Sendable, Equatable {
    case meta(timestamp: Int64, data: ReplayMetaData)
    case fullSnapshot(timestamp: Int64, data: ReplayFullSnapshotData)
    case touch(timestamp: Int64, data: ReplayTouchData)

    var timestamp: Int64 {
        switch self {
        case let .meta(timestamp, _), let .fullSnapshot(timestamp, _), let .touch(timestamp, _): return timestamp
        }
    }

    var isFullSnapshot: Bool {
        if case .fullSnapshot = self { return true }
        return false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .meta(timestamp, data):
            try container.encode(4, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(data, forKey: .data)
        case let .fullSnapshot(timestamp, data):
            try container.encode(2, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(data, forKey: .data)
        case let .touch(timestamp, data):
            try container.encode(3, forKey: .type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(data, forKey: .data)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, timestamp, data }

    static func taps(at timestamp: Int64, x: Double, y: Double, id: Int) -> [ReplayEvent] {
        [7, 9, 2].map {
            .touch(timestamp: timestamp, data: ReplayTouchData(type: $0, id: id, x: x, y: y))
        }
    }
}
