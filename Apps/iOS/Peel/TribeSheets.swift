import PeelCore
import PeelUI
import PhotosUI
import SwiftUI

// Joining and running tribes on the phone (docs/design/iphone.md, screen
// 1's Tribes; the Mac's `SidebarForms` and `TribeViews`): Join a tribe by
// its link or QR code with the price shown, and Create a tribe or Edit
// tribe for its owner. The rules are PeelUI's (`TribeLookup`,
// `TribeSettingsDraft`) and the engine's, as on the Mac.

/// Paste, scan or pick a photo of a tribe's link, see what the tribe is and
/// what it costs, then Join, which pays only the price shown (confirmed in
/// place over the threshold). A link card opens it with the link and the
/// tribe it read: `JoinTribeSheet(link:info:)`.
struct JoinTribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissSheet) private var dismiss
    @State private var lookup: TribeLookup
    @State private var attempt = PaymentAttempt()

    init(link: String = "", info: TribeInfo? = nil) {
        _lookup = State(initialValue: TribeLookup(link: link, info: info))
    }

    var body: some View {
        @Bindable var lookup = lookup
        SheetPage(title: "Join a tribe") {
            CodeEntry(
                label: "Tribe link", prompt: "sphinx.chat://?action=tribeV2…", text: $lookup.link,
                scanTitle: "Scan a tribe's code", scanPrompt: "Point the camera at a tribe's QR code.",
                accept: { TribeLink($0) == nil ? "That code isn't a tribe link." : nil },
                choose: { $0.first { TribeLink($0) != nil } },
                // A link that arrives whole is looked up at once.
                picked: { _ in Task { await lookup.lookUp(with: model) } }
            )
            if let info = lookup.info {
                TribePreview(info: info)
            }
            if let problem = lookup.problem { ProblemText(problem) }
        } actions: {
            if let info = lookup.info {
                TouchPayButton(verb: "Join", totalMsat: info.joinAmountMsat, attempt: attempt, send: { confirmed in
                    await lookup.join(with: model, confirmedMsat: confirmed)
                }, sent: dismiss)
            } else {
                Button { Task { await lookup.lookUp(with: model) } } label: {
                    Text("Look up").frame(maxWidth: .infinity).buttonProgress(lookup.lookingUp)
                }
                .buttonStyle(.peel(.primary, size: .touch))
                // Not off while it looks up, so it keeps its fill under the
                // spinner; `lookUp` ignores a second tap.
                .disabled(lookup.link.trimmed.isEmpty)
            }
        }
        .onChange(of: lookup.link) {
            attempt.armed = nil
            attempt.problem = nil
        }
        // Opened from a link card that had not read the tribe yet.
        .task { if lookup.info == nil, !lookup.link.isEmpty { await lookup.lookUp(with: model) } }
    }
}

/// What a tribe link names, before joining: its image, name, what it is
/// about, and what joining and each message cost.
private struct TribePreview: View {
    let info: TribeInfo

