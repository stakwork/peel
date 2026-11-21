import PeelUI
import SwiftUI

/// A woven linen, drawn in code (docs/voice-mode.md, "Voice Mode screen"): a
/// warm base, fine weft and warp lines, thread flecks from a fixed seed
/// (`LinenFleck`) and a soft vignette. Charcoal cloth in dark mode.
struct LinenBackground: View {
    @Environment(\.colorScheme) private var scheme
    private static let flecks = LinenFleck.make()

    var body: some View {
        let dark = scheme == .dark
        Canvas { context, size in
            let base = dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.93, green: 0.89, blue: 0.81)
            let thread = dark ? Color.white : Color(red: 0.36, green: 0.28, blue: 0.18)
            let full = CGRect(origin: .zero, size: size)
            context.fill(Path(full), with: .color(base))

            // Weft (horizontal) and warp (vertical) threads, alternating strength.
            let step: CGFloat = 3
            var weft = Path()
            var y: CGFloat = 0
            while y < size.height { weft.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)); y += step * 2 }
            context.fill(weft, with: .color(thread.opacity(dark ? 0.035 : 0.07)))
            var warp = Path()
            var x: CGFloat = step
            while x < size.width { warp.addRect(CGRect(x: x, y: 0, width: 1, height: size.height)); x += step * 2 }
            context.fill(warp, with: .color(thread.opacity(dark ? 0.03 : 0.06)))

            // Flecks.
            let reach = max(size.width, size.height)
            for fleck in Self.flecks {
                var path = Path()
                let start = CGPoint(x: fleck.x * size.width, y: fleck.y * size.height)
                let length = fleck.length * reach
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x + cos(fleck.angle) * length, y: start.y + sin(fleck.angle) * length))
                let color = fleck.isLight ? Color.white.opacity(0.35 * fleck.tone) : thread.opacity((dark ? 0.12 : 0.22) * fleck.tone)
                context.stroke(path, with: .color(color), lineWidth: 1)
            }

            // Vignette.
            context.fill(Path(full), with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(dark ? 0.35 : 0.14)]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: reach * 0.25, endRadius: reach * 0.75))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
