import Foundation

/// When a model call that failed is made again on its own: a rate limit, an
/// outage or a dropped connection (`ModelError.isRetryable`), a few times,
/// waiting as the provider asked or longer each time. The loop only asks
/// while nothing of the call has been shown, so a retry never repeats words.
public struct RetryPolicy: Sendable, Hashable {
    /// The most retries of one call.
    public var retries = 3
    /// The first wait without a `retry-after`; each one after doubles it.
    public var baseDelay: Duration = .seconds(2)
    /// The longest single wait; a provider asking for longer gets its error shown.
    public var maxDelay: Duration = .seconds(30)
    /// The longest one call may take, its failed tries and waits included,
    /// for another retry to start: a call that hung until a timeout is not
    /// tried again for minutes.
    public var maxTotal: Duration = .seconds(60)

    public init() {}

    /// Never retries.
    public static let never: RetryPolicy = {
        var policy = RetryPolicy()
        policy.retries = 0
        return policy
    }()

    /// How long to wait before retry number `retry` (from 1) after `error`,
    /// `elapsed` since the call was first made; nil to give up and show it.
    /// `jitter`, from 0.5 to 1, spreads the waits of clients that failed
    /// together; a provider's `retry-after` is kept as given.
    func delay(after error: ModelError, retry: Int, elapsed: Duration, jitter: Double) -> Duration? {
        guard error.isRetryable, retry >= 1, retry <= retries else { return nil }
        let delay: Duration
        if case .rateLimited(let after?) = error {
            // A wait the provider names that is not a sane number is not waited.
            guard after.isFinite, after <= 86_400 else { return nil }
            delay = .milliseconds(Int64((max(after, 0) * 1000).rounded(.up)))
        } else {
            let doubled = baseDelay * (1 << min(retry - 1, 16))
            delay = min(doubled, maxDelay) * jitter
        }
        guard delay <= maxDelay, elapsed + delay <= maxTotal else { return nil }
        return delay
    }

    /// What a person is told while a call waits to be made again:
    /// "Rate limited by the provider. Retrying in 4 s…", and once it goes,
    /// "… Retrying…" (`after` zero).
    public static func note(after: Duration, _ reason: ModelError) -> String {
        let seconds = Int((after / .seconds(1)).rounded(.up))
        return reason.reason + (seconds > 0 ? " Retrying in \(seconds) s…" : " Retrying…")
    }
}
