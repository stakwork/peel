import SwiftUI

/// Peel's few shared motions (docs/design/README.md, "Motion"): one curve
/// for what arrives, the way a mark arrives, and the wrong-PIN shake. Each
/// is for a rare moment; keyboard actions and what is used all day stay still.
extension Animation {
    /// What arrives: a strong ease-out, (0.23, 1, 0.32, 1).
    static func arrive(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

extension AnyTransition {
    /// A mark arriving (a check, the delivered bolt): from a quarter of its
    /// size and a 4 pt blur, fading in. It leaves by fading.
    static var mark: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: MarkArrival(progress: 0), identity: MarkArrival(progress: 1)).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// A line that follows a mark: fading up `rise` points.
    static func rise(_ rise: CGFloat) -> AnyTransition {
        .asymmetric(insertion: .offset(y: rise).combined(with: .opacity), removal: .opacity)
    }
}

private struct MarkArrival: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.25 + 0.75 * progress)
            .blur(radius: 4 * (1 - progress))
    }
}

extension View {
    /// Shakes sideways once each time `count` goes up, as macOS does for a
    /// wrong password: 10, 6, then 2 pt, over 360 ms. Never under Reduce Motion.
    func shake(_ count: Int) -> some View {
        modifier(ShakeOnChange(count: count))
    }
}

private struct ShakeOnChange: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shaken: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(Shake(shakes: shaken))
            .onChange(of: count) { _, count in
                guard !reduceMotion else { shaken = CGFloat(count); return }
                withAnimation(.linear(duration: 0.36)) { shaken = CGFloat(count) }
            }
    }
}

/// Its fraction between whole shakes is how far into one it is: three
/// swings that die away (10, 6, 2 pt at their peaks), at rest on every
/// whole number.
private struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = shakes - shakes.rounded(.down)
        let x = sin(t * .pi * 3) * 12 * (1 - t)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

extension View {
    /// One beat of a staged arrival, laid out from the start so nothing
    /// moves: hidden until `shown`, then fading up `rise` points (or, as a
    /// `mark`, growing from a quarter size out of a 4 pt blur) over 300 ms,
    /// `delay` seconds after. Under Reduce Motion it only fades.
    func arrival(_ shown: Bool, delay: Double = 0, rise: CGFloat = 8, mark: Bool = false) -> some View {
        modifier(Arrival(shown: shown, delay: delay, rise: rise, mark: mark))
    }

    /// Scales up and back once (1, 1.15, 1 over 260 ms, no overshoot) each
    /// time `on` turns true, as your boost lands. Never under Reduce Motion.
    func popOnce(when on: Bool) -> some View {
        modifier(PopOnce(on: on))
    }
}

private struct Arrival: ViewModifier {
    let shown: Bool
    let delay: Double
    let rise: CGFloat
    let mark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moving = !shown && !reduceMotion
        content
            .scaleEffect(mark && moving ? 0.25 : 1)
            .blur(radius: mark && moving ? 4 : 0)
            .offset(y: !mark && moving ? rise : 0)
            .opacity(shown ? 1 : 0)
            .animation(shown ? .arrive(0.3).delay(delay) : nil, value: shown)
    }
}

private struct PopOnce: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pops = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 1.0, trigger: pops) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(1.15, duration: 0.11, timingCurve: .easeOut)
                    LinearKeyframe(1, duration: 0.15, timingCurve: .easeInOut)
                }
            }
            .onChange(of: on) { _, on in
                if on, !reduceMotion { pops += 1 }
            }
    }
}
