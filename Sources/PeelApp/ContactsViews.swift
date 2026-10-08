import SwiftUI
import UniformTypeIdentifiers
import PeelCore
#if os(macOS)
import AppKit
#endif

// MARK: - Model

extension AppModel {
    /// Adds whoever a scanned or pasted code names (`Engine.addContact(code:)`),
    /// through the engine's payment checks: the key exchange pays 5 sats.
    /// Someone already a contact is not added again: their chat opens.
    /// Returns whether a key exchange was started, once the engine went ahead.
    func addContact(code: String, alias: String, confirmedMsat: UInt64?) async -> (PaymentOutcome, Bool?) {
        var added: Bool?
        let outcome = await pay("add contact") {
            let (pubkey, started) = try await $0.addContact(code: code, alias: alias.trimmed, confirmedMsat: confirmedMsat)
            if !started { destination = .chat(pubkey) }
            added = started
        }
        return (outcome, added)
    }

    /// Makes an invite with sats, through the engine's payment checks; the
    /// engine always asks to confirm the amount first.
    func makeInvite(
        amountMsat: UInt64, nickname: String, message: String, confirmedMsat: UInt64?
    ) async -> (PaymentOutcome, InviteRecord?) {
        var made: InviteRecord?
        let outcome = await pay("invite") {
            made = try await $0.makeInvite(
                amountMsat: amountMsat, nickname: nickname, message: message, confirmedMsat: confirmedMsat
            )
        }
        return (outcome, made)
    }

    func cancelInvite(_ code: String) async throws {
        try await signedIn().cancelInvite(code: code)
    }

    func forgetInvite(_ code: String) async throws {
        try await signedIn().forgetInvite(code: code)
    }
}

// MARK: - Sidebar

/// The end of Direct messages: invites waiting to be used, then Add contact
/// and Invite someone.
struct ContactsSidebarRows: View {
    var body: some View {
        PendingInviteRows()
        SidebarActionLink(title: "Add contact") { AddContactForm(done: $0) }
        SidebarActionLink(title: "Invite someone") { InviteForm(done: $0) }
    }
}

/// "New" on a direct message whose contact added this account and that has
/// not been read since. The core accepts someone who adds us at once, so
/// there is no request to answer: this only says they are new.
struct NewContactBadge: View {
    var body: some View {
        UnreadBadge(text: "New", foreground: Theme.buttonText, fill: Theme.accent)
            .help("Added you as a contact")
    }
}

private struct PendingInviteRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 1) {
            ForEach(model.pendingInvites) { invite in
                InviteRow(invite: invite)
            }
        }
    }
}

private struct InviteRow: View {
    let invite: InviteRecord
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 9) {
                InviteIcon(size: 18)
                    .frame(width: 18)
                Text(invite.nickname ?? "Invite")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(shortStatus)
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .buttonStyle(SidebarRowStyle(selected: showing))
        .help("Invite with \(Sats.format(msat: invite.amountMsat)), waiting to be used")
        .peelPopover(isPresented: $showing) {
            InviteDetail(code: invite.code, done: { showing = false })
        }
    }
}

private extension InviteRow {
    /// What the row says beside the name: the amount once it can be shared.
    var shortStatus: String {
        switch invite.status {
        case .sending: "Sending…"
        case .cancelling: "Cancelling…"
        default: Sats.format(msat: invite.amountMsat)
        }
    }
}

/// An invite is a person who is not here yet: a dashed circle, as Payments
/// draws someone not known.
private struct InviteIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.tertiaryText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            Image(systemName: "envelope")
                .font(.system(size: size * 0.45))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Add contact

