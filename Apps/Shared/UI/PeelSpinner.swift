import SwiftUI

/// Peel's loading spinner, in place of the system's: the peel's spiral from
/// the app icon as a line glyph, drawn on a faint copy of itself. It winds
/// out from the centre to the tail, rests a beat, and draws back to the
/// centre, 2.4 s a cycle. Under Reduce Motion the whole glyph breathes
/// between full and 40% opacity instead.
///
/// It shows only while `active`, and with `delayed` (the default) only once
/// the wait has passed 400 ms, then stays at least 400 ms, so a quick answer
/// never flickers it. Its frame is always laid out, so nothing moves when it
/// comes and goes. Nothing animates while it is hidden.
struct PeelSpinner: View {
    let size: CGFloat
    let active: Bool
    let delayed: Bool
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible: Bool
    @State private var shownAt = Date.now

    init(size: CGFloat = 20, active: Bool = true, delayed: Bool = true, tint: Color = Theme.secondaryText) {
        self.size = size
        self.active = active
        self.delayed = delayed
        self.tint = tint
        _visible = State(initialValue: active && !delayed)
    }

    /// The cycle's two halves: ease in and out, as the board's Wind does.
    private static let wind = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.55, y: 1)
    )

    var body: some View {
        ZStack {
            if visible { glyph.transition(.opacity) }
        }
        .frame(width: size, height: size)
        .foregroundStyle(tint)
        .animation(.easeOut(duration: 0.15), value: visible)
        .task(id: active) { await follow() }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Loading", table: "Shared"))
        .accessibilityHidden(!visible)
    }

    @ViewBuilder private var glyph: some View {
        let style = StrokeStyle(lineWidth: max(1.25, size * 0.08), lineCap: .round, lineJoin: .round)
        if reduceMotion {
            KeyframeAnimator(initialValue: 1.0, repeating: true) { opacity in
                PeelGlyph().stroke(style: style).opacity(opacity)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.4, duration: 0.8, timingCurve: .easeInOut)
                    LinearKeyframe(1, duration: 0.8, timingCurve: .easeInOut)
                }
            }
        } else {
            ZStack {
                PeelGlyph().stroke(style: style).opacity(0.2)
                KeyframeAnimator(initialValue: 0.0, repeating: true) { drawn in
                    PeelGlyph().trim(from: 0, to: drawn).stroke(style: style)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1, duration: 1.08, timingCurve: Self.wind)
                        LinearKeyframe(1, duration: 0.24)
                        LinearKeyframe(0, duration: 1.08, timingCurve: Self.wind)
                    }
                }
            }
        }
    }

    /// Shows after the delay once `active`; hides once it has been up 400 ms.
    /// A change of `active` cancels the wait in progress.
    private func follow() async {
        if active {
            guard !visible else { return }
            if delayed {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            shownAt = .now
            visible = true
        } else if visible {
            let left = 0.4 - Date.now.timeIntervalSince(shownAt)
            if left > 0 {
                try? await Task.sleep(for: .seconds(left))
                if Task.isCancelled { return }
            }
            visible = false
        }
    }
}

/// The peel's spiral as a line in a 24 pt box, from its centre out to the
/// tail at the lower left: the curve of `Apps/Assets/peel.svg`, sampled.
struct PeelGlyph: Shape {
    private static let points: [CGFloat] = [
        12, 8.29, 12.2, 8.22, 12.42, 8.17, 12.65, 8.14, 12.88, 8.14, 13.13, 8.15, 13.37, 8.19, 13.62,
        8.25, 13.86, 8.34, 14.11, 8.46, 14.34, 8.6, 14.57, 8.76, 14.79, 8.95, 14.98, 9.16, 15.17, 9.4,
        15.34, 9.65, 15.48, 9.93, 15.6, 10.23, 15.7, 10.54, 15.77, 10.86, 15.81, 11.2, 15.82, 11.55,
        15.8, 11.9, 15.74, 12.25, 15.65, 12.6, 15.53, 12.95, 15.37, 13.3, 15.18, 13.63, 14.96, 13.96,
        14.71, 14.26, 14.42, 14.54, 14.1, 14.81, 13.76, 15.05, 13.39, 15.26, 13, 15.44, 12.59, 15.58,
        12.16, 15.69, 11.71, 15.77, 11.26, 15.8, 10.79, 15.79, 10.33, 15.74, 9.86, 15.65, 9.39, 15.51,
        8.94, 15.34, 8.49, 15.11, 8.07, 14.85, 7.66, 14.55, 7.27, 14.21, 6.91, 13.83, 6.58, 13.41, 6.28,
        12.96, 6.03, 12.49, 5.81, 11.98, 5.64, 11.45, 5.51, 10.9, 5.43, 10.34, 5.4, 9.76, 5.42, 9.18,
        5.5, 8.6, 5.62, 8.01, 5.8, 7.44, 6.03, 6.87, 6.31, 6.33, 6.64, 5.8, 7.02, 5.3, 7.45, 4.83, 7.92,
        4.39, 8.44, 4, 8.99, 3.64, 9.58, 3.33, 10.19, 3.08, 10.84, 2.87, 11.5, 2.72, 12.18, 2.63, 12.88,
        2.6, 13.58, 2.63, 14.28, 2.72, 14.98, 2.88, 15.67, 3.09, 16.35, 3.37, 17, 3.71, 17.62, 4.11,
        18.22, 4.57, 18.78, 5.08, 19.29, 5.64, 19.76, 6.25, 20.18, 6.9, 20.54, 7.6, 20.84, 8.33, 21.08,
        9.09, 21.25, 9.87, 21.36, 10.67, 21.39, 11.48, 21.36, 12.31, 21.25, 13.13, 21.07, 13.94, 20.82,
        14.75, 20.5, 15.53, 20.1, 16.29, 19.64, 17.02, 19.11, 17.71, 18.52, 18.36, 17.87, 18.95, 17.17,
        19.5, 16.41, 19.98, 15.61, 20.4, 14.77, 20.75, 13.9, 21.03, 13, 21.23, 12.08, 21.35, 11.15,
        21.4, 10.2, 21.36, 9.27, 21.24, 8.33, 21.04, 7.41, 20.76, 6.51, 20.39, 5.65, 19.94, 4.81, 19.42,
        4.03, 18.82, 3.29, 18.16, 2.61, 17.42,
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: origin.x + Self.points[2 * i] * scale, y: origin.y + Self.points[2 * i + 1] * scale)
        }
        let count = Self.points.count / 2
        var path = Path()
        path.move(to: point(0))
        // Through the midpoints, each sample a control point: a smooth curve.
        for i in 1..<(count - 1) {
            let (a, b) = (point(i), point(i + 1))
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.addLine(to: point(count - 1))
        return path
    }
}
