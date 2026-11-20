import Foundation

/// What a camera's QR code is called on the scanner's pill: a short form of
/// the text, never the text itself in full. Pure, so it is tested here and
/// the phone's scanner only draws it. What it reads is untrusted; the label
/// says what the code looks like, and acting on it is `accept`'s call.
public struct ScanLabel: Sendable, Equatable {
    /// What the pill's icon shows.
    public enum Kind: Sendable, Equatable {
        case web, peel, invoice, contact, tribe, invite, text
    }

    public let kind: Kind
    public let text: String

    /// Longest a plain-text label runs before its ellipsis.
    static let maxText = 30

    public init(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("peel://"), let url = URL(string: trimmed) {
            if let app = PublicAppLink(peelLink: url) {
                self.init(kind: .peel, text: String(localized: "Open \(Self.bare(app.host)) in Peel", table: "Shared"))
                return
            }
            if BoxLinkOffer(peelLink: url) != nil {
                self.init(kind: .peel, text: String(localized: "Link a box", table: "Shared"))
                return
            }
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"),
           let host = URL(string: trimmed)?.host(), !host.isEmpty {
            self.init(kind: .web, text: Self.bare(host))
            return
        }
        if TribeLink(trimmed) != nil {
            self.init(kind: .tribe, text: String(localized: "Tribe", table: "Shared"))
            return
        }
        if (try? Invoice(trimmed)) != nil {
            self.init(kind: .invoice, text: String(localized: "Lightning invoice", table: "Shared"))
            return
        }
        if let read = try? ContactCode.read(trimmed) {
            switch read {
            case .invite: self.init(kind: .invite, text: String(localized: "Sphinx invite", table: "Shared"))
            case .tribe: self.init(kind: .tribe, text: String(localized: "Tribe", table: "Shared"))
            case .contact: self.init(kind: .contact, text: String(localized: "Contact", table: "Shared"))
            }
            return
        }
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let short = line.count > Self.maxText ? String(line.prefix(Self.maxText)) + "…" : line
        self.init(kind: .text, text: short.isEmpty ? String(localized: "Code", table: "Shared") : short)
    }

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// A host as a person reads it: lower case, no leading "www.".
    static func bare(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
