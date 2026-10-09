import SwiftUI
import PeelCore

/// Paste a link, see what the tribe is and what it costs, then join.
struct JoinTribeForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var link: String
    @State private var info: TribeInfo?
    @State private var lookingUp = false
    @State private var problem: String?
    @State private var attempt = PaymentAttempt()

    /// Opened from a link card: the link filled in, and the tribe when the
    /// card has read it. Joining reads it again and pays only this price.
    init(link: String = "", info: TribeInfo? = nil, done: @escaping () -> Void) {
        _link = State(initialValue: link)
        _info = State(initialValue: info)
        self.done = done
    }

    var body: some View {
        // The compact form (one field): the link, then the tribe.
        FormPopover(title: "Join a tribe", compact: true, close: done) {
            FormItem(label: "Tribe link") {
                FormTextField(label: "Tribe link", prompt: "sphinx.chat://?action=tribeV2…", text: $link, axis: .vertical)
            }
            // Return looks up, then joins once the preview is up, as the buttons would.
            .onSubmit { Task { await submit() } }
            .onChange(of: link) {
                info = nil
                problem = nil
                attempt.armed = nil
                attempt.problem = nil
            }
            if let info {
                HStack(alignment: .top, spacing: 10) {
                    TribeIcon(name: info.name, url: info.img, pubkey: info.pubkey, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name)
                            .font(Theme.font(14, .semibold))
                        if let summary = info.summary?.trimmed.nilIfEmpty {
                            Text(summary)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(3)
                        }
                        Text("Joining costs \(info.joinPrice.text) · \(info.messagePrice.text) a message")
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .formCard()
            }
        } footer: {
            FormFooter(problem: problem ?? attempt.problem) {
                Button("Cancel", action: done)
                    .buttonStyle(.peel(.outline))
                    .disabled(attempt.working)
                if let info {
                    // Over the threshold the price is confirmed in place, as any payment.
                    PayButton(
                        verb: "Join", totalMsat: info.joinAmountMsat, attempt: attempt, send: join, sent: done,
                        namesAmount: false
                    )
                } else {
                    Button { Task { await lookUp() } } label: { Text("Look up").buttonProgress(lookingUp) }
                        .buttonStyle(.peel(.primary))
                        .keyboardShortcut(.defaultAction)
                        // Not off while it looks up, so it keeps its fill under
                        // the spinner; `lookUp` ignores a second click.
                        .disabled(link.trimmed.isEmpty)
                }
            }
        }
    }

    private func submit() async {
        if info == nil {
            await lookUp()
        } else if await attempt.run(join) {
            done()
        }
    }

    private func lookUp() async {
        guard !link.trimmed.isEmpty, !lookingUp else { return }
        lookingUp = true
        defer { lookingUp = false }
        let looked = link
        do {
            let found = try await model.previewTribe(looked)
            // A link edited during the lookup is looked up again, not shown with this answer.
            guard link == looked else { return }
            info = found
            problem = nil
        } catch {
            if link == looked { problem = PeelError.readable(error) }
        }
    }

    private func join(_ confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let info else { return .busy }
        return await model.joinTribe(link, agreedJoinMsat: info.joinAmountMsat, confirmedMsat: confirmedMsat)
    }
}
