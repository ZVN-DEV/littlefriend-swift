import Foundation
import Testing
@testable import LittleFriend

/// Cases the shared vectors do not name. Every expected value was produced by the contract's own
/// functions (sanitizeRoute, looksLikePII, sanitizeCampaignValue, cleanProps, utmFromUrl, parseWireApp).
@Suite struct RulesTests {
    @Test(arguments: [
        // Screen templates as an app passes them.
        ("Settings", "/Settings"),
        ("/orders/:id", "/orders/:id"),
        ("Settings/", "/Settings"),
        ("café/Menu", "/café/Menu"),
        // A combining mark after ? still cuts there, and a leading one is not a slash.
        ("/a?\u{301}b", "/a"),
        ("/\u{301}x", "/\u{301}x"),
        // Decoding: a stray % or a broken or non-UTF-8 escape keeps the raw path.
        ("/100%", "/100%"),
        ("/a%2", "/a%2"),
        ("/%E2%82%AC", "/€"),
        ("/%ED%A0%80", "/%ED%A0%80"),
        ("/%C0%AF", "/%C0%AF"),
        // JavaScript whitespace is not a control character.
        ("/a/\u{A0}", "/a/\u{A0}"),
        ("/x\u{2028}y", "/x\u{2028}y"),
        ("/u/a@b.co", "/u/:redacted"),
        ("/u/a@b.c", "/u/a@b.c"),
        ("/u/@b.com", "/u/@b.com"),
        ("/u/x@.com", "/u/x@.com"),
        ("/p/555 0109", "/p/555 0109"),
        ("/p/555-010-9999", "/p/:redacted"),
        ("/p/1234567\u{A0}89", "/p/:redacted"),
        // Only ASCII digits are digits.
        ("/n/\u{661}\u{662}\u{663}\u{664}\u{665}\u{666}\u{667}\u{668}\u{669}", "/n/\u{661}\u{662}\u{663}\u{664}\u{665}\u{666}\u{667}\u{668}\u{669}"),
        ("/h/ABCDEF0123456789", "/h/:id"),
        ("/h/0123456789012345", "/h/:id"),
        ("/t/abcdefghijklmnopqrs1", "/t/:id"),
        ("/t/abcdefghijklmnopqr1", "/t/abcdefghijklmnopqr1"),
        ("//", "/"),
        ("/a//b", "/a//b"),
        ("/:", "/:"),
        ("#top", "/"),
        ("?x=1", "/"),
        ("/a#b?c", "/a"),
        // The 256 limit counts UTF-16 code units.
        ("/" + String(repeating: "é", count: 255), "/" + String(repeating: "é", count: 255)),
    ])
    func routeKept(input: String, want: String) {
        #expect(Routes.clean(input) == want, "route \(input)")
    }

    @Test(arguments: [
        "/" + String(repeating: "é", count: 256),
        "/" + String(repeating: "\u{1F600}", count: 128),
    ])
    func routeTooLong(input: String) {
        #expect(Routes.clean(input) == nil)
    }

    @Test(arguments: [
        ("jane@example.com", true),
        ("a@b.cd", true),
        ("a@b.c", false),
        ("@b.com", false),
        ("a@.com", false),
        ("a@b.c1", false),
        ("x a@b.com", true),
        ("555 010 9999", true),
        ("12345678", false),
        ("123456789", true),
        ("(555) 010-99", true),
        ("1.2.3.4.5.6.7.8.9", true),
        ("\u{661}\u{662}\u{663}\u{664}\u{665}\u{666}\u{667}\u{668}\u{669}", false),
        ("deadbeefdeadbeef1234567890", false),
        ("1234567890123456", true),
        ("3f2b8c1e-8a4d-4c55-9a53-0b4f3a2c1d9e", false),
        ("a@" + String(repeating: "b", count: 253) + ".com", true),
        ("a@" + String(repeating: "b", count: 252) + ".com", true),
        ("1\u{A0}2\u{A0}3\u{A0}4\u{A0}5\u{A0}6\u{A0}7\u{A0}8\u{A0}9", true),
        ("1\u{2028}2 3 4 5 6 7 8 9", true),
    ])
    func personalData(input: String, want: Bool) {
        #expect(Text.looksLikePII(input) == want, "looksLikePII \(input.prefix(40))")
    }

    @Test(arguments: [
        ("  Spring Sale ", "spring sale"),
        ("\u{A0}X\u{A0}", "x"),
        // NEL is not JavaScript whitespace; the byte order mark is.
        ("\u{85}x", "\u{85}x"),
        ("\u{FEFF}x\u{FEFF}", "x"),
        ("x\u{180E}", "x\u{180E}"),
        ("ÉTÉ", "été"),
        ("İstanbul", "i\u{307}stanbul"),
        // Final sigma, as toLowerCase maps it.
        ("ΟΔΟΣ", "οδος"),
        ("ΟΔΟΣ Α", "οδος α"),
        ("a\u{0}b", "ab"),
        // 64 UTF-16 code units hold 32 emoji.
        (String(repeating: "\u{1F600}", count: 40), String(repeating: "\u{1F600}", count: 32)),
    ])
    func campaignValue(input: String, want: String) {
        #expect(CampaignRules.cleanValue(input) == want)
    }

