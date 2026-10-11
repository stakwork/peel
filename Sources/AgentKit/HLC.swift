/// A hybrid logical clock: the wall time in ms, a counter for events in the
/// same ms (or while the wall clock is behind one already seen), and the
/// device that made it. Ordered by wall, then counter, then device, so two
/// devices never tie and every device orders the same events the same way.
public struct HLC: Codable, Sendable, Hashable, Comparable {
    public var wallMs: Int64
    public var counter: Int
    public var device: String

    public init(wallMs: Int64, counter: Int = 0, device: String) {
        self.wallMs = wallMs
        self.counter = counter
        self.device = device
    }

    enum CodingKeys: String, CodingKey {
        case wallMs = "wall_ms", counter, device
    }

    /// Advances the clock for a local event at `now` and returns its stamp,
    /// later than every stamp this clock has made or seen.
    public mutating func tick(now: Int64) -> HLC {
        if now > wallMs {
            wallMs = now
            counter = 0
        } else {
            counter += 1
        }
        return self
    }

    /// Advances the clock past `remote`, a stamp from another device, so the
    /// next local event orders after it.
    public mutating func receive(_ remote: HLC, now: Int64) {
        let wall = max(wallMs, remote.wallMs, now)
        if wall == wallMs && wall == remote.wallMs {
            counter = max(counter, remote.counter) + 1
        } else if wall == wallMs {
            counter += 1
        } else if wall == remote.wallMs {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        wallMs = wall
    }

    public static func < (a: HLC, b: HLC) -> Bool {
        (a.wallMs, a.counter, a.device) < (b.wallMs, b.counter, b.device)
    }
}
