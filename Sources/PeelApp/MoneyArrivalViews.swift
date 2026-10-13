import SwiftUI
import PeelCore
import PeelUI

/// The balance under your name in the sidebar header: it rolls up, digit by
/// digit, when a payment arrives. Nothing moves: the line keeps the width of
/// the larger of the two numbers from the start, in tabular digits. Under
/// Reduce Motion the number just changes. Sats promised to people still
/// offline follow it as the pending clock and the amount, or the clock alone
/// where the header has no room (the tooltip, VoiceOver and Payments say it
/// in words).
struct BalanceLabel: View {
    let money: MoneyArrivals
    var waitingMsat: UInt64 = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let shown = money.shownMsat {
            Group {
                if waitingMsat > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) { balance(shown); Text(" · ") + clock + Text(" \(Sats.number(msat: waitingMsat))") }
                        HStack(spacing: 0) { balance(shown); Text(" · ") + clock }
                    }
                    .help("\(Sats.format(msat: waitingMsat)) held for people who are offline")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Sats.format(msat: shown)), \(Sats.format(msat: waitingMsat)) waiting")
                } else {
                    balance(shown)
                }
            }
            .font(Theme.font(12))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var clock: Text { Text(Image(systemName: "clock")) }

    private func balance(_ shown: UInt64) -> some View {
        ZStack(alignment: .leading) {
            Text(Sats.format(msat: max(shown, money.balanceMsat ?? 0))).hidden()
            Text(Sats.format(msat: shown))
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(shown)))
        }
    }
}

/// The Payments row in the sidebar, its own view so an arrival redraws only
/// it. Its badge for a moment after sats arrive: "+350", the sum, in the
/// green of received amounts. It pops in with a short scale and fade, rolls
/// to "+420" as more comes, and fades away a few seconds later; it never
/// stays to be cleared. Under Reduce Motion it is a plain badge with the
/// final number.
struct PaymentsLink: View {
    let money: MoneyArrivals

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let msat = money.recentMsat
        SidebarLink("Payments", to: .payments, unread: msat > 0) {
            Image(systemName: "bolt").font(.system(size: 13))
        } accessory: {
            if msat > 0 {
                Badge(Sats.signed(msat: msat, incoming: true), .success)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(msat)))
                    .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Received \(Sats.format(msat: msat))")
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: msat)
    }
}

extension View {
    /// A glow behind the connection bolt for a moment when sats arrive.
    func receivedGlow(_ money: MoneyArrivals) -> some View {
        modifier(ReceivedGlow(arrivals: money.arrivals))
    }
}

private struct ReceivedGlow: ViewModifier {
    let arrivals: Int

    @State private var glowing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.confirmed.opacity(glowing ? 0.9 : 0), radius: glowing ? 5 : 0)
            .onChange(of: arrivals) {
                withAnimation(.easeOut(duration: 0.2)) { glowing = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeOut(duration: 0.8)) { glowing = false }
                }
            }
    }
}
