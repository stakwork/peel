import SwiftUI
import PeelCore

/// Create a tribe, or edit one this account owns: what the Mac app's tribe
/// form sets, in the form system's sections (Basics, Pricing, Access).
/// Prices in sats and the escrow time in hours, as people think of them;
/// the engine sends msat and milliseconds. Editing also holds Delete, its
/// own section, confirmed in place.
struct TribeSettingsForm: View {
    @Environment(AppModel.self) private var model
    /// The tribe being edited, or nil to create one.
    let editing: Tribe?
    let done: () -> Void

    @State private var name = ""
    @State private var summary = ""
    @State private var photoURL = ""
    @State private var priceToJoin = ""
    @State private var pricePerMessage = ""
    @State private var escrow = ""
    @State private var escrowHours = ""
    @State private var isPrivate = false
    @State private var unlisted = false
    /// What the tribe had, so a field left as it was shown sends exactly that.
    @State private var original: TribeSettings?
    /// What is on its way: Create or Save (which spins), or Delete.
    @State private var working: Action?
    @State private var problem: String?
    /// What is wrong with one field, shown under it until a field changes.
    @State private var fieldProblem: FieldProblem?

    private enum Action { case save, delete }
    /// A field that can have its own problem, named as the engine's words name it.
    private enum Field: String {
        case name, photo = "image", priceToJoin = "price to join", pricePerMessage = "price per message"
        case escrow, escrowHours = "escrow time"

        /// The field an engine refusal is about, if it is about one.
        init?(_ failure: Engine.Failure) {
            switch failure {
            case .tribeNeedsName: self = .name
            case .tribeImageNotHTTPS: self = .photo
            default: return nil
            }
        }
    }

    private struct FieldProblem: Error {
        let field: Field
        let text: String
    }

    private var loaded: Bool { editing == nil || original != nil }

