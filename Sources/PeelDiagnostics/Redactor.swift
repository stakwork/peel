import Foundation

/// Scrubs a crash record: structure stays, every free-text field is run
/// through `redactText`. Best effort by design (docs/diagnostics.md): the
/// rules below catch what Peel knows to look for.
///
/// - `allow`: strings that must survive verbatim (the tribe's name and
///   public key). Swapped for placeholders before the rules run and put back
///   after, so not even a 66-hex public key meets the key rule.
/// - `knownNames`: contact names and aliases, removed case-insensitively.
///   Built from the contact list when redacting, never stored.
public struct Redactor: Sendable {
    public let allow: [String]
    public let knownNames: [String]

    public init(allow: [String] = [], knownNames: [String] = []) {
        self.allow = allow.filter { !$0.isEmpty }
        self.knownNames = knownNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    func redact(_ record: CrashRecord) -> RedactedRecord {
        RedactedRecord(
            id: record.id,
            appIdentifier: identifier(record.appIdentifier),
            appVersion: identifier(record.appVersion),
            osVersion: identifier(record.osVersion),
            osBuild: identifier(record.osBuild),
            machineModel: identifier(record.machineModel),
            timestamp: record.timestamp,
            signal: identifier(record.signal),
            signalCode: identifier(record.signalCode),
            faultAddress: record.faultAddress,
            machException: identifier(record.machException),
            exceptionName: record.exceptionName.map(redactText),
            exceptionReason: record.exceptionReason.map(redactText),
            processName: record.processName.map(redactPath),
            processPath: record.processPath.map(redactPath),
            threads: record.threads.map { thread in
                .init(
                    number: thread.number, crashed: thread.crashed,
                    frames: thread.frames.map {
                        .init(pc: $0.pc, imageName: $0.imageName.map(redactPath), symbol: $0.symbol.map(redactSymbol),
                              offset: $0.offset)
                    },
                    registers: thread.registers.map { .init(name: identifier($0.name) ?? "?", value: $0.value) })
            },
            images: record.images.map {
                .init(name: redactPath($0.name), uuid: identifier($0.uuid), base: $0.base, size: $0.size,
                      arch: identifier($0.arch))
            },
            events: record.events,
            strutStderrTail: record.strutStderrTail.map(redactText))
    }

    // MARK: Text

    /// A free-text field: paths, money, keys, device names, contact names,
    /// quoted text and labelled text all go; the allowed strings stay.
    public func redactText(_ text: String) -> String {
        let (swapped, swaps) = swapAllowed(in: text)
        var text = swapped
        func apply(_ rules: [Rule]) {
            for rule in rules { text = rule.apply(to: text, swaps: swaps) }
        }
        apply(Self.quoted + Self.labelled)
        text = redactPath(text)
        apply(Self.money + Self.device + Self.keys)
        text = removeNames(from: text)
        for (token, original) in swaps { text = text.replacingOccurrences(of: token, with: original) }
        return text
    }

    /// A code symbol: only a home path in it goes, so mangled names
    /// (`$s4Peel…`) and `Module.Type.method` read as they are.
    func redactSymbol(_ symbol: String) -> String {
        String(redactPath(symbol).prefix(512))
    }

    /// A path: the home folder and the app container's id become `~`.
    func redactPath(_ text: String) -> String {
        var text = text
        for rule in Self.paths { text = rule.apply(to: text, swaps: []) }
        return text
    }

    /// Fields that are identifiers by nature (versions, model, signal name,
    /// uuid, register name): kept only in that alphabet and length.
    private func identifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet(charactersIn: ".,_-+").union(.alphanumerics)
        guard value.count <= 64, value.unicodeScalars.allSatisfy(allowed.contains) else { return "[removed]" }
        return value
    }

    // MARK: Allowed strings

    private func swapAllowed(in text: String) -> (String, [(String, String)]) {
        var text = text
        var swaps: [(String, String)] = []
        for (index, item) in allow.sorted(by: { $0.count > $1.count }).enumerated() {
            let token = "\u{27E6}P\(index)\u{27E7}"
            let found = text.range(of: item, options: .caseInsensitive)
            guard found != nil else { continue }
            // Put back as written in the allowed list, whatever the text's case.
            text = text.replacingOccurrences(of: item, with: token, options: .caseInsensitive)
            swaps.append((token, item))
        }
        return (text, swaps)
    }

