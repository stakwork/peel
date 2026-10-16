import SwiftUI
import PeelCore
import PeelUI

/// Paste a link, see what the tribe is and what it costs, then join.
struct JoinTribeForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    /// The link and the tribe it names (`TribeLookup`).
    @State private var lookup: TribeLookup
    @State private var attempt = PaymentAttempt()

    /// Opened from a link card: the link filled in, and the tribe when the
    /// card has read it. Joining reads it again and pays only this price.
    init(link: String = "", info: TribeInfo? = nil, done: @escaping () -> Void) {
        _lookup = State(initialValue: TribeLookup(link: link, info: info))
        self.done = done
    }

    var body: some View {
        @Bindable var lookup = lookup
        // The compact form (one field): the link, then the tribe.
        Panel("Join a tribe", compact: true, close: done) {
            FormItem(label: "Tribe link") {
                FormTextField(label: "Tribe link", prompt: "sphinx.chat://?action=tribeV2…", text: $lookup.link, axis: .vertical)
            }
            // Return looks up, then joins once the preview is up, as the buttons would.
            .onSubmit { Task { await submit() } }
            .onChange(of: lookup.link) {
                attempt.armed = nil
                attempt.problem = nil
            }
            if let info = lookup.info {
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        TribeIcon(name: info.name, url: info.img, pubkey: info.pubkey, size: Theme.AvatarSize.lg)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info.name)
                                .font(Theme.font(14, .semibold))
                            if let summary = info.summary?.trimmed.nilIfEmpty {
                                Text(summary)
                                    .font(Theme.font(12))
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(3)
                            }
                            Text(info.priceLine)
                                .monospacedDigit()
                                .muted()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            FormFooter(problem: lookup.problem ?? attempt.problem) {
                Button("Cancel", action: done)
                    .buttonStyle(.peel(.outline))
                    .disabled(attempt.working)
                if let info = lookup.info {
                    // Over the threshold the price is confirmed in place, as any payment.
                    PayButton(
                        verb: "Join", totalMsat: info.joinAmountMsat, attempt: attempt, send: join, sent: done,
                        namesAmount: false
                    )
                } else {
                    Button { Task { await lookUp() } } label: { Text("Look up").buttonProgress(lookup.lookingUp) }
                        .buttonStyle(.peel(.primary))
                        .keyboardShortcut(.defaultAction)
                        // Not off while it looks up, so it keeps its fill under
                        // the spinner; `lookUp` ignores a second click.
                        .disabled(lookup.link.trimmed.isEmpty)
                }
            }
        }
    }

    private func submit() async {
        if lookup.info == nil {
            await lookUp()
        } else if await attempt.run(join) {
            done()
        }
    }

    private func lookUp() async {
        await lookup.lookUp(with: model)
    }

    private func join(_ confirmedMsat: UInt64?) async -> PaymentOutcome {
        await lookup.join(with: model, confirmedMsat: confirmedMsat)
    }
}
