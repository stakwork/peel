import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

// The 2026-10-08 audit of untrusted input (docs/reviews/2026-10-08-audit-input-web-media.md):
// everything a stranger can send or show, fed malformed, huge and adversarial
// values. Randomised inputs come from a fixed seed, so a failure repeats.

/// SplitMix64: a small generator with a seed, so every run sees the same inputs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `count` strings of up to `length` pieces drawn from `alphabet`.
func randomStrings(_ alphabet: [String], count: Int, length: Int, seed: UInt64) -> [String] {
    var generator = SeededGenerator(seed: seed)
    return (0..<count).map { _ in
        (0..<Int.random(in: 0...length, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }.joined()
    }
}

/// Runs `body` and says whether it finished within `limit`. The limits are
/// far above what a linear parse takes even in a debug build, and far
/// below what the quadratic ones took (seconds to tens of seconds).
func finishes(within limit: Duration, _ body: () -> Void) -> Bool {
    let start = ContinuousClock.now
    body()
    return ContinuousClock.now - start < limit
}

/// The pieces markup is made of, and the characters that have broken parsers before.
let markupPieces = [
    "`", "``", "```", "\n", "\r\n", " ", "\t", "@", "@a", "a", "-", "- ", "* ", "• ", "https://a.co/", "https://b.co/`x",
    "\u{00A0}", "\u{0301}", "\u{202E}", "\u{2028}", "é", "😀", "swift", "#",
    "*", "**", "_", "~~", "> ", "1. ", "# ",
]

struct AuditMarkupTests {
    /// Spans as (kind, range offsets), to compare two parses.
    private func shape(_ spans: [MessageMarkup.Span], in text: String) -> [String] {
        spans.map { span in
            let kind = switch span.kind {
            case .code: "code"
            case .link(let url): "link \(url.absoluteString)"
            case .namedLink(let url): "named \(url.absoluteString)"
            case .mention: "mention"
            }
            let start = text.distance(from: text.startIndex, to: span.range.lowerBound)
            return "\(kind) \(start)+\(text[span.range].count) \(span.text)"
        }
    }

    /// The span rules as they were before the audit, written the obvious
    /// (quadratic) way: the reference the linear parse must agree with. Since
    /// markdown, emphasis marks at the end of a link or mention are not its.
    private func referenceSpans(_ text: String) -> [MessageMarkup.Span] {
        let whole = NSRange(text.startIndex..., in: text)
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        func trimmed(_ range: Range<String.Index>) -> Range<String.Index> {
            var shown = text[range]
            while let last = shown.last, "*_~".contains(last) { shown = shown.dropLast() }
            return shown.startIndex..<shown.endIndex
        }
        let links: [MessageMarkup.Span] = detector.matches(in: text, range: whole).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let range = trimmed(found)
            let address = String(text[range])
            guard let again = detector.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)),
                  again.range.length == address.utf16.count,
                  let url = again.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil
            else { return nil }
            return MessageMarkup.Span(kind: .link(url), range: range, text: address)
        }
        let code = try! NSRegularExpression(pattern: #"(?<!`)(`+)([^`\n]+)\1(?!`)"#)
        var codes: [MessageMarkup.Span] = []
        var from = text.startIndex
        while let match = code.firstMatch(in: text, options: .withTransparentBounds, range: NSRange(from..., in: text)),
              let range = Range(match.range, in: text), let inner = Range(match.range(at: 2), in: text) {
            if let link = links.first(where: { $0.range.lowerBound < range.lowerBound && range.lowerBound < $0.range.upperBound }) {
                from = link.range.upperBound
                continue
            }
            codes.append(MessageMarkup.Span(kind: .code, range: range, text: String(text[inner])))
            from = range.upperBound
        }
        var spans = codes + links.filter { link in !codes.contains { $0.range.overlaps(link.range) } }
        let mention = try! NSRegularExpression(pattern: #"\B@[^\s]+"#)
        for match in text.contains("@") ? mention.matches(in: text, range: whole) : [] {
            guard let range = Range(match.range, in: text).map(trimmed), text[range].count > 1,
                  !spans.contains(where: { $0.range.overlaps(range) }) else { continue }
            spans.append(MessageMarkup.Span(kind: .mention, range: range, text: String(text[range])))
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    @Test func spansAgreeWithTheReferenceOnRandomText() {
        for text in randomStrings(markupPieces, count: 3000, length: 24, seed: 1) {
            #expect(shape(MessageMarkup.spans(in: text), in: text) == shape(referenceSpans(text), in: text), "\(text.debugDescription)")
        }
    }

    @Test func randomTextNeverTraps() {
        for text in randomStrings(markupPieces, count: 3000, length: 40, seed: 2) {
            _ = MessageMarkup.blocks(text)
            _ = MessageMarkup.plainText(text)
        }
    }

    /// A message can be long: the core joins up to 65,535 fragments into one.
    /// Each of these took seconds to tens of seconds at 64 KB before the audit.
    /// Each input is built whole (`text(1)`) and at a quarter of its length
    /// (`text(4)`).
    static let adversarial: [(String, @Sendable (_ divisor: Int) -> String)] = [
        ("mentions", { String(repeating: "@a ", count: 21_000 / $0) }),
        ("unclosed fences", { String(repeating: "```x\n", count: 12_800 / $0) }),
        ("links holding backticks", { String(repeating: "https://a.co/` ", count: 4_300 / $0) }),
        ("mentions, code and links", { String(repeating: "@a `b` https://c.co ", count: 3_200 / $0) }),
        ("backticks", { String(repeating: "`", count: 64_000 / $0) }),
        ("item markers", { String(repeating: "- a\n", count: 16_000 / $0) }),
        ("emphasis marks", { String(repeating: "*a _b ~~c ", count: 6_400 / $0) }),
        ("unclosed emphasis", { String(repeating: "**a ", count: 16_000 / $0) }),
        ("nested emphasis", { String(repeating: "*_", count: 16_000 / $0) + "a" + String(repeating: "_*", count: 16_000 / $0) }),
        ("named links", { String(repeating: "[a](https://a.co) ", count: 3_500 / $0) }),
        ("links closing emphasis", { String(repeating: "https://a.co/* ", count: 4_300 / $0) }),
        ("quotes", { String(repeating: "> a\n", count: 16_000 / $0) }),
        ("headings and numbers", { String(repeating: "# a\n1. b\n", count: 6_400 / $0) }),
        ("leading blank lines", { String(repeating: "\n", count: 64_000 / $0) + "a" }),
        ("blank quote lines", { String(repeating: ">\n", count: 32_000 / $0) + "> a" }),
    ]

    /// Parsing four times the text must take about four times as long, not
    /// sixteen (quadratic). Both sizes are timed in the same run, alternately,
    /// keeping the fastest of three, so a slow or busy machine slows both
    /// alike and the ratio measures the parser, not the machine. A machine
    /// busy at background priority can still slow one size more than the
    /// other, so a high ratio is measured again, up to three times: a
    /// quadratic parse is high every time. The cases run one at a time so they
    /// do not load the machine for each other. The floor keeps a quarter-size
    /// parse too quick to time from turning noise into a ratio.
    @Test(.serialized, arguments: adversarial)
    func longAdversarialTextParsesInLinearTime(name: String, text: @Sendable (Int) -> String) {
        let (quarter, whole) = (text(4), text(1))
        func parse(_ input: String) -> Duration {
            ContinuousClock().measure {
                _ = MessageMarkup.spans(in: input)
                _ = MessageMarkup.inlines(input)
                _ = MessageMarkup.blocks(input)
                _ = MessageMarkup.plainText(input)
            }
        }
        func ratio() -> Double {
            var (small, large) = (parse(quarter), parse(whole))
            for _ in 0..<2 {
                small = min(small, parse(quarter))
                large = min(large, parse(whole))
            }
            return large / max(small, .milliseconds(5))
        }
        var ratios = [ratio()]
        while ratios.last! >= 8, ratios.count < 3 { ratios.append(ratio()) }
        #expect(ratios.last! < 8, "\(name): the whole took \(ratios.map { String(format: "%.1f", $0) }) times a quarter")
    }

    @Test func unclosedFencesStayText() {
        #expect(MessageMarkup.blocks("```a\n```b\nc") == [.paragraph("```a\n```b\nc")])
        #expect(MessageMarkup.blocks("```\nx\n```\n```y") == [.code("x"), .paragraph("```y")])
        #expect(MessageMarkup.blocks("```\n```\n```\nq\n```") == [.paragraph("```\n```"), .code("q")])
    }

    @Test func aLinkWithAUserNameIsNoLink() {
        let spans = MessageMarkup.spans(in: "https://google.com@evil.example/x and https://user:pw@a.co/")
        #expect(!spans.contains { if case .link = $0.kind { true } else { false } })
    }
}

struct AuditLinkLabelTests {
    private func label(_ text: String) throws -> String {
        let span = try #require(MessageMarkup.spans(in: text).first)
        guard case .link(let url) = span.kind else { throw PeelError("not a link") }
        return MessageMarkup.linkLabel(span.text, url: url)
    }

    @Test func aLookAlikeHostShowsAsTheAddressNamesIt() throws {
        // A Cyrillic "а" in place of the Latin one.
        #expect(try label("https://\u{0430}pple.com/login") == "xn--pple-43d.com/login")
    }

    @Test func aLongHostIsNeverCut() throws {
        let host = "accounts.google.com.verify-session-and-sign-in.attacker.example"
        let shown = try label("https://\(host)/a/very/long/path/that/goes/on/and/on/for/a/while/yet")
        #expect(shown.hasPrefix(host + "/"))
        #expect(shown.contains("…"))
    }

    @Test func aShortLinkShowsWhole() throws {
        #expect(try label("https://github.com/stakwork/sphinx") == "github.com/stakwork/sphinx")
        #expect(try label("https://a.co:8443/p?q=1#f") == "a.co:8443/p?q=1#f")
    }

    @Test func aLongPathIsShortenedInTheMiddle() throws {
        let shown = try label("https://github.com/stakwork/sphinx-broker/blob/main/docs/notes/0.9.3-reconnect-backoff.md")
        #expect(shown.hasPrefix("github.com/stakwork/"))
        #expect(shown.hasSuffix("-backoff.md"))
        #expect(shown.count <= 57)
    }
}

struct AuditCodeTests {
    /// Fullwidth hex (`０２…`, `ａ`) is refused at the key, not later with a
    /// vaguer error; ASCII hex in either case is a key, and only at full length.
    @Test func fullWidthHexIsNoKey() {
        let fullWidth = String(keyG.map { $0 == "0" ? "\u{FF10}" : $0 })
        #expect(keyG.isPubkey)
        #expect(keyG.uppercased().isPubkey)
        #expect(!fullWidth.isPubkey)
        #expect(!(keyG.dropLast() + "\u{FF41}").isPubkey)
        #expect(!String(keyG.dropLast()).isPubkey)
        #expect(ContactCode.contactInfo("\(fullWidth)_\(key2G)_123") == nil)
        #expect(TribeLink("sphinx.chat://?action=tribeV2&pubkey=\(fullWidth)&host=tribes.sphinx.chat") == nil)
    }

    @Test(arguments: ["\u{FF11}\u{FF12}\u{FF17}.0.0.1", "ｌｏｃａｌｈｏｓｔ", "tribes.sphinx.chat/x", "a@b", "a b", "", "é.com"])
    func aHostIsPlainASCII(host: String) {
        #expect(!TribeLink.isPlainHost(host))
        #expect(TribeLink.baseURL(host) == nil)
        #expect(TribeLink("sphinx.chat://?action=tribeV2&pubkey=\(keyG)&host=\(host)") == nil)
    }

    @Test func plainHostsStillRead() {
        #expect(TribeLink.isPlainHost("tribes.sphinx.chat"))
        #expect(TribeLink.isPlainHost("127.0.0.1:8801"))
        #expect(TribeLink.isPlainHost("xn--pple-43d.com"))
    }

    @Test func aHugePasteIsRefusedBeforeItIsWalked() {
        let huge = String(repeating: " ", count: 5_000_000) + "sphinx.chat://?action=share_contact&pubKey=x"
        #expect(finishes(within: .milliseconds(200)) {
            #expect(throws: (any Error).self) { try ContactCode.read(huge) }
        })
    }

    @Test func randomCodesNeverTrap() {
        let pieces = ["sphinx.chat://", "?", "&", "=", "action", "i", "share_contact", "tribeV2", "pubKey", "pubkey", "host",
                      keyG, key2G, "_", "123", "d=", "%", "%00", "\u{FF10}", "\n", " ", "/", ":", "@", "#"]
        for text in randomStrings(pieces, count: 3000, length: 12, seed: 3) {
            _ = try? ContactCode.read(text)
            _ = TribeLink(text)
        }
    }
}