    private func removeNames(from text: String) -> String {
        var text = text
        for name in knownNames.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let expression = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
            else { continue }
            text = expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[contact]")
        }
        return text
    }

    // MARK: Rules

    struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let replacement: String
        /// Leave a match alone when all that is in it, besides the label, is allowed text.
        var keepsAllowed = false

        init(_ pattern: String, _ replacement: String, options: NSRegularExpression.Options = [], keepsAllowed: Bool = false) {
            // Patterns are literals in this file; a bad one is a bug the tests meet.
            expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.replacement = replacement
            self.keepsAllowed = keepsAllowed
        }

        func apply(to text: String, swaps: [(String, String)]) -> String {
            let source = text as NSString
            var out = ""
            var last = 0
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                out += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let matched = source.substring(with: match.range)
                if keepsAllowed, swaps.contains(where: { matched.contains($0.0) }),
                   Self.onlyAllowed(matched, swaps: swaps) {
                    out += matched
                } else {
                    out += expression.replacementString(for: match, in: text, offset: 0, template: replacement)
                }
                last = match.range.location + match.range.length
            }
            out += source.substring(from: last)
            return out
        }

        /// Whether `text` is just placeholders, quotes, a label and spacing.
        static func onlyAllowed(_ text: String, swaps: [(String, String)]) -> Bool {
            var rest = text
            for (token, _) in swaps { rest = rest.replacingOccurrences(of: token, with: "") }
            // A label before a colon is not text.
            if let colon = rest.firstIndex(of: ":") { rest = String(rest[rest.index(after: colon)...]) }
            return !rest.contains { $0.isLetter || $0.isNumber }
        }
    }

    private static let quoted: [Rule] = [
        Rule("\"[^\"\\n]{0,400}\"", "[text]", keepsAllowed: true),
        Rule("\u{201C}[^\u{201D}\\n]{0,400}\u{201D}", "[text]", keepsAllowed: true),
        Rule("(?<![\\w])'[^'\\n]{1,200}'(?![\\w])", "[text]", keepsAllowed: true),
    ]

    private static let labelled: [Rule] = [
        Rule("(?i)\\b(message|text|name|alias|content|body)\\s*[:=][^\\n]*", "$1: [text]", keepsAllowed: true),
    ]

    private static let paths: [Rule] = [
        Rule("(?:/private)?/var/mobile/Containers/[^/\\s]+/[^/\\s]+/[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", "~"),
        Rule("(?:/private)?/var/containers/[^/\\s]+/[^/\\s]+/[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}", "~"),
        Rule("(?:/private)?/var/mobile(?=/|\\s|$)", "~"),
        Rule("/Users/[^/\\s\"']+", "~"),
        Rule("/home/[^/\\s\"']+", "~"),
    ]

    private static let money: [Rule] = [
        Rule("\\bln(?:bc|tbs|tb|bcrt|sb)[0-9a-z]{10,}", "[amount]", options: .caseInsensitive),
        Rule("\\b\\d[\\d,._]*\\s?(?:msats?|sats?|satoshis?|btc|usd|eur|gbp)\\b", "[amount]", options: .caseInsensitive),
        Rule("[$\u{20AC}\u{00A3}\u{20BF}]\\s?\\d[\\d,._]*", "[amount]"),
    ]

    private static let keys: [Rule] = [
        // 12 or more lowercase words in a row: a recovery phrase, or prose.
        Rule("\\b(?:[a-z]{3,8}\\s+){11,}[a-z]{3,8}\\b", "[key]"),
        Rule("\\b[xyz]prv[1-9A-HJ-NP-Za-km-z]{20,}", "[key]"),
        Rule("\\bsk[-_][A-Za-z0-9_-]{16,}", "[key]"),
        Rule("\\b(?:bc1|tb1|bcrt1|lnurl1|npub1|nsec1)[a-z0-9]{20,}", "[key]", options: .caseInsensitive),
        Rule("(?<![\\w$])[0-9a-fA-F]{32,}(?![\\w])", "[key]"),
        // Base64 and its URL form, with a digit in it: not a word, not a path.
        Rule("(?<![\\w$+-])(?=[A-Za-z0-9+_-]*\\d)[A-Za-z0-9+_-]{32,}={0,2}", "[key]"),
    ]

    private static let device: [Rule] = [
        Rule("\\bhttps?://\\S+", "[url]", options: .caseInsensitive),
        Rule("\\b[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\\b", "[device]"),
        Rule("\\b[\\w-]+\\.(?:local|lan|home|internal)\\b", "[device]", options: .caseInsensitive),
        Rule("\\b[\\w]+-(?:MacBook|iPhone|iPad|iMac|Mac-mini|Mac-Studio|Mac-Pro)[\\w-]*", "[device]", options: .caseInsensitive),
        Rule("\\b(serial(?:\\s*number)?|udid|imei)\\b\\s*[:=]?\\s*[A-Za-z0-9-]{8,}", "$1 [device]", options: .caseInsensitive),
    ]
}
