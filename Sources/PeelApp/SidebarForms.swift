import SwiftUI
import PeelCore

/// Paste a link, see what the tribe is and what it costs, then join.
struct JoinTribeForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var link = ""
    @State private var info: TribeInfo?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a tribe")
                .font(Theme.font(15, .bold))
            TextField("sphinx.chat://?action=tribeV2…", text: $link, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                // Return joins once the preview is up, as the Join button would.
                .onSubmit { Task { await submit() } }
                .onChange(of: link) { info = nil; problem = nil }
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
            FormFooter(problem: problem) {
                if info == nil {
                    Button { Task { await lookUp() } } label: { Text("Look up").buttonProgress(working) }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || link.trimmed.isEmpty)
                } else {
                    Button { Task { await join() } } label: { Text("Join").buttonProgress(working) }
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func submit() async {
        if info == nil { await lookUp() } else { await join() }
    }

    private func lookUp() async {
        guard !link.trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }
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

    private func join() async {
        guard let info, !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.joinTribe(link, agreedJoinMsat: info.joinAmountMsat)
            done()
        } catch {
            problem = PeelError.readable(error)
        }
    }
}