struct AuditCallLinkTests {
    private let server = "chat.sphinx.chat"

    /// Whatever a call message says, a link Peel reads is on the account's
    /// call server, https, at /rooms/<room>, and rebuilt from its parts.
    @Test func everyLinkReadIsOnTheCallServer() {
        let pieces = ["https://", "http://", "chat.sphinx.chat", "evil.example", "@", ":443", ":80", "/rooms/", "sphinx.call.",
                      "abc", "?", "&", "#", "startAudioOnly=true", "callKey=a", "hiveToken=b", "%2F", "..", "/", "call::",
                      #"{"link":""#, #""}"#, "\\", " ", "\n"]
        for text in randomStrings(pieces, count: 4000, length: 10, seed: 4) {
            guard let link = CallLink(message: text, server: server) else { continue }
            #expect(link.url.scheme == "https", "\(text)")
            #expect(link.url.host == server, "\(text)")
            #expect(link.url.path.hasPrefix("/rooms/sphinx.call."), "\(text)")
            #expect(link.url.user == nil && link.url.fragment == nil, "\(text)")
        }
    }

    @Test func aHugeCallMessageIsNoCall() {
        let link = "https://chat.sphinx.chat/rooms/sphinx.call.abc?callKey=" + String(repeating: "a", count: 5000)
        #expect(CallLink(message: link, server: server) == nil)
        #expect(CallLink.linkText(in: String(repeating: " ", count: 10_000)) == nil)
    }
}

struct AuditTimeZoneTests {
    /// Abbreviations would come out as a city with summer time; nothing else
    /// reaches `TimeZone(identifier:)` unless the system lists it.
    @Test(arguments: [
        "EST", "BST", "CET", "gmt+1", "GMT1", "GMT+", "GMT+:30", "GMT+1:", "GMT+1:5", "GMT+5:3", "GMT+5:60",
        "GMT+15", "GMT+14:01", "GMT+14:30", "GMT+1:30:00", "GMT++1", "GMT+1 ", " GMT+1", "GMT+\u{FF11}", "GMT+١",
        "UTC-99", "", "Foo/Bar", "../../etc/passwd", "/etc/localtime", "Europe/../London", "Europe/London/x",
        "Europe/London\u{0000}", "Europe/" + String(repeating: "x", count: 80), String(repeating: "A/", count: 40),
    ])
    func malformedOffsetsAreNoZone(text: String) {
        #expect(TimeZoneOffset.zone(text) == nil)
    }