/// Add someone by their contact info, an invite (its inviter is added) or a
/// Sphinx link, typed or pasted, or read from a QR code in a picture: dropped
/// on the form, pasted, or chosen. No camera: a code on a phone is
/// screenshotted or photographed first.
struct AddContactForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var text = ""
    /// What `text` is, read once per change.
    @State private var code: ContactCode?
    @State private var codeProblem: String?
    /// The text a picture or the clipboard gave: why it adds nobody shows at once.
    @State private var scannedText: String?
    @State private var name = ""
    @State private var reading = false
    @State private var attempt = PaymentAttempt()
    @State private var dropTargeted = false
    @State private var problem: String?
    /// The key exchange went out to this name.
    @State private var sentTo: String?

    var body: some View {
        FormPopover(title: "Add contact", close: done) {
            if let sentTo {
                Text("Sent to \(sentTo). They show under Direct messages once their app answers.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            } else {
                form
            }
        } footer: {
            if sentTo != nil {
                FormFooter(problem: nil) {
                    Button("Done", action: done)
                        .buttonStyle(FormButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                FormFooter(problem: problem ?? attempt.problem ?? (text == scannedText ? codeProblem : nil) ?? tribeProblem) {
                    Button("Cancel", action: done)
                        .buttonStyle(FormButtonStyle())
                        .disabled(attempt.working)
                    // Over the threshold the 5 sats are confirmed in place, as any payment.
                    PayButton(
                        verb: "Add", totalMsat: reading || text.trimmed.isEmpty ? nil : Engine.keyExchangeMsat, attempt: attempt
                    ) { confirmed in
                        let (outcome, added) = await model.addContact(code: text, alias: name, confirmedMsat: confirmed)
                        if added == false { done() }
                        if added == true { sentTo = name.trimmed.nilIfEmpty ?? code?.inviterName ?? "them" }
                        return outcome
                    }
                }
            }
        }
        #if os(macOS)
        .onDrop(of: PasteboardFiles.dropTypes + [.plainText], delegate: CodeDrop(targeted: $dropTargeted) { codes in
            Task { await read(codes) }
        })
        #endif
    }

    @ViewBuilder private var form: some View {
        FormSection {
            FormRow(label: "Code", stacked: true) {
                FormTextField(label: "Code", prompt: "Contact info, invite or Sphinx link", text: $text, axis: .vertical)
            }
            if let code, let pubkey = code.pubkey {
                CodePreview(code: code, pubkey: pubkey)
            }
        }
        .onChange(of: text, initial: true) {
                problem = nil
                attempt.armed = nil
                attempt.problem = nil
                do {
                    code = try ContactCode.read(text)
                    codeProblem = nil
                } catch {
                    code = nil
                    codeProblem = Formatting.sentence(error)
                }
            }
        scanZone
            .padding(.top, 10)
        FormSection {
            FormRow(label: "Name") {
                FormTextField(label: "Name", prompt: code.flatMap(\.inviterName) ?? "Optional", text: $name)
            }
        }
    }

    /// Where a picture goes: the whole form takes a drop; this says so.
    private var scanZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 20))
                .foregroundStyle(dropTargeted ? Theme.accent : Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading ? "Reading the picture…" : "Drop a picture of their QR code here")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 10) {
                    #if os(macOS)
                    Button("Paste") { Task { await read { try await CodeSource.codesOnClipboard() } } }
                    #endif
                    Button("Choose picture…") {
                        guard let file = model.choosePicture() else { return }
                        Task { await read { try await CodeSource.codes(inFile: file) } }
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.link)
                .disabled(reading || attempt.working)
            }
            Spacer(minLength: 0)
            if reading { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private var tribeProblem: String? {
        if case .tribe = code { Formatting.sentence(Engine.Failure.tribeLinkNotContact) } else { nil }
    }

    /// Puts the first code that names someone into the field; else says
    /// why none does.
    private func read(_ codes: @escaping () async throws -> [String]) async {
        reading = true
        defer { reading = false }
        problem = nil
        do {
            let found = try await codes()
            guard let chosen = ContactCode.likeliest(in: found) else {
                problem = "No QR code found in that picture."
                return
            }
            scannedText = chosen
            text = chosen
        } catch {
            problem = PeelError.readable(error)
        }
    }
}

