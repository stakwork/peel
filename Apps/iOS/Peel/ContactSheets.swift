import PeelCore
import PeelUI
import SwiftUI

// Adding people on the phone (docs/design/iphone.md, screen 1's Direct
// messages; the Mac's `ContactsViews`): Add contact, Invite someone and an
// invite's own screen. Every rule is the engine's, through the model, as
// on the Mac; money goes through the touch-safe confirm.

/// Add someone by their contact info, an invite (its inviter is added) or
/// a Sphinx contact link: typed, pasted, scanned with the camera or read
/// from a photo of their code. Then who it adds, an optional name, and Add,
/// which pays the 5-sat key exchange (confirmed in place over the
/// threshold). Someone already a contact is not added again: their chat opens.
struct AddContactSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissSheet) private var dismiss

    @State private var text = ""
    /// What `text` is, read once per change.
    @State private var code: ContactCode?
    @State private var codeProblem: String?
    /// The text a scan, a photo or Paste gave: why it adds nobody shows at once.
    @State private var pickedText: String?
    @State private var name = ""
    @State private var attempt = PaymentAttempt()
    /// The key exchange went out to this name.
    @State private var sentTo: String?

    var body: some View {
        Group {
            if let sentTo {
                SheetPage(title: "Add contact") {
                    Label("Sent to \(sentTo)", systemImage: "checkmark.circle.fill")
                        .phoneFont(PhoneFont.row.weight(.semibold))
                        .foregroundStyle(Theme.confirmed)
                    Text("They appear in Direct messages once they accept.")
                        .phoneFont(.row)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } actions: {
                    Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(.peel(.primary, size: .touch))
                }
            } else {
                form
            }
        }
    }

    private var form: some View {
        SheetPage(title: "Add contact") {
            CodeEntry(
                label: "Their code", prompt: "Contact info, invite or Sphinx link", text: $text,
                scanTitle: "Scan their code", scanPrompt: "Point the camera at their contact QR code.",
                accept: { (try? ContactCode.read($0))?.pubkey == nil ? "That code doesn't name anyone." : nil },
                choose: ContactCode.likeliest(in:),
                picked: { pickedText = $0 }
            )
            if let code, let pubkey = code.pubkey {
                CodePreview(code: code, pubkey: pubkey)
            }
            FieldLabel("Name") {
                NoteInput(label: "Name", prompt: code?.inviterName ?? "Optional", text: $name)
            }
            if let problem = (text == pickedText ? codeProblem : nil) ?? code?.addRefusal {
                ProblemText(problem)
            }
        } actions: {
            TouchPayButton(
                verb: "Add", totalMsat: text.trimmed.isEmpty ? nil : Engine.keyExchangeMsat, attempt: attempt
            ) { confirmed in
                let (outcome, added) = await model.addContact(code: text, alias: name, confirmedMsat: confirmed)
                // Already a contact: their chat opened.
                if added == false { dismiss() }
                if added == true { sentTo = AppModel.addedName(alias: name, code: code) }
                return outcome
            }
        }
        .onChange(of: text, initial: true) {
            attempt.armed = nil
            attempt.problem = nil
            (code, codeProblem) = AppModel.readContactCode(text)
        }
    }
}

/// Who the code adds: contact info by its short key; an invite by its
/// inviter. A card under the code.
private struct CodePreview: View {
    @Environment(AppModel.self) private var model
    let code: ContactCode
    let pubkey: String

