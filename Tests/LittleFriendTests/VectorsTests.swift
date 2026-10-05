import Foundation
import Testing
@testable import LittleFriend

/// The shared SDK vectors (packages/contract/vectors/sdk.json). Every app SDK must produce
/// these outputs. The install referrer and Android referrer sections are Android only.
struct VectorFile: Decodable {
    struct Route: Decodable { let `in`: String; let out: String? }
    struct Prop: Decodable { let `in`: [String: JSONValue]; let out: [String: JSONValue]? }
    struct Name: Decodable { let `in`: String; let valid: Bool }
    struct Utm: Decodable { let url: String; let extended: Bool; let out: [String: String]? }
    struct App: Decodable { let `in`: JSONValue; let out: [String: String]? }

    let version: Int
    let routes: [Route]
    let props: [Prop]
    let names: [Name]
    let utm: [Utm]
    let apps: [App]

    /// Walks up from this file until a directory holds the contract's vector file.
    static func locate(from file: String = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("packages/contract/vectors/sdk.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func load() throws -> VectorFile {
        let url = try #require(locate(), "packages/contract/vectors/sdk.json not found above \(#filePath)")
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }
}

@Suite struct VectorsTests {
    let vectors: VectorFile

    init() throws {
        vectors = try VectorFile.load()
    }

    @Test func fileIsVersionOneAndEverySectionHasCases() {
        #expect(vectors.version == 1)
        #expect(!vectors.routes.isEmpty)
        #expect(!vectors.props.isEmpty)
        #expect(!vectors.names.isEmpty)
        #expect(!vectors.utm.isEmpty)
        #expect(!vectors.apps.isEmpty)
    }

    @Test func routes() {
        for c in vectors.routes {
            let got = Routes.clean(c.in)
            #expect(got == c.out, "routes: input \(JSONValue.string(c.in).label) gave \(got.map { JSONValue.string($0).label } ?? "null"), want \(c.out.map { JSONValue.string($0).label } ?? "null")")
        }
    }

    @Test func props() {
        for c in vectors.props {
            // Values the Swift type cannot hold (arrays, objects, null) are dropped by the type itself,
            // exactly as cleanProps drops them without counting them toward the 8.
            var input: [String: PropValue] = [:]
            for (key, value) in c.in {
                switch value {
                case let .string(s): input[key] = .string(s)
                case let .number(d): input[key] = .number(d)
                case let .bool(b): input[key] = .bool(b)
                default: break
                }
            }
            let want: [String: PropValue]? = c.out.map { out in
                out.compactMapValues { v -> PropValue? in
                    switch v {
                    case let .string(s): return .string(s)
                    case let .number(d): return .number(d)
                    case let .bool(b): return .bool(b)
                    default: return nil
                    }
                }
            }
            let got = Props.clean(input)
            #expect(got == want, "props: input \(JSONValue.object(c.in).label) gave \(String(describing: got)), want \(String(describing: want))")
        }
    }

    @Test func names() {
        for c in vectors.names {
            #expect(Names.valid(c.in) == c.valid, "names: input \(JSONValue.string(c.in).label) want valid \(c.valid)")
        }
    }

    @Test func utm() {
        for c in vectors.utm {
            let want = c.out.map {
                Campaign(s: $0["s"], m: $0["m"], c: $0["c"], t: $0["t"], n: $0["n"])
            }
            let got = CampaignRules.fromURL(c.url, extended: c.extended)
            #expect(got == want, "utm: input \(JSONValue.string(c.url).label) extended \(c.extended) gave \(String(describing: got)), want \(String(describing: want))")
        }
    }

    @Test func apps() {
        for c in vectors.apps {
            guard let fields = c.in.object,
                  let id = fields["i"]?.string, let platform = fields["p"]?.string,
                  let device = fields["d"]?.string, let version = fields["v"]?.string
            else {
                // Not an object of four strings: the Swift API cannot express it, and the contract refuses it.
                #expect(c.out == nil, "apps: input \(c.in.label) is not an object of strings, want out null")
                continue
            }
            let got = AppRules.valid(id: id, platform: platform, device: device, version: version)
            #expect(got == (c.out != nil), "apps: input \(c.in.label) gave valid \(got), want \(c.out != nil)")
            if let out = c.out {
                #expect(out["id"] == id.lowercased(), "apps: input \(c.in.label) stores its id lowercased")
            }
        }
    }
}