    /// Final_Sigma as toLowerCase applies it: a cased letter before the sigma and none after it,
    /// Case_Ignorable characters skipped on both sides. The same cases are in the shared vectors.
    static let sigma: [(String, String)] = [
        ("ΕΚΠΤΩΣΕΙΣ.gr", "εκπτωσεισ.gr"),
        ("promo-ΑΘΗΝΑΣ:b", "promo-αθηνασ:b"),
        ("ΝΕΟΣ_ΧΡΟΝΟΣ", "νεος_χρονος"),
        ("g1234Σ", "g1234σ"),
        ("ΟΔΥΣΣΕΥΣ", "οδυσσευς"),
        ("Σ", "σ"),
        ("ΑΣ.", "ας."),
        ("ΑΣ\u{301}Β", "ασ\u{301}β"),
        ("ΑΣ'Σ", "ασ'ς"),
        ("1Σ2", "1σ2"),
        ("ΑΣ-Β", "ας-β"),
        ("ΑΣ:", "ας:"),
        ("ΑΣ ΒΣ", "ας βς"),
        ("Σ.Σ", "σ.ς"),
        ("ΑΣ\u{200D}Β", "ασ\u{200D}β"),
    ]

    @Test(arguments: sigma)
    func finalSigma(input: String, want: String) {
        #expect(CampaignRules.cleanValue(input) == want, "cleanValue \(input.unicodeScalars.map { String($0.value, radix: 16) })")
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(
            CampaignRules.fromURL("https://acme.com/?utm_campaign=\(encoded)", extended: false) == Campaign(c: want),
            "utm_campaign \(input.unicodeScalars.map { String($0.value, radix: 16) })"
        )
    }

    @Test func campaignValueEmptyIsNil() {
        #expect(CampaignRules.cleanValue("") == nil)
        #expect(CampaignRules.cleanValue("   ") == nil)
    }

    @Test(arguments: [
        ("https:///p?utm_source=x", "x"),
        ("https://acme.com:8080/?utm_source=x", "x"),
        ("shop:open?utm_source=x", "x"),
        ("  https://acme.com/?utm_source=x  ", "x"),
        ("https://acme.com/?utm_source=a%2Bb+c", "a+b c"),
        ("https://acme.com/?utm_source=%E2%82%AC", "€"),
        ("https://acme.com/?utm_source=%FF", "\u{FFFD}"),
        ("https://acme.com/?utm_source=100%", "100%"),
        ("https://acme.com/?utm_source=a\tb", "ab"),
        ("https://user:pw@acme.com/?utm_source=x", "x"),
        ("https://[::1]/?utm_source=x", "x"),
        ("https://acme.com/?&&utm_source=x&", "x"),
        ("HTTPS://ACME.COM/?utm_source=X", "x"),
        ("file:///?utm_source=x", "x"),
        ("https://acme.com?utm_source=x", "x"),
        ("https://exa%41mple.com/?utm_source=x", "x"),
        ("shop://ex%ample/?utm_source=x", "x"),
        ("https://%C3%A9.com/?utm_source=x", "x"),
        ("https://ÉX.com/?utm_source=x", "x"),
        ("https://acme.com:/?utm_source=x", "x"),
        ("https://@acme.com/?utm_source=x", "x"),
        ("https://acme.com\\?utm_source=x", "x"),
        ("https:\\\\acme.com/?utm_source=x", "x"),
    ])
    func utmSource(url: String, want: String) {
        #expect(CampaignRules.fromURL(url, extended: false) == Campaign(s: want), "utm \(url)")
    }

    @Test(arguments: [
        "https://?utm_source=x",
        "https://a b.com/?utm_source=x",
        "https://acme.com:99999/?utm_source=x",
        "shop://a b/?utm_source=x",
        "https://acme.com/?utm_source",
        "1shop://x?utm_source=x",
        "sh op://x?utm_source=x",
        "https://acme.com/a?b#c?utm_source=x",
        "https://ex^ample.com/?utm_source=x",
        "shop://ex^ample/?utm_source=x",
        "https://%zz.com/?utm_source=x",
        "https://%FF.com/?utm_source=x",
        "https://%25.com/?utm_source=x",
        "https://a%20b.com/?utm_source=x",
        "https://:80/?utm_source=x",
        "https://acme.com:0x50/?utm_source=x",
        "shop://a:b:c/?utm_source=x",
        "shop://[::1/?utm_source=x",
        "https://[zz]/?utm_source=x",
    ])
    func utmNone(url: String) {
        #expect(CampaignRules.fromURL(url, extended: false) == nil, "utm \(url)")
    }

    @Test func propsKeepTheFirstEightKeysInOrder() {
        let input: [String: PropValue] = Dictionary(uniqueKeysWithValues: "abcdefghi".map {
            (String($0), .number(Double($0.asciiValue! - 96)))
        })
        let want: [String: PropValue] = Dictionary(uniqueKeysWithValues: "abcdefgh".map {
            (String($0), .number(Double($0.asciiValue! - 96)))
        })
        #expect(Props.clean(input) == want)
    }

    @Test func propsDropNonFiniteNumbersAndCutStringsByCodeUnits() {
        #expect(Props.clean(["n": .number(.infinity), "m": .number(.nan), "o": .number(-0.0)]) == ["o": .number(0)])
        #expect(Props.clean(["x": .string("a\u{301}b")]) == ["x": .string("a\u{301}b")])
        let emoji = String(repeating: "\u{1F600}", count: 40)
        #expect(Props.clean(["s": .string(emoji)]) == ["s": .string(String(repeating: "\u{1F600}", count: 32))])
        // A surrogate pair the 64 unit cut would split is left out whole.
        #expect(Props.clean(["s": .string("a" + emoji)]) == ["s": .string("a" + String(repeating: "\u{1F600}", count: 31))])
    }

    @Test(arguments: [
        ("com.acme.shop", "1.0..2", true),
        ("com.acme.shop", "1.0.0+", true),
        ("com.acme.shop", "café", false),
        ("com-acme.shop", "1", true),
        ("_com.acme", "1", false),
        ("com.-acme", "1", true),
    ])
    func appBlock(id: String, version: String, want: Bool) {
        #expect(AppRules.valid(id: id, platform: "ios", device: "mobile", version: version) == want)
    }
}
