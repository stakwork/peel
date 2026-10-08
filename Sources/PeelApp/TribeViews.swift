import SwiftUI
import PeelCore

/// Create a tribe, or edit one this account owns: what the Mac app's tribe
/// form sets. Prices in sats and the escrow time in hours, as people think
/// of them; the engine sends msat and milliseconds. Editing also holds
/// Delete, confirmed in place.
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

    private enum Action { case save, delete }

    private var loaded: Bool { editing == nil || original != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing.map { "Edit #\($0.displayName)" } ?? "Create a tribe")
                .font(Theme.font(15, .bold))
            if loaded {
                fields
            } else if problem == nil {
                TribeServerProgress()
            }
            if editing != nil, loaded {
                Theme.divider.frame(height: 1)
                HStack {
                    InlineConfirm(trigger: "Delete tribe", prompt: "Delete it for everyone?", confirm: "Delete") {
                        await delete()
                    }
                    .disabled(working != nil)
                    Spacer()
                }
            }
            FormFooter(problem: problem) {
                Button { Task { await save() } } label: {
                    Text(editing == nil ? "Create" : "Save").buttonProgress(working == .save)
                }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(working != nil || !loaded || name.trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .task { await load() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("What it is about", text: $summary, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            TextField("Image link (https)", text: $photoURL)
                .textFieldStyle(.roundedBorder)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    SectionLabel("Price to join", weight: .regular)
                    SectionLabel("Price per message", weight: .regular)
                }
                GridRow {
                    AmountField(text: $priceToJoin, unit: "sats")
                    AmountField(text: $pricePerMessage, unit: "sats")
                }
                GridRow {
                    SectionLabel("Escrow per message", weight: .regular)
                    SectionLabel("Paid back after", weight: .regular)
                }
                GridRow {
                    AmountField(text: $escrow, unit: "sats")
                    AmountField(text: $escrowHours, unit: "hours")
                }
            }
            Toggle(isOn: $isPrivate) {
                ToggleLabel("Private", detail: "People ask to join and you approve them.")
            }
            Toggle(isOn: $unlisted) {
                ToggleLabel("Unlisted", detail: "Not shown in the tribes directory; joined by link only.")
            }
        }
        .toggleStyle(.checkbox)
    }

    private func load() async {
        guard let editing else { return }
        do {
            let settings = try await model.tribeSettings(editing.pubkey)
            name = settings.name
            summary = settings.summary ?? ""
            photoURL = settings.photoURL ?? ""
            priceToJoin = Self.text(settings.priceToJoinMsat, unit: 1000)
            pricePerMessage = Self.text(settings.pricePerMessageMsat, unit: 1000)
            escrow = Self.text(settings.escrowMsat, unit: 1000)
            escrowHours = Self.text(settings.escrowMillis, unit: 3_600_000)
            isPrivate = settings.isPrivate
            unlisted = settings.unlisted
            original = settings
        } catch {
            problem = "Could not load the tribe: \(PeelError.readable(error))"
        }
    }

    /// An amount in the unit people type, blank for zero as the Mac app shows them.
    private static func text(_ value: UInt64, unit: UInt64) -> String {
        // A point for the decimals whatever the locale, as `Sats.parse` reads them.
        value == 0 ? "" : (Decimal(value) / Decimal(unit)).formatted(
            .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...6))
        )
    }

    private func settings() throws -> TribeSettings {
        /// A field still showing what the tribe had sends exactly that, even
        /// where the shown text was rounded (an escrow time of 20 minutes).
        func value(_ text: String, unit: UInt64, of what: String, _ stored: KeyPath<TribeSettings, UInt64>) throws -> UInt64 {
            if let original, text == Self.text(original[keyPath: stored], unit: unit) { return original[keyPath: stored] }
            return try Sats.parse(text, unit: unit, of: what)
        }
        return TribeSettings(
            name: name, summary: summary, photoURL: photoURL,
            pricePerMessageMsat: try value(pricePerMessage, unit: 1000, of: "price per message", \.pricePerMessageMsat),
            priceToJoinMsat: try value(priceToJoin, unit: 1000, of: "price to join", \.priceToJoinMsat),
            escrowMsat: try value(escrow, unit: 1000, of: "escrow", \.escrowMsat),
            escrowMillis: try value(escrowHours, unit: 3_600_000, of: "escrow time", \.escrowMillis),
            isPrivate: isPrivate, unlisted: unlisted
        )
    }

    private func save() async {
        guard working == nil else { return }
        working = .save
        defer { working = nil }
        problem = nil
        do {
            if let editing {
                try await model.updateTribe(editing.pubkey, try settings())
            } else {
                try await model.createTribe(try settings())
            }
            done()
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

/// A number field with its unit after it.
private struct AmountField: View {
    @Binding var text: String
    let unit: String

    var body: some View {
        HStack(spacing: 6) {
            TextField("0", text: $text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            Text(unit)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 36, alignment: .leading)
        }
    }
}

private struct ToggleLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.font(13))
            Text(detail)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// A small secondary label: a heading inside a popover list, or a field's name.
struct SectionLabel: View {
    let text: String
    var weight: Font.Weight = .medium

    init(_ text: String, weight: Font.Weight = .medium) {
        self.text = text
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(Theme.font(12, weight))
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

/// An action confirmed right next to its button, never in a dialog: the
/// button, then the prompt with Cancel and the action in red. Off while the
/// action runs; the action reports its own failure.
struct InlineConfirm: View {
    let trigger: String
    var prompt: String?
    let confirm: String
    let action: () async -> Void

    @State private var confirming = false
    @State private var working = false

    var body: some View {
        HStack(spacing: 8) {
            if confirming {
                if let prompt {
                    Text(prompt)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Button("Cancel") { confirming = false }
                Button {
                    working = true
                    Task {
                        await action()
                        working = false
                        confirming = false
                    }
                } label: {
                    Text(confirm).foregroundStyle(Theme.destructive)
                }
            } else {
                Button(trigger) { confirming = true }
            }
        }
        .disabled(working)
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
            Text("\(message.senderAlias ?? "Someone") wants to join")
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

/// The message the owner pinned, under the tribe's header. The Mac app
/// shows it only when the message is here; so does Peel.
struct PinnedMessageBar: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let tribe: Tribe

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text(message.fromMe ? "You" : message.senderAlias ?? "Someone")
                .font(Theme.font(12, .medium))
            Text(message.content ?? "")
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
                        Text(alias ?? "Someone")
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
