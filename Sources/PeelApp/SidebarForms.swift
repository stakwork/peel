import SwiftUI
import PeelCore

/// Paste a link, see what the tribe is and what it costs, then join.
struct JoinTribeForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var link = ""
    @State private var info: TribeInfo?
    @State private var lookingUp = false
    @State private var problem: String?
    @State private var attempt = PaymentAttempt()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a tribe")
                .font(Theme.font(15, .bold))
            TextField("sphinx.chat://?action=tribeV2…", text: $link, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                // Return joins once the preview is up, as the Join button would.
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
                            .font(Theme.font(14, .medium))
                        if let summary = info.summary?.trimmed.nilIfEmpty {
                            Text(summary)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(3)
                        }
                        Text("Joining costs \(Sats.format(msat: info.joinAmountMsat)) · \(Sats.format(msat: info.messageAmountMsat)) a message")
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            FormFooter(problem: problem ?? attempt.problem) {
                if let info {
                    // Over the threshold the price is confirmed in place, as any payment.
                    PayButton(
                        verb: "Join", totalMsat: info.joinAmountMsat, attempt: attempt, send: join, sent: done,
                        namesAmount: false
                    )
                } else {
                    Button { Task { await lookUp() } } label: { Text("Look up").buttonProgress(lookingUp) }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(lookingUp || link.trimmed.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
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
