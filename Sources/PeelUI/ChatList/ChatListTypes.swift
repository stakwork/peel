import Foundation
import PeelCore

// What a message list's controller (`ChatListController`) and its engine
// (the platform's scroll view) say to each other: the rows, where to put
// the list, and what the list shows now. No SwiftUI, AppKit or UIKit.

/// One row as the controller sees it.
public struct ChatListRow: Equatable, Sendable {
    public let id: String
    /// Whether the list's place can be kept by this row: never "New
    /// messages"' row (the line goes once you send), a thread's "N replies"
    /// or its missing original.
    public var canAnchor: Bool
    /// Yours, judged from the message: it takes the list to its newest.
    public var isOwn: Bool
    /// The messages it stands for, oldest first (`ListBottom`'s count).
    public var shown: [Message]
    /// The uuids a jump finds it by (`ChatRow.heldUUIDs`).
    public var holds: [String]
    /// Where it sits in time (`ChatRow.date`): a jump to a message older
    /// than the first row waits for a window with it.
    public var date: Date

    public init(id: String, canAnchor: Bool = true, isOwn: Bool = false, shown: [Message] = [], holds: [String] = [],
                date: Date = .distantPast) {
        self.id = id
        self.canAnchor = canAnchor
        self.isOwn = isOwn
        self.shown = shown
        self.holds = holds
        self.date = date
    }
}

/// A list's rows, oldest first, and what the model says about them.
public struct ListContent: Equatable, Sendable {
    public var rows: [ChatListRow]
    /// The row under a live "New messages".
    public var divider: String?
    /// The rows end at the chat's newest message (not a jump's window short of it).
    public var reachesNewest: Bool
    /// Older messages can be loaded above the first row.
    public var hasOlder: Bool

    public init(rows: [ChatListRow], divider: String? = nil, reachesNewest: Bool = true, hasOlder: Bool = false) {
        self.rows = rows
        self.divider = divider
        self.reachesNewest = reachesNewest
        self.hasOlder = hasOlder
    }

    public static let empty = ListContent(rows: [])
}

/// Where the list goes.
public enum ListPlacement: Equatable, Sendable {
    /// The content's end, its padding included.
    case newest
    /// The row's top `offset` points below the view's top.
    case row(id: String, offset: Double)
    /// The row in the middle of the view.
    case center(id: String)
    /// Where it is.
    case keep
}

public struct ListMove: Equatable, Sendable {
    public var to: ListPlacement
    public var animated: Bool

    public init(to: ListPlacement, animated: Bool = false) {
        self.to = to
        self.animated = animated
    }

    public static let keep = ListMove(to: .keep)
}

/// What the list shows, as the engine measured it after a move.
public struct ListViewport: Equatable, Sendable {
    /// The rows in view, top to bottom, and each one's top below the view's
    /// top (negative: cut off above).
    public var visibleIDs: [String]
    public var visibleTops: [Double]
    /// Within `ChatListController.bottomZone` of the content's end.
    public var atBottom: Bool
    /// Within a view's height of the content's top.
    public var nearTop: Bool
    /// Over a view's height from the content's end.
    public var far: Bool

    public init(visibleIDs: [String], visibleTops: [Double], atBottom: Bool, nearTop: Bool = false, far: Bool = false) {
        self.visibleIDs = visibleIDs
        self.visibleTops = visibleTops
        self.atBottom = atBottom
        self.nearTop = nearTop
        self.far = far
    }
}

public enum ListScrollPhase: Equatable, Sendable {
    case idle, tracking, decelerating, animating
}

/// Where a jump to a message stands.
public enum JumpOutcome: Equatable, Sendable {
    /// Among the rows: centred and lit.
    case here
    /// Older than the first row: a window with it is coming.
    case waitingForWindow
    /// Where the rows are but not among them: folded into a thread, or gone.
    case notLoaded
}

/// How a list's rows changed: the ids that came, and the kept rows that
/// moved among the others (a tribe's thread row re-sorted to its newest reply).
public struct ListDiff: Equatable, Sendable {
    public private(set) var inserted: Set<String> = []
    public private(set) var moved: Set<String> = []

    /// From a difference of the rows' ids (in either order) with its moves inferred.
    public init(_ difference: CollectionDifference<String>) {
        for case .insert(_, let id, let from) in difference {
            if from == nil { inserted.insert(id) } else { moved.insert(id) }
        }
    }
}

/// The jump button over a list scrolled up.
public enum ListPill: Equatable, Sendable {
    /// Back to the newest.
    case arrow
    /// "N new messages" below.
    case count(Int)
    /// The list is a jump's window short of the newest.
    case present
}

/// The platform's scroll view under a `ChatListController`. Every change
/// that comes with a layout returns its placement to the engine, which
/// applies it in the same pass; these are the moves outside one.
@MainActor public protocol ChatListEngine: AnyObject {
    /// A jump or the pill: animated where it asks.
    func move(_ move: ListMove)
    /// Lights a row for a moment.
    func flash(_ id: String)
    /// Shows the list, once it has been placed the first time.
    func reveal()
    /// The row's top below the view's top, measured; nil when it is not here.
    func top(of id: String) -> Double?
}

/// Where each list stood, kept past the list (`AppModel` conforms).
@MainActor public protocol ListAnchorStore: AnyObject {
    func anchor(of list: ComposerID) -> ListAnchor?
    func keep(_ anchor: ListAnchor, of list: ComposerID)
    /// Whether a list made now opens at "New messages".
    func opensAtNewMessages(in list: ComposerID) -> Bool
}

extension AppModel: ListAnchorStore {
    /// Only the chat's own list opens at "New messages"; a thread never does.
    public func opensAtNewMessages(in list: ComposerID) -> Bool {
        guard case .chat(let chat) = list else { return false }
        return opensAtNewMessages(in: chat)
    }
}

extension ChatRow {
    /// This row as `list`'s controller sees it.
    public func listRow(in list: ComposerID) -> ChatListRow {
        let anchors: Bool = switch kind {
        case .replies, .missingOriginal: false
        default: !startsNew
        }
        let newest = shown.last
        // In the chat's list, a reply of yours in a thread is the thread's
        // send, not this list's.
        let own = newest?.fromMe == true && (list.thread != nil || newest?.threadUUID == nil)
        return ChatListRow(id: id, canAnchor: anchors, isOwn: own, shown: shown, holds: heldUUIDs, date: date)
    }
}

extension ListContent {
    /// `rows` as `list`'s controller sees them.
    public init(_ rows: [ChatRow], in list: ComposerID, reachesNewest: Bool, hasOlder: Bool) {
        self.init(rows: rows.map { $0.listRow(in: list) }, divider: rows.first(where: \.startsNew)?.id,
                  reachesNewest: reachesNewest, hasOlder: hasOlder)
    }
}
