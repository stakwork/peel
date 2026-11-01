import Foundation
import GRDB

/// A proposal as Peel last read it (`proposal`, v30): strut's record, where
/// it is, for one of Peel's own strut the device request whose card it is
/// and when that card runs out, for one in a tribe the post whose card it
/// is, when it was answered here, and how it ended for Peel. Kept so a
/// restart draws every card as it last stood before the next read, and a
/// decided one stays on its line in the agent chat or under its post.
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
    /// then read soon and often until it moves. In a tribe, when the
    /// owner's reply went (`answer` says which way).
    public var answeredAt: Date?
    /// How it ended for Peel; nil while it is open.
    public var ending: Ending?
    /// In a tribe (docs/hive-tribes.md, "Proposals in a tribe"): the post
    /// whose card it is. Its state then comes from the tribe's posts, never
    /// from a read of the workspace's strut by itself, and its card is
    /// under that post alone.
    public var post: TribePost?
    /// In a tribe: the owner's answer sent here at `answeredAt`, true for an accept.
    public var answer: Bool?

    /// How long the owner's reply in a tribe waits for Jamie's word before
    /// the card says so and offers the buttons again.
    public static let answerPatience: TimeInterval = 10 * 60

    public var key: ProposalKey { ProposalKey(source: source, id: record.id) }

    public init(source: ProposalSource, record: ProposalRecord, request: String? = nil, notAfter: Int64? = nil,
                readAt: Date = .now, answeredAt: Date? = nil, ending: Ending? = nil, post: TribePost? = nil, answer: Bool? = nil) {
        self.source = source
        self.record = record
        self.request = request
        self.notAfter = notAfter
        self.readAt = readAt
        self.answeredAt = answeredAt
        self.ending = ending ?? (record.status.isFinal ? .final(readAt) : nil)
        self.post = post
        self.answer = answer
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

    /// Whether its truth is strut's record, read with the person's token
    /// (Peel's own strut's, a workspace's), or the tribe's posts
    /// (`post != nil`): the latter is never read from a strut by itself,
    /// never a card at the end of the agent chat, and a read of strut that
    /// still happens (the owner's list) leaves it alone.
    public var fromStrut: Bool { post == nil }

    /// The post in a tribe that made it (`carrier`), dated as the post is:
    /// its card and words, and where its card is. The status stays the
    /// latest word's (a copy of the post coming round again never reopens a
    /// decided one), and what strut's own record had beyond the post's (the
    /// input) stays too. A record read from strut before stands by the
    /// posts from now on, so it takes the posts' clock.
    public mutating func take(carrier record: ProposalRecord, on post: TribePost, at date: Date) {
        if self.post == nil {
            self.post = post
            readAt = date
        }
        var known = record
        known.status = self.record.status
        known.decision = self.record.decision ?? record.decision
        known.result = self.record.result ?? record.result
        if record.input == nil, !record.inputCut {
            known.input = self.record.input
            known.inputCut = self.record.inputCut
        }
        self.record = known
    }

    /// A reply in the post's thread saying how it ended, or that the step
    /// runs, dated as the reply is: the later word wins, whichever came
    /// first (history pages come in any order), and nothing reopens a
    /// decided one.
    public mutating func take(outcome record: ProposalRecord, at date: Date) {
        guard date >= readAt, !(isOver && !record.status.isFinal) else { return }
        var settled = self.record
        settled.status = record.status
        if let decision = record.decision { settled.decision = decision }
        if let result = record.result { settled.result = result }
        self = updated(with: settled, at: date)
    }

    /// In a tribe: when the owner's answer here, with no word from Jamie,
    /// has waited `answerPatience`: the reply may not have reached it, so
    /// the card says so and offers the buttons again. Nil while nothing
    /// waits (not answered, the step running, over).
    public var answerStaleAt: Date? {
        guard post != nil, !isOver, record.status == .pending, answer != nil, let answeredAt else { return nil }
        return answeredAt.addingTimeInterval(Self.answerPatience)
    }

    public func isAnswerStale(at now: Date) -> Bool {
        answerStaleAt.map { now >= $0 } ?? false
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
    /// In a tribe: the post whose card it is.
    var tribe: String?
    var post: String?
    var poster: String?
    /// In a tribe: the owner's answer sent here.
    var answer: Bool?

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
        tribe = kept.post?.tribe
        post = kept.post?.uuid
        poster = kept.post?.poster
        answer = kept.answer
    }

    /// The proposal it keeps; nil for a record this build cannot read.
    var kept: KeptProposal? {
        guard let record = JSON.decode(ProposalRecord.self, from: record) else { return nil }
        var over: KeptProposal.Ending?
        if let ending, let endedAt { over = KeptProposal.Ending(word: ending, at: Date(millisecondsSince1970: endedAt)) }
        var on: TribePost?
        if let tribe, let post { on = TribePost(tribe: tribe, uuid: post, poster: poster) }
        return KeptProposal(source: ProposalSource(rawValue: source), record: record, request: request, notAfter: notAfter,
                            readAt: Date(millisecondsSince1970: readAt), answeredAt: answeredAt.map(Date.init(millisecondsSince1970:)),
                            ending: over, post: on, answer: answer)
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

    /// The posts in tribes stored since message id `id` that may say
    /// something of strut's proposals (`Message.strutProposals`): someone
    /// else's text, not deleted, whose body names `proposals`, oldest
    /// first; and the highest message id stored, which the next read starts
    /// after (`Setting.proposalPostsScan`). Read as the watch opens, so a
    /// post that came while it was not watching (to another process on the
    /// profile, or before this build) is taken up as any arrival.
    public func proposalPosts(after id: Int64) throws -> (posts: [Message], upTo: Int64) {
        try pool.read { db in
            let upTo = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM message") ?? 0
            let posts = try Message.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE id > ? AND type = \(MessageType.text) AND fromMe = 0 AND deleted = 0 AND body LIKE '%proposals%'
                  AND chat IN (\(Self.tribeChats))
                ORDER BY timestamp, id
                """, arguments: [id])
            return (posts, upTo)
        }
    }

    /// Changed when a look left out posts it read, so the next one reads
    /// every stored row again. "2": the first watch opened before the
    /// account listed its tribes and took none of the posts it read.
    static let proposalPostsVersion = "2"

    /// Where the last `proposalPosts(after:)` got to; 0 when another
    /// `proposalPostsVersion` made it.
    public func proposalPostsScanned() throws -> Int64 {
        guard try value(for: .proposalPostsScanVersion) == Self.proposalPostsVersion else { return 0 }
        return try value(for: .proposalPostsScan).flatMap(Int64.init) ?? 0
    }

    public func setProposalPostsScanned(_ id: Int64) throws {
        try set(String(id), for: .proposalPostsScan)
        try set(Self.proposalPostsVersion, for: .proposalPostsScanVersion)
    }

    /// Forgets a workspace's proposals over since before `date`: their
    /// cards have no line in a chat to stay on. Peel's own strut's are kept
    /// with their lines, and a tribe's with their posts.
    public func forgetOrgProposals(endedBefore date: Date) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM proposal WHERE source != '' AND tribe IS NULL AND endedAt IS NOT NULL AND endedAt < ?",
                           arguments: [date.millisecondsSince1970])
        }
    }
}