    var body: some View {
        PhoneCard {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                TribeIcon(name: info.name, url: info.img, pubkey: info.pubkey, size: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name)
                        .phoneFont(PhoneFont.row.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    if let summary = info.summary?.trimmed.nilIfEmpty {
                        Text(summary)
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(4)
                    }
                    Text(info.priceLine)
                        .phoneFont(.secondary)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Create a tribe, or edit one this account owns: Basics with the image and
/// tags, Pricing, Access, as the Mac's form; editing also holds Delete,
/// confirmed in place. Prices in sats and the escrow time in hours
/// (`TribeSettingsDraft`).
struct TribeSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissSheet) private var dismiss
    /// The tribe being edited, or nil to create one.
    let editing: Tribe?

    @State private var draft = TribeSettingsDraft()
    @State private var photo: PhotosPickerItem?
    @State private var uploadingImage = false
    @State private var saving = false
    @State private var problem: String?
    @State private var fieldProblem: TribeSettingsDraft.FieldProblem?

    private var loaded: Bool { editing == nil || draft.original != nil }

    var body: some View {
        SheetPage(title: editing.map { "Edit #\($0.displayName)" } ?? "Create a tribe") {
            if loaded {
                fields
                if let editing {
                    ConfirmInPlace(trigger: "Delete tribe", explanation: "Delete #\(editing.displayName) for everyone?",
                                   confirm: "Delete") { await delete(editing) }
                        .disabled(saving)
                        .padding(.top, Theme.Space.lg)
                }
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let problem { ProblemText(problem) }
        } actions: {
            Button { Task { await save() } } label: {
                Text(editing == nil ? "Create" : "Save").frame(maxWidth: .infinity).buttonProgress(saving)
            }
            .buttonStyle(.peel(.primary, size: .touch))
            .disabled(!loaded || draft.name.trimmed.isEmpty || uploadingImage)
        }
        .onChange(of: draft.typedFields) {
            if fieldProblem != nil { fieldProblem = nil }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await upload(item) }
        }
        .task { await load() }
    }

    @ViewBuilder private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            PhoneSectionHeader("Basics")
            field("Name", .name) {
                NoteInput(label: "Name", prompt: "Required", text: $draft.name)
            }
            FieldLabel("What it is about") {
                NoteInput(label: "What it is about", prompt: "Optional", text: $draft.summary)
            }
            field("Image", .photo) { image }
            FieldLabel("Tags") { TagToggles(choices: draft.tagChoices, selection: $draft.tags) }
        }
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            PhoneSectionHeader("Pricing")
            let pay = draft.membersPay
            amount("Price to join", helper: pay.toJoin, text: $draft.priceToJoin, unit: "sats", field: .priceToJoin)
            amount("Price per message", helper: pay.perMessage, text: $draft.pricePerMessage, unit: "sats",
                   field: .pricePerMessage)
            amount("Escrow per message", helper: "Held, then paid back", text: $draft.escrow, unit: "sats", field: .escrow)
            amount("Paid back after", text: $draft.escrowHours, unit: "hours", field: .escrowHours)
        }
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            PhoneSectionHeader("Access")
            SwitchRow(label: "Private", detail: "You approve who joins.", isOn: $draft.isPrivate)
            SwitchRow(label: "Unlisted", detail: "Only people with the link can join.", isOn: $draft.unlisted)
        }
    }

    /// The image, picked from Photos and uploaded, never typed; Remove once there is one.
    private var image: some View {
        HStack(spacing: Theme.Space.md) {
            TribeIcon(name: draft.name.trimmed.nilIfEmpty ?? "?", url: draft.photoURL.nilIfEmpty,
                      pubkey: editing?.pubkey ?? "", size: 56)
                .accessibilityHidden(true)
            PhotosPicker(selection: $photo, matching: .images) {
                Text(uploadingImage ? "Uploading…" : draft.photoURL.isEmpty ? "Choose" : "Change")
            }
            .buttonStyle(.peel(.outline, size: .touch))
            .disabled(uploadingImage)
            if !draft.photoURL.isEmpty {
                Button("Remove") { draft.photoURL = "" }
                    .buttonStyle(.peel(.ghost, size: .touch))
                    .disabled(uploadingImage)
            }
        }
    }

    private func field(_ label: String, _ field: TribeSettingsDraft.Field, @ViewBuilder content: () -> some View) -> some View {
        FieldLabel(label) {
            content()
            if let text = problem(field) { ProblemText(text) }
        }
    }

    private func amount(
        _ label: String, helper: String? = nil, text: Binding<String>, unit: String, field: TribeSettingsDraft.Field
    ) -> some View {
        FieldLabel(label) {
            NumberInput(label: label, text: text, unit: unit)
            if let note = problem(field) ?? helper {
                Text(note)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func problem(_ field: TribeSettingsDraft.Field) -> String? {
        fieldProblem?.field == field ? fieldProblem?.text : nil
    }

    private func load() async {
        guard let editing, draft.original == nil else { return }
        do {
            draft = TribeSettingsDraft(try await model.tribeSettings(editing.pubkey))
        } catch {
            problem = PeelError.problem(error, couldNot: "load the tribe")
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        uploadingImage = true
        defer { uploadingImage = false }
        do {
            draft.photoURL = try await model.uploadPicture(item)
        } catch {
            fieldProblem = .init(field: .photo, text: PeelError.problem(error, couldNot: "upload the image"))
        }
    }

    private func save() async {
        guard !saving, !uploadingImage else { return }
        saving = true
        defer { saving = false }
        problem = nil
        fieldProblem = nil
        do {
            if let editing {
                try await model.updateTribe(editing.pubkey, try draft.settings())
            } else {
                try await model.createTribe(try draft.settings())
            }
            dismiss()
        } catch {
            switch TribeSettingsDraft.saveProblem(error, creating: editing == nil) {
            case .field(let field): fieldProblem = field
            case .form(let text): problem = text
            }
        }
    }

    private func delete(_ tribe: Tribe) async {
        problem = nil
        do {
            try await model.deleteTribe(tribe.pubkey)
            dismiss()
        } catch {
            problem = PeelError.problem(error, couldNot: "delete the tribe")
        }
    }
}

/// A number typed in a box on the decimal pad, its unit after it.
private struct NumberInput: View {
    let label: String
    @Binding var text: String
    let unit: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            TextField(label, text: $text, prompt: Text("0"))
                .keyboardType(.decimalPad)
                .phoneFont(.row)
                .monospacedDigit()
                .focused($focused)
            Text(unit)
                .phoneFont(.row)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: 48)
        .fieldBox(focused: focused)
    }
}

/// A switch with its label and a line under it, on its own card, as the
/// Mac's `FormSwitchRow`: a tribe's access, a chat's time zone.
struct SwitchRow: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        PhoneCard {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).phoneFont(.row).foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail).phoneFont(.secondary).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .frame(minHeight: Theme.touchTarget)
        }
    }
}

/// A tribe's tags, each a chip that turns on and off (a tick while on),
/// 44 pt tall to the touch, in lines.
private struct TagToggles: View {
    let choices: [String]
    @Binding var selection: [String]

    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(choices.prefix(16), id: \.self) { tag in
                let on = selection.contains(tag)
                Button {
                    if on { selection.removeAll { $0 == tag } } else { selection.append(tag) }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        if on { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                        Text(tag).phoneFont(.secondary).lineLimit(1)
                    }
                    .foregroundStyle(on ? Theme.selectionText : Theme.text)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(on ? Theme.selection : Theme.fieldFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.inputBorder))
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