    var body: some View {
        PhoneCard {
            HStack(spacing: Theme.Space.md) {
                Avatar(name: code.inviterName ?? "", url: nil, size: 40,
                       hue: model.hue(pubkey: pubkey, alias: code.inviterName, inTribe: false))
                VStack(alignment: .leading, spacing: 2) {
                    Text(code.inviterName ?? Formatting.shortKey(pubkey))
                        .phoneFont(PhoneFont.row.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(code.previewDetail)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Make an invite with sats for someone without an account: the amount,
/// a nickname and message only you see, and Invite, which the engine
/// always asks to confirm with its amount. Once made, the invite itself.
struct InviteSheet: View {
    @Environment(AppModel.self) private var model

    @State private var amount = ""
    @State private var nickname = ""
    @State private var message = ""
    @State private var attempt = PaymentAttempt()
    @State private var made: InviteRecord?
    @FocusState private var amountFocused: Bool

    var body: some View {
        Group {
            if let made {
                InviteDetailScreen(code: made.code)
            } else {
                SheetPage(title: "Invite someone") {
                    FieldLabel("Amount") { SatsInput(label: "Amount", text: $amount, focused: $amountFocused) }
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        PhoneSectionHeader("Only you see these")
                        FieldLabel("Nickname") { NoteInput(label: "Nickname", prompt: "Optional", text: $nickname) }
                        FieldLabel("Message") { NoteInput(label: "Message", prompt: "Optional", text: $message) }
                    }
                    Text("The sats leave your balance now. Cancel the invite to get them back.")
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    BalanceLine()
                } actions: {
                    TouchPayButton(verb: "Invite", totalMsat: Sats.msat(amount), attempt: attempt) { confirmed in
                        guard let msat = Sats.msat(amount) else { return .refused("Enter an amount in sats.") }
                        let (outcome, invite) = await model.makeInvite(
                            amountMsat: msat, nickname: nickname, message: message, confirmedMsat: confirmed
                        )
                        if let invite { made = invite }
                        return outcome
                    }
                }
                // Another nickname or message is another invite: ask again.
                .onChange(of: [nickname, message]) {
                    attempt.armed = nil
                    attempt.problem = nil
                }
                .onAppear { amountFocused = true }
            }
        }
    }
}

/// One invite: its QR code and link to copy or share once the server holds
/// its sats, what it holds, the private nickname and message, and Cancel
/// invite, confirmed in place, for the sats back. The Mac's `InviteDetail`.
struct InviteDetailScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissSheet) private var dismiss
    let code: String

    @State private var problem: String?

    var body: some View {
        let invite = model.invites[code]
        SheetPage(title: invite?.nickname ?? "Invite") {
            if let invite {
                content(invite)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } actions: {
            if let invite { actions(invite) }
        }
    }

    @ViewBuilder private func content(_ invite: InviteRecord) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Text(Sats.format(msat: invite.amountMsat))
                .phoneFont(PhoneFont(size: 28, weight: .bold, style: .title))
                .monospacedDigit()
            Text(invite.statusLine)
                .phoneFont(.secondary)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        if invite.status == .ready {
            ShareableCode(text: invite.link, label: "QR code of the invite", copyTitle: "Copy invite")
            Text("Anyone with this invite can claim its sats.")
                .phoneFont(.secondary)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        } else {
            // Faint until the server holds the sats.
            QRCodeTile(text: nil, label: "QR code of the invite, not ready yet", size: 220, inset: 12)
                .frame(maxWidth: .infinity)
        }
        if let message = invite.message {
            PhoneCard {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    PhoneSectionHeader("Your message")
                    Text(message)
                        .phoneFont(.row)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let problem { ProblemText(problem) }
    }

    /// Remove from list (cancelling with no answer), Cancel invite or Done.
    @ViewBuilder private func actions(_ invite: InviteRecord) -> some View {
        if invite.status == .cancelling {
            // The server never answered: used, or the sats came back unseen.
            Button {
                Task {
                    do {
                        try await model.forgetInvite(invite.code)
                        dismiss()
                    } catch {
                        problem = PeelError.problem(error)
                    }
                }
            } label: {
                Text("Remove from list").frame(maxWidth: .infinity)
            }
            .buttonStyle(.peel(.outline, size: .touch))
        }
        if invite.isPending {
            ConfirmInPlace(
                trigger: invite.status == .cancelling ? "Ask again" : "Cancel invite",
                explanation: "Get the sats back?",
                confirm: "Cancel invite", destructive: false
            ) {
                problem = nil
                do {
                    try await model.cancelInvite(invite.code)
                    dismiss()
                } catch {
                    problem = PeelError.problem(error)
                }
            }
            .disabled(invite.status == .sending)
        } else {
            Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.peel(.outline, size: .touch))
        }
    }
}