    var body: some View {
        // Its own buttons do not close it while a save or delete runs.
        FormPopover(title: editing.map { "Edit #\($0.displayName)" } ?? "Create a tribe", close: { if working == nil { done() } }) {
            if loaded {
                fields
                if let editing {
                    FormDestructiveSection(
                        trigger: "Delete tribe…", prompt: "Delete #\(editing.displayName) for everyone?", confirm: "Delete"
                    ) {
                        await delete()
                    }
                    .disabled(working == .save)
                }
            } else if problem == nil {
                TribeServerProgress().padding(.vertical, 12)
            }
        } footer: {
            FormFooter(problem: problem) {
                Button("Cancel", action: done)
                    .buttonStyle(FormButtonStyle())
                    .disabled(working != nil)
                Button { Task { await save() } } label: {
                    Text(editing == nil ? "Create" : "Save").buttonProgress(working == .save)
                }
                .buttonStyle(FormButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                // Not off while it saves, so it keeps its fill under the
                // spinner; `save` ignores a second click.
                .disabled(working == .delete || !loaded || name.trimmed.isEmpty)
            }
        }
        .onChange(of: [name, photoURL, priceToJoin, pricePerMessage, escrow, escrowHours]) {
            if fieldProblem != nil { fieldProblem = nil }
        }
        .task { await load() }
    }

    @ViewBuilder private var fields: some View {
        FormSection("Basics") {
            FormItem(label: "Name", problem: problem(.name)) {
                FormTextField(label: "Name", prompt: "Required", text: $name, problem: problem(.name) != nil)
            }
            FormItem(label: "What it is about", helper: "Shown in the tribes directory and the header.") {
                FormTextField(label: "What it is about", text: $summary, axis: .vertical)
            }
            FormItem(label: "Image link", problem: problem(.photo)) {
                HStack(spacing: 8) {
                    FormTextField(label: "Image link", prompt: "https://", text: $photoURL, problem: problem(.photo) != nil)
                    // The tribe's image while the link is the one it has, its
                    // initial otherwise: nothing is fetched while you type.
                    TribeIcon(
                        name: name.trimmed.nilIfEmpty ?? "?",
                        url: original?.photoURL.flatMap { $0 == photoURL.trimmed ? $0 : nil },
                        pubkey: editing?.pubkey ?? "", size: 32
                    )
                }
            }
        }
        FormSection("Pricing") {
            // Two to a line.
            HStack(alignment: .top, spacing: 12) {
                amountItem("Price to join", text: $priceToJoin, unit: "sats", field: .priceToJoin)
                amountItem("Price per message", text: $pricePerMessage, unit: "sats", field: .pricePerMessage)
            }
            HStack(alignment: .top, spacing: 12) {
                amountItem("Escrow per message", helper: "Held, then paid back", text: $escrow, unit: "sats", field: .escrow)
                amountItem("Paid back after", text: $escrowHours, unit: "hours", field: .escrowHours)
            }
        }
        FormSection("Access") {
            FormSwitchRow(label: "Private", detail: "People ask to join and you approve them.", isOn: $isPrivate)
            FormSwitchRow(label: "Unlisted", detail: "Not shown in the tribes directory; joined by link only.", isOn: $unlisted)
        }
    }

    private func amountItem(
        _ label: String, helper: String? = nil, text: Binding<String>, unit: String, field: Field
    ) -> some View {
        let problem = problem(field)
        return FormItem(label: label, helper: helper, problem: problem) {
            FormNumberField(label: label, text: text, unit: unit, problem: problem != nil)
        }
    }

    private func problem(_ field: Field) -> String? {
        fieldProblem?.field == field ? fieldProblem?.text : nil
    }

    private func load() async {
        guard let editing else { return }
        do {
            let settings = try await model.tribeSettings(editing.pubkey)
            name = settings.name
            summary = settings.summary ?? ""
            photoURL = settings.photoURL ?? ""
            priceToJoin = Sats.text(settings.priceToJoinMsat, unit: Sats.msatPerSat)
            pricePerMessage = Sats.text(settings.pricePerMessageMsat, unit: Sats.msatPerSat)
            escrow = Sats.text(settings.escrowMsat, unit: Sats.msatPerSat)
            escrowHours = Sats.text(settings.escrowMillis, unit: Sats.millisecondsPerHour)
            isPrivate = settings.isPrivate
            unlisted = settings.unlisted
            original = settings
        } catch {
            problem = "Could not load the tribe: \(PeelError.readable(error))"
        }
    }

    private func settings() throws -> TribeSettings {
        /// A field still showing what the tribe had sends exactly that, even
        /// where the shown text was rounded (an escrow time of 20 minutes).
        /// A number that does not parse is that field's problem.
        func value(
            _ text: String, unit: UInt64, _ stored: KeyPath<TribeSettings, UInt64>, _ field: Field
        ) throws -> UInt64 {
            if let original, text == Sats.text(original[keyPath: stored], unit: unit) { return original[keyPath: stored] }
            do {
                return try Sats.parse(text, unit: unit, of: field.rawValue)
            } catch {
                throw FieldProblem(field: field, text: Formatting.sentence(error))
            }
        }
        return TribeSettings(
            name: name, summary: summary, photoURL: photoURL,
            pricePerMessageMsat: try value(pricePerMessage, unit: Sats.msatPerSat, \.pricePerMessageMsat, .pricePerMessage),
            priceToJoinMsat: try value(priceToJoin, unit: Sats.msatPerSat, \.priceToJoinMsat, .priceToJoin),
            escrowMsat: try value(escrow, unit: Sats.msatPerSat, \.escrowMsat, .escrow),
            escrowMillis: try value(escrowHours, unit: Sats.millisecondsPerHour, \.escrowMillis, .escrowHours),
            isPrivate: isPrivate, unlisted: unlisted
        )
    }

    private func save() async {
        guard working == nil else { return }
        working = .save
        defer { working = nil }
        problem = nil
        fieldProblem = nil
        do {
            if let editing {
                try await model.updateTribe(editing.pubkey, try settings())
            } else {
                try await model.createTribe(try settings())
            }
            done()
        } catch let error as FieldProblem {
            fieldProblem = error
        } catch let failure as Engine.Failure {
            if let field = Field(failure) {
                fieldProblem = FieldProblem(field: field, text: Formatting.sentence(failure))
            } else {
                problem = PeelError.readable(failure)
            }
        } catch {
            problem = PeelError.readable(error)
        }
    }

    private func delete() async {
        guard let editing, working == nil else { return }
        working = .delete
        defer { working = nil }
        do {
            try await model.deleteTribe(editing.pubkey)
            done()
        } catch {
            problem = "Could not delete: \(PeelError.readable(error))"
        }
    }
}

/// A small secondary label: a heading inside a popover list, or a field's name.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.font(12, .medium))
            .foregroundStyle(Theme.secondaryText)
    }
}

/// While a tribes server is asked.
struct TribeServerProgress: View {
    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Asking the tribes server…")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// Approve and Decline for a request to join. Once an answer has gone out
/// they stay off (each answer costs the tribe's price), showing what was
/// sent until the tribe's copy of it replaces this row.
struct JoinRequestButtons: View {
    /// Returns whether the answer went out.
    let answer: (_ approve: Bool) async -> Bool

    /// The answer on its way, as `sent`: true to approve, false to decline.
    @State private var sending: Bool?
    @State private var sent: Bool?