/// Who the code adds: contact info by its short key; an invite by its
/// inviter, with what happens to its sats. A row of the code's section.
private struct CodePreview: View {
    @Environment(AppModel.self) private var model
    let code: ContactCode
    let pubkey: String

    var body: some View {
        HStack(spacing: 10) {
            Avatar(
                name: code.inviterName ?? "", url: nil, size: 28,
                hue: model.hue(pubkey: pubkey, alias: code.inviterName, inTribe: false)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(code.inviterName ?? Formatting.shortKey(pubkey))
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var detail: String {
        switch code {
        case .invite: "An invite for a new account. Peel adds who sent it; its sats stay in the invite."
        default: "Contact info"
        }
    }
}

/// Where scanned codes come from on a Mac: a drag's or the clipboard's
/// pictures (files, image data, the screenshot thumbnail's promised file,
/// read as the composer reads them, `PasteboardFiles`) or text. Pictures are
/// read off the main thread; promised files are Peel's own and go after.
@MainActor
enum CodeSource {
    #if os(macOS)
    /// The clipboard's picture, else its text.
    static func codesOnClipboard() async throws -> [String] {
        let board = NSPasteboard.general
        return try await codes(in: PasteboardFiles.items(on: board, promises: false), text: board.string(forType: .string))
    }

    /// The first picture's codes, else the text.
    static func codes(in items: [PasteboardFiles.Item], text: String?) async throws -> [String] {
        guard let item = items.first else { return text.map { [$0] } ?? [] }
        switch item {
        case .file(let file):
            return try await codes(inFile: file)
        case .image(let data, _):
            return try await Task.detached { try QRImage.codes(in: data) }.value
        case .promised(let files):
            for await written in files {
                let file = try written.get()
                defer { IncomingFiles.discard(file) }
                return try await codes(inFile: file)
            }
            return []
        }
    }
    #endif

    static func codes(inFile file: URL) async throws -> [String] {
        try await Task.detached { try QRImage.codes(inFile: file) }.value
    }
}

#if os(macOS)
/// A picture or text dropped anywhere on the Add contact form, read from the
/// drag's own pasteboard as the composer's drop is (file promises included).
private struct CodeDrop: DropDelegate {
    @Binding var targeted: Bool
    let read: (_ codes: @escaping () async throws -> [String]) -> Void

    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        // Read now: a drag's pasteboard is gone after the drop.
        let drag = NSPasteboard(name: .drag)
        let items = PasteboardFiles.items(on: drag, promises: true)
        let text = drag.string(forType: .string)
        guard !items.isEmpty || text != nil else { return false }
        read { try await CodeSource.codes(in: items, text: text) }
        return true
    }
}
#endif

// MARK: - Invites

/// Make an invite with sats for someone without an account. The amount is
/// always confirmed in place ("Invite 2,000 sats", then again), and goes
/// through the engine's balance and threshold checks.
struct InviteForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @State private var amount = ""
    @State private var nickname = ""
    @State private var message = ""
    @State private var attempt = PaymentAttempt()
    @State private var made: InviteRecord?

    var body: some View {
        if let made {
            InviteDetail(code: made.code, done: done)
        } else {
            FormPopover(title: "Invite someone", close: done) {
                note("An invite holds sats for someone new: they sign up with it, get the sats and have you as a contact.")
                    .padding(.top, 6)
                FormSection {
                    FormRow(label: "Amount") { SatsField(label: "Amount", text: $amount) }
                }
                FormSection("Only you see these") {
                    FormRow(label: "Nickname") {
                        FormTextField(label: "Nickname", prompt: "Optional", text: $nickname)
                    }
                    FormRow(label: "Message", stacked: true) {
                        FormTextField(label: "Message", prompt: "Optional", text: $message, axis: .vertical)
                    }
                }
                note("The sats leave your balance now. The server may keep a fee from them; cancelling returns the rest.")
                    .padding(.top, 10)
            } footer: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let problem = attempt.problem { ProblemText(problem) }
                        BalanceLine()
                    }
                    Spacer()
                    Button("Cancel", action: done)
                        .buttonStyle(FormButtonStyle())
                        .disabled(attempt.working)
                    PayButton(verb: "Invite", totalMsat: Sats.msat(amount), attempt: attempt) { confirmed in
                        guard let msat = Sats.msat(amount) else { return .refused("Enter an amount in sats.") }
                        let (outcome, invite) = await model.makeInvite(
                            amountMsat: msat, nickname: nickname, message: message, confirmedMsat: confirmed
                        )
                        if let invite { made = invite }
                        return outcome
                    }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// One invite: its QR code and link to copy or share once the server holds
/// its sats, what it holds, the private nickname and message, and Cancel,
/// confirmed in place, for the sats back.
private struct InviteDetail: View {
    @Environment(AppModel.self) private var model
    let code: String
    let done: () -> Void

    @State private var problem: String?

    private var invite: InviteRecord? { model.invites[code] }

    var body: some View {
        FormPopover(title: invite?.nickname ?? "Invite", close: done) {
            if let invite {
                content(invite)
            } else {
                ProgressView().controlSize(.small).padding(.vertical, 12)
            }
        } footer: {
            if let invite { footer(invite) }
        }
    }

    @ViewBuilder private func content(_ invite: InviteRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            QRCodeTile(text: invite.status == .ready ? invite.link : nil, label: "QR code of the invite")
            VStack(alignment: .leading, spacing: 4) {
                Text(Sats.format(msat: invite.amountMsat))
                    .font(Theme.font(15, .semibold))
                    .monospacedDigit()
                Text(Self.statusLine(invite))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = invite.message {
                    Text(message)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(4)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .formCard()
        .padding(.top, 12)
        if invite.status == .ready {
            VStack(alignment: .leading, spacing: 10) {
                Text("Send it to them yourself: whoever has it can sign up with its sats.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    CopyButton("Copy invite", text: invite.link)
                    CopyButton("Copy QR", systemImage: "qrcode") { QRCode.copyImage(invite.link) }
                    ShareLink(item: invite.link) { Image(systemName: "square.and.arrow.up") }
                        .help("Share the invite")
                        .accessibilityLabel("Share the invite")
                }
                .buttonStyle(FormButtonStyle())
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)
        }
    }

    /// Why the last try failed, then Remove, Cancel invite or Done.
    private func footer(_ invite: InviteRecord) -> some View {
        HStack {
            if let problem { ProblemText(problem) }
            Spacer()
            if invite.status == .cancelling {
                // The server never answered: used, or the sats came back unseen.
                Button("Remove from list") {
                    Task {
                        do {
                            try await model.forgetInvite(invite.code)
                            done()
                        } catch {
                            problem = Formatting.sentence(error)
                        }
                    }
                }
                .buttonStyle(FormButtonStyle())
            }
            if invite.isPending {
                InlineConfirm(
                    trigger: invite.status == .cancelling ? "Ask again" : "Cancel invite",
                    prompt: "Get the sats back?", confirm: "Cancel invite"
                ) {
                    do {
                        try await model.cancelInvite(invite.code)
                        done()
                    } catch {
                        problem = Formatting.sentence(error)
                    }
                }
                .disabled(invite.status == .sending)
            } else {
                Button("Done", action: done).buttonStyle(FormButtonStyle())
            }
        }
    }

    static func statusLine(_ invite: InviteRecord) -> String {
        let made = "Made \(invite.created.formatted(date: .abbreviated, time: .shortened))"
        return switch invite.status {
        case .sending: "Waiting for the server to confirm"
        case .ready: "\(made) · waiting to be used"
        case .cancelling: "Cancelling: the server has not sent the sats back"
        case .cancelled: "Cancelled; the sats came back"
        case .used: "Used"
        case .failed: "Not made: the payment failed"
        }
    }
}