    @Test func randomOffsetsNeverTrap() {
        let pieces = ["GMT", "UTC", "+", "-", ":", "0", "1", "4", "9", "/", "Europe", "London", ".", "\u{FF11}", " "]
        for text in randomStrings(pieces, count: 3000, length: 8, seed: 5) {
            if let zone = TimeZoneOffset.zone(text) {
                #expect(abs(zone.secondsFromGMT()) <= 14 * 3600, "\(text)")
            }
        }
    }
}

struct AuditInvoiceTests {
    @Test func aHugeOrGarbledInvoiceIsRefused() {
        #expect(throws: (any Error).self) { try Invoice("lnbc" + String(repeating: "q", count: 10_000)) }
        for text in randomStrings(["ln", "bc", "tb", "1", "q", "p", "z", "lightning:", " ", "\u{FF10}"], count: 300, length: 30, seed: 6) {
            #expect(throws: (any Error).self) { try Invoice(text) }
        }
    }
}

struct AuditMediaTests {
    @Test func randomMediaTokensNeverTrap() {
        let pieces = [".", "bWVtZXMuc3BoaW54LmNoYXQ", "YW10PTEwMA", "-", "_", "=", "abc", "%", "/", "..", "\u{0000}"]
        for text in randomStrings(pieces, count: 3000, length: 10, seed: 7) {
            if let token = MediaToken(text) {
                #expect(!token.muid.isEmpty)
            }
        }
    }

