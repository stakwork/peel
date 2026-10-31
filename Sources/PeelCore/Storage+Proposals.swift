import Foundation
import GRDB

/// A proposal as Peel last read it (`proposal`, v30): strut's record, where
/// it is, for one of Peel's own strut the device request whose card it is
/// and when that card runs out, when it was answered here, and how it
/// ended for Peel. Kept so a restart draws every card as it last stood
/// before the next read, and a decided one stays on its line in the agent
/// chat.
public struct KeptProposal: Sendable, Equatable {
    /// How a proposal ended for Peel: strut said it is final, or Peel gave
    /// up on it (strut no longer has it, it is not this person's, or its
    /// record could not be read), each at a time.
    public enum Ending: Sendable, Equatable {
        case final(Date)
        case gone(Date)
        case forbidden(Date)
        case unreadable(Date)

        public var at: Date {
            switch self {
            case .final(let at), .gone(let at), .forbidden(let at), .unreadable(let at): at
            }
        }

        /// As stored, and back.
        var word: String {
            switch self {
            case .final: "final"
            case .gone: "gone"
            case .forbidden: "forbidden"
            case .unreadable: "unreadable"
            }
        }

        init?(word: String, at: Date) {
            switch word {
            case "final": self = .final(at)
            case "gone": self = .gone(at)
            case "forbidden": self = .forbidden(at)
            case "unreadable": self = .unreadable(at)
            default: return nil
            }
        }
    }

    public var source: ProposalSource
    public var record: ProposalRecord
    /// The bridge's `approve` request this is the card of (`proposal:<id>`); nil on a workspace's.
    public var request: String?
    /// After this second the card is never acted on (the request's `not_after`); nil on a workspace's.
    public var notAfter: Int64?
    /// When Peel last read the record.
    public var readAt: Date
    /// When the Mac answered its card (Peel's own strut's): the record is
    /// then read soon and often until it moves.
    public var answeredAt: Date?
    /// How it ended for Peel; nil while it is open.
    public var ending: Ending?

    public var key: ProposalKey { ProposalKey(source: source, id: record.id) }

    public init(source: ProposalSource, record: ProposalRecord, request: String? = nil, notAfter: Int64? = nil,
                readAt: Date = .now, answeredAt: Date? = nil, ending: Ending? = nil) {
        self.source = source
        self.record = record
        self.request = request
        self.notAfter = notAfter
        self.readAt = readAt
        self.answeredAt = answeredAt
        self.ending = ending ?? (record.status.isFinal ? .final(readAt) : nil)
    }

    /// Whether Peel is done with it, one way or another.
    public var isOver: Bool { ending != nil }

    /// Its card's time has run out while it still waits on this Mac: nothing
    /// will be done here, whatever strut says.
    public func isExpired(at now: Date) -> Bool {
        guard !isOver, let notAfter else { return false }
        return ControlEnvelope.isPast(notAfter, at: now)
    }

    /// `record` in place of what was read before: the ending is set once,
    /// the first time a read finds it final, and cleared should strut say it
    /// is open after all (one Peel gave up on as gone, found again): strut's
    /// word wins.
    public func updated(with record: ProposalRecord, at now: Date = .now) -> KeptProposal {
        var kept = self
        kept.record = record
        kept.readAt = now
        if !record.status.isFinal {
            kept.ending = nil
        } else if kept.ending == nil {
            kept.ending = .final(now)
        }
        return kept
    }
}

/// `KeptProposal` as its row.
struct ProposalRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "proposal"

    var source: String
    var id: String
    var request: String?
    var notAfter: Int64?
    /// The record as Peel's own JSON.
    var record: String
    /// Milliseconds since 1970.
    var readAt: Int64
    var answeredAt: Int64?
    var ending: String?
    var endedAt: Int64?

    init(_ kept: KeptProposal) throws {
        source = kept.source.rawValue
        id = kept.record.id
        request = kept.request
        notAfter = kept.notAfter
        record = String(decoding: try JSONEncoder().encode(kept.record), as: UTF8.self)
        readAt = kept.readAt.millisecondsSince1970
        answeredAt = kept.answeredAt?.millisecondsSince1970
        ending = kept.ending?.word
        endedAt = kept.ending?.at.millisecondsSince1970
    }

    /// The proposal it keeps; nil for a record this build cannot read.
    var kept: KeptProposal? {
        guard let record = JSON.decode(ProposalRecord.self, from: record) else { return nil }
        var over: KeptProposal.Ending?
        if let ending, let endedAt { over = KeptProposal.Ending(word: ending, at: Date(millisecondsSince1970: endedAt)) }
        return KeptProposal(source: ProposalSource(rawValue: source), record: record, request: request, notAfter: notAfter,
                            readAt: Date(millisecondsSince1970: readAt), answeredAt: answeredAt.map(Date.init(millisecondsSince1970:)),
                            ending: over)
    }
}

extension Storage {
    /// Keeps `proposal` as it stands, in place of what was kept of it.
    public func keepProposal(_ proposal: KeptProposal) throws {
        let row = try ProposalRow(proposal)
        try pool.write { db in try row.save(db) }
    }

    /// Every proposal kept.
    public func proposals() throws -> [KeptProposal] {
        try pool.read { db in try ProposalRow.fetchAll(db).compactMap(\.kept) }
    }

    /// Forgets a workspace's proposals over since before `date`: their
    /// cards have no line in a chat to stay on. Peel's own strut's are kept
    /// with their lines.
    public func forgetOrgProposals(endedBefore date: Date) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM proposal WHERE source != '' AND endedAt IS NOT NULL AND endedAt < ?",
                           arguments: [date.millisecondsSince1970])
        }
    }
}
