import Foundation

/// The note the agent sends when it is renamed (`PUT /alias` with
/// `announce`, sphinx#443), so every client gets a message carrying the new
/// alias. The decisions are here, apart from the bridge and the app.
public struct AliasAnnouncement: Sendable {
    public init() {}

    /// Whether a rename from `old` to `new` is worth announcing: a real
    /// change only. Never a first naming (`old` nil: the launch path sets the
    /// alias through `RUNNER_ALIAS` and says nothing), an empty name, or the
    /// same name (compared case-sensitively, ignoring surrounding whitespace).
    public static func shouldAnnounce(old: String?, new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let old, !new.isEmpty else { return false }
        return new != old.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to do after one `PUT /alias` attempt that followed a restart.
    public enum Step: Equatable, Sendable {
        case done, retry, stop
    }

    /// 200 is done. 404 (a runner without the route) and 400 (a name it
    /// refuses) never get better, so stop. Anything else (503 before the
    /// account registered, no connection: `nil`) is tried again.
    public static func step(afterStatus status: Int?) -> Step {
        switch status {
        case 200: .done
        case 404, 400: .stop
        default: .retry
        }
    }

    /// Tries after a restart, and the wait between them.
    public static let tries = 5
    public static let wait = Duration.seconds(2)

    private var last = 0
    private var pending: Int?

    /// A rename begins, and supersedes any announcement still waiting: its
    /// token is the only current one.
    public mutating func begin() -> Int {
        last += 1
        pending = last
        return last
    }

    public func isCurrent(_ token: Int) -> Bool { pending == token }

    /// The announcement for `token` is over (sent, given up, or not wanted).
    public mutating func finish(_ token: Int) {
        if pending == token { pending = nil }
    }
}