    var body: some View {
        HStack(spacing: 10) {
            if let sent {
                Text(sent ? "Approving…" : "Declining…")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Button { run(false) } label: { Text("Decline").buttonProgress(sending == false, size: .mini) }
                    .foregroundStyle(Theme.secondaryText)
                Button { run(true) } label: { Text("Approve").buttonProgress(sending == true, size: .mini) }
                    .foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(.plain)
        .font(Theme.font(12, .medium))
        .disabled(sending != nil)
    }

    private func run(_ approve: Bool) {
        sending = approve
        Task {
            if await answer(approve) { sent = approve }
            sending = nil
        }
    }
}

/// "Name wants to join", in a private tribe's chat, with the owner's answer
/// or the buttons to give one, as the Mac app shows requests inline.
struct JoinRequestNote: View {
    @Environment(AppModel.self) private var model
    let message: Message
    /// Whether the owner approved, once answered.
    let approved: Bool?
    let canAnswer: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(message.senderAlias ?? Sender.unnamed) wants to join")
            if let approved {
                Text(approved ? "· Approved" : "· Declined")
            } else if canAnswer {
                JoinRequestButtons { approve in await model.answerJoinRequest(message, approve: approve) }
            }
        }
        .font(Theme.font(12))
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

/// The message the owner pinned, under the tribe's header, read from
/// storage however old (Tom, Q5); the Mac app shows it only when it is
/// among the messages loaded.
struct PinnedMessageBar: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let tribe: Tribe

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text(message.fromMe ? "You" : message.senderAlias ?? Sender.unnamed)
                .font(Theme.font(12, .medium))
            Text(message.preview)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .help(message.content ?? "")
            Spacer(minLength: 8)
            if tribe.canManage {
                Button("Unpin") { Task { await model.pin(nil, in: tribe.pubkey) } }
                    .buttonStyle(.plain)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
        // Unpin keeps its own clicks; anywhere else goes to the message.
        .contentShape(Rectangle())
        .onTapGesture { model.focus(on: message) }
        .peelMenu {
            var entries: [MenuEntry] = []
            if let text = message.content?.trimmed.nilIfEmpty {
                entries.append(.copyText(text))
            }
            if tribe.canManage {
                entries.append(.button("Unpin from top of tribe", systemImage: "pin.slash") {
                    Task { await model.pin(nil, in: tribe.pubkey) }
                })
            }
            return entries
        }
    }
}

/// In place of the composer when this account cannot post: waiting for
/// approval, declined, removed, or the tribe deleted. Removing it from Peel
/// is confirmed in place.
struct TribeStatusBar: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe

    @State private var problem: String?

    private var text: String {
        switch tribe.status {
        case .pending: "Waiting for the owner to approve your request to join."
        case .rejected: "The owner declined your request to join."
        case .removed: "The owner removed you from this tribe."
        case .deleted: "The owner deleted this tribe."
        case .active: "You are not in this tribe."
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if tribe.status == .pending {
                ProgressView().controlSize(.small)
            }
            Text(problem ?? text)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            InlineConfirm(trigger: "Remove from Peel", prompt: "Remove #\(conversation.name) from Peel?", confirm: "Remove") {
                do {
                    try await model.leaveTribe(tribe.pubkey)
                } catch {
                    problem = "Could not remove: \(PeelError.readable(error))"
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .panelBoxed()
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }
}

/// Tribe messages that mention you, newest first, followed while this is
/// open. Clicking one opens its tribe.
struct MentionsView: View {
    @Environment(AppModel.self) private var model
    @State private var mentions: [Message] = []
    @State private var problem: String?

    var body: some View {
        Group {
            if mentions.isEmpty {
                EmptyPlace(title: "Mentions", message: problem ?? "Messages that mention you show up here.")
            } else {
                let names = Dictionary(model.conversations.map { ($0.chat, $0.name) }, uniquingKeysWith: { $1 })
                VStack(spacing: 0) {
                    DetailHeader(title: "Mentions")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(mentions) { message in
                                MentionRow(message: message, tribeName: names[message.chat])
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .task {
            do {
                guard let updates = model.mentionUpdates() else { return }
                for try await rows in updates { mentions = rows }
            } catch {
                problem = PeelError.readable(error)
            }
        }
    }
}

private struct MentionRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let tribeName: String?

    var body: some View {
        let details = message.senderDetails, alias = details.alias
        Button {
            model.focus(on: message)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                let hue = model.hue(pubkey: message.chat, alias: alias, inTribe: true)
                Avatar(name: alias ?? "?", url: details.photoURL, size: 28, hue: hue)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(alias ?? Sender.unnamed)
                            .font(Theme.font(13, .medium))
                            .foregroundStyle(hue.name)
                        Text("in #\(tribeName ?? String(message.chat.prefix(12)))")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer(minLength: 8)
                        Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(Theme.font(11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(LinkText.attributed(message.content ?? "", myAliases: model.mentionAliases(in: message.chat)))
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.text)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(selected: false))
        .peelMenu {
            var entries: [MenuEntry] = [.button("Open in #\(tribeName ?? "tribe")", systemImage: "number") {
                model.focus(on: message)
            }]
            if let text = message.content?.trimmed.nilIfEmpty {
                entries.append(.copyText(text))
            }
            return entries
        }
    }
}