    @Test(arguments: [
        ("attachment; filename=report.pdf", "report.pdf"),
        ("attachment; filename=\"a b.txt\"; size=3", "a b.txt"),
        ("attachment; filename=../../etc/passwd", "passwd"),
        ("attachment; filename=\"../../.ssh/authorized_keys\"", "authorized_keys"),
        ("attachment; filename=..\\..\\evil.exe", "evil.exe"),
        ("attachment; filename=\".zshrc\"", "zshrc"),
        ("attachment; filename=\"invoice\u{202E}fdp.app\"", "invoicefdp.app"),
        ("attachment; filename=\"a:b\"", "ab"),
        ("attachment; filename=\"/\"", nil),
        ("attachment", nil),
        ("inline", nil),
    ] as [(String, String?)])
    func aServersFileNameIsOneSafeName(header: String, name: String?) {
        #expect(MemesServer.fileName(fromDisposition: header) == name)
    }

    @Test func aSavedNameKeepsItsExtensionAndFitsTheFileSystem() {
        let long = UserFiles.cleanName(String(repeating: "ä", count: 300) + ".pdf")
        #expect(long.hasSuffix(".pdf"))
        #expect(long.utf8.count <= UserFiles.maxNameBytes)
        // Shortening never leaves a different extension at the end.
        let trick = UserFiles.cleanName(String(repeating: "x", count: 196) + ".app" + String(repeating: "y", count: 50) + ".pdf")
        #expect(trick.hasSuffix(".pdf"))
        let accents = UserFiles.cleanName("e" + String(repeating: "\u{0301}", count: 400) + ".txt")
        #expect(accents == "file.txt")
        #expect(UserFiles.cleanName(" ..\u{202E}hidden") == "hidden")
        #expect(UserFiles.cleanName("../../etc/passwd") == "-..-etc-passwd")
        #expect(UserFiles.cleanName("\u{0000}\n") == "file")
    }

