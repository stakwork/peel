import PeelCore

/// The Payments list's paging: how many stored rows it reads, raised a page
/// at a time as its end comes into view, and whether the server may still
/// have older pages.
public struct PaymentPaging: Equatable, Sendable {
    public static let page = Int(Engine.paymentPageSize)

    /// How many stored rows the list reads.
    public private(set) var limit = page
    /// False once the server's history gave fewer than a page.
    public private(set) var hasMore = true

    public init() {}

    /// The end of the list is in view with `shown` rows: a page more of
    /// what is stored, at most a page past what shows, so the end of what
    /// is stored stops raising it. Not `shown >= limit`: pings folded into
    /// their payments leave a full page a row or two short.
    public mutating func reachedEnd(showing shown: Int) {
        if limit - shown < Self.page { limit += Self.page }
    }

    /// The server's next older page came with `count` rows: fewer than a
    /// page means the end.
    public mutating func fetched(_ count: Int) {
        hasMore = count >= Self.page
    }
}
