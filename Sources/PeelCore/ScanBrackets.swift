import CoreGraphics

/// The four corner brackets drawn around a scanned code, from the code's
/// four corners as the scanner reports them. Pure geometry: each bracket is
/// three points (an arm's end, the corner, the other arm's end), drawn as
/// one rounded stroke by the phone's scanner.
public struct ScanBrackets: Sendable, Equatable {
    /// One L: the first arm's end, the corner, the second arm's end.
    public struct Bracket: Sendable, Equatable {
        public let start: CGPoint
        public let corner: CGPoint
        public let end: CGPoint
    }

    /// An arm is this fraction of the side it runs along.
    public static let armFraction: CGFloat = 0.22

    public let brackets: [Bracket]
    /// The quad's centre, for placing and scaling a drawing from it.
    public let center: CGPoint

    /// The quad's corners in order around it (top left, top right, bottom
    /// right, bottom left, or any rotation of that).
    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let corners = [topLeft, topRight, bottomRight, bottomLeft]
        brackets = corners.indices.map { i in
            let previous = corners[(i + 3) % 4], corner = corners[i], next = corners[(i + 1) % 4]
            return Bracket(
                start: Self.step(from: corner, toward: previous),
                corner: corner,
                end: Self.step(from: corner, toward: next))
        }
        center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
    }

    /// The point `armFraction` of the way from `a` to `b`.
    static func step(from a: CGPoint, toward b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * armFraction, y: a.y + (b.y - a.y) * armFraction)
    }

    /// The quad's area (shoelace), to choose the largest of several codes.
    public static func area(_ q: [CGPoint]) -> CGFloat {
        guard q.count == 4 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}