    @Test func randomSealedBytesNeverDecrypt() throws {
        var generator = SeededGenerator(seed: 8)
        let key = MediaCrypto.newKey()
        let sealed = try! MediaCrypto.encrypt(Data("hello".utf8), key: key)
        for _ in 0..<200 {
            let length = Int.random(in: 0...200, using: &generator)
            var bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            if length > 2 { bytes[0] = 3; bytes[1] = 1 }
            #expect(throws: (any Error).self) { try MediaCrypto.decrypt(bytes, key: key) }
        }
        // Every truncation and every single flipped bit is refused.
        for cut in 0..<sealed.count {
            #expect(throws: (any Error).self) { try MediaCrypto.decrypt(sealed.prefix(cut), key: key) }
        }
        for index in sealed.indices {
            var flipped = sealed
            flipped[index] ^= 0x01
            #expect(throws: MediaCrypto.Failure.self) { try MediaCrypto.decrypt(flipped, key: key) }
        }
        #expect(throws: MediaCrypto.Failure.self) { try MediaCrypto.decrypt(sealed, key: MediaCrypto.newKey()) }
        #expect(throws: (any Error).self) { try MediaCrypto.decrypt(sealed, key: "") }
        #expect(try MediaCrypto.decrypt(sealed, key: key) == Data("hello".utf8))
    }

    @Test func randomBytesAreNoContainerOrImage() {
        var generator = SeededGenerator(seed: 9)
        for _ in 0..<300 {
            let data = Data((0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = AttachmentKind.container(data)
            #expect(AttachmentKind.verified(data, declared: .pdf) == (data.starts(with: Array("%PDF-".utf8)) ? .pdf : .file))
            #expect(AttachmentKind.verified(data, declared: .image) == .file)
        }
        #expect(AttachmentKind.verified(Data([0xFF]), declared: .audio) == .file)
        #expect(AttachmentKind.verified(Data(), declared: .video) == .file)
    }

    @Test func aQRCodeFromGarbageIsRefused() {
        var generator = SeededGenerator(seed: 10)
        for _ in 0..<50 {
            let data = Data((0..<Int.random(in: 0...512, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            #expect(throws: (any Error).self) { try QRImage.codes(in: data) }
        }
        #expect(throws: (any Error).self) { try QRImage.codes(in: Data(count: QRImage.maxBytes + 1)) }
    }
}

struct AuditWebAddressTests {
    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "data:text/html,<script>1</script>", "blob:https://a.co/x",
        "sphinx.chat://?action=i", "mailto:a@b.co", "https://google.com@evil.example/", "https://user:pw@a.co/",
        "https:///nohost", "ftp://a.co/", "about:blank", "x-apple.systempreferences:com.apple",
    ])
    func thePaneOpensOnlyPlainWebAddresses(text: String) {
        #expect(WebPage.address(text) == nil)
    }

    @Test(arguments: [
        "https://\u{FF11}\u{FF12}\u{FF17}.\u{FF10}.\u{FF10}.\u{FF11}/x", "https://ｌｏｃａｌｈｏｓｔ/x", "https://localhost./x",
        "https://127.1/x", "https://2130706433/x", "https://[::1]/x", "https://router.lan/", "https://printer.local/",
    ])
    func aFetchNeverReachesThisMachineOrNetwork(text: String) throws {
        #expect(!Web.isPublic(try #require(URL(string: text))))
    }
}
