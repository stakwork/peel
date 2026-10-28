import SwiftUI
import PeelCore
import PeelUI

/// The account screen: who others see, how to be added, money, the agent,
/// dictation, screen recording, notifications, the words and PIN that guard the account on
/// this Mac, and leaving it. Opened from the top of the sidebar or with ⌘,;
/// its categories (`AccountCategories`, in `SidebarColumn`) stand where the
/// chats were, and the chosen one fills the detail. Every change is an `AppModel` operation.
struct AccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let page = AccountPage.shown(in: model)
        VStack(spacing: 0) {
            DetailHeader(title: page.title)
            ScrollView {
                // Settings, not a form: facts of what is set on cards
                // (`SettingsSection`); a text field, when one opens, is a
                // `FormItem`.
                VStack(alignment: .leading, spacing: 18) {
                    content(page)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
                // In the scroll view as well: a click there never reaches a gesture outside it.
                .endsEditingOnClick()
            }
            // Each category from its top.
            .id(page)
        }
        .endsEditingOnClick()
        .font(Theme.font(13))
    }

    @ViewBuilder private func content(_ page: AccountPage) -> some View {
        switch page {
        case .profile:
            IdentitySection()
            ContactInfoSection()
            SettingsSection {
                NameRow()
                TimeZoneRow()
                Fact("Server") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.myServer ?? "None")
                            .textSelection(.enabled)
                        Text(model.connection.label)
                            .muted()
                    }
                }
            }
        case .payments:
            SettingsSection {
                Fact("Balance") {
                    Text(model.balanceText ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(model.balanceMsat == nil ? Theme.secondaryText : Theme.text)
                }
                Fact("Confirm payments") {
                    PaymentConfirmationRow()
                }
                Fact("Boost amount") {
                    BoostAmountRow()
                }
            }
        case .assistant:
            if let agent = model.agent { AgentSettingsSection(agent: agent) }
        case .brain:
            BrainSection()
        case .connections:
            ConnectionsSection()
        case .dictation:
            DictationSettingsSection()
        case .recording:
            RecordingSettingsSection()
        case .notifications:
            SettingsSection {
                NotificationsRow()
                NotificationTextRow()
                NotificationStyleRow()
                NotificationSoundRow()
            }
        case .security:
            SettingsSection {
                if model.profile?.requiresPIN == true {
                    ChangePINRow()
                    PINTimeoutRow()
                }
                WordsRow()
                WebsiteDataRow()
            }
            ForgetAccountControl(
                trigger: "Forget this account on this Mac…",
                explanation: model.brain?.moved != nil
                    ? "Removes the account and its messages from this Mac. Your assistant still runs on your home server: "
                        + "turn off Always on first, or wipe that box, before you sign in with your twelve words anywhere."
                    : "Removes the account and its messages from this Mac. You need your twelve words to sign back in.",
                section: true
            )
        }
    }
}

typealias AccountPage = AppModel.AccountPage

extension AccountPage {
    var title: String {
        switch self {
        case .profile: "Profile"
        case .payments: "Payments"
        case .assistant: "Assistant"
        case .brain: "Always on"
        case .connections: "Connections"
        case .dictation: "Dictation"
        case .recording: "Recording"
        case .notifications: "Notifications"
        case .security: "Privacy and security"
        }
    }

    var icon: String {
        switch self {
        case .profile: "person.crop.circle"
        case .payments: "bolt"
        case .assistant: "sparkles"
        case .brain: "house"
        case .connections: "powerplug"
        case .dictation: "mic"
        case .recording: "record.circle"
        case .notifications: "bell"
        case .security: "lock"
        }
    }

    /// The agent's own: listed only while there is one.
    private var needsAgent: Bool { [.assistant, .brain, .connections].contains(self) }

    /// The categories this account has, by title as listed.
    @MainActor static func listed(in model: AppModel) -> [AccountPage] {
        allCases.filter { model.agent != nil || !$0.needsAgent }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// What each category holds, for the search: the labels of its rows.
    private var keywords: [String] {
        switch self {
        case .profile: ["name", "photo", "picture", "contact info", "QR code", "time zone", "server", "public key"]
        case .payments: ["balance", "sats", "confirm payments", "boost amount"]
        case .assistant: ["agent", "provider", "API key", "model", "own account", "always allowed", "may post as you",
                          "revoke", "old assistant chats"]
        case .brain: ["Peel Home", "brain", "home server", "this Mac", "move", "turn off", "restore", "sync"]
        case .connections: ["services", "MCP server", "Stadeum", "workspaces", "pair"]
        case .dictation: ["key", "speech", "history", "microphone", "input monitoring", "accessibility", "voice"]
        case .recording: ["screen recording", "record screen", "camera", "video", "captions", "transcript", "Loom"]
        case .notifications: ["message text", "alerts"]
        case .security: ["PIN", "lock", "twelve words", "recovery", "website data", "forget account", "sign out"]
        }
    }

    /// Account's list under you: every category but Profile (your row), or
    /// those whose title or rows hold `query`, Profile among them.
    @MainActor static func matching(_ query: String, in model: AppModel) -> [AccountPage] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return listed(in: model).filter { $0 != .profile } }
        return listed(in: model).filter { page in
            ([page.title] + page.keywords).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// The chosen category, or Profile when this account no longer has it.
    @MainActor static func shown(in model: AppModel) -> AccountPage {
        listed(in: model).contains(model.accountPage) ? model.accountPage : .profile
    }
}

/// Account's categories under you (Profile): a row for each of the others,
/// or, while the search holds something, each it found.
struct AccountCategories: View {
    @Environment(AppModel.self) private var model
    /// `AccountPage.matching`: every category but Profile, or what was found.
    let pages: [AccountPage]
    let searching: Bool

    var body: some View {
        let shown = AccountPage.shown(in: model)
        ScrollView {
            VStack(spacing: 1) {
                if searching, pages.isEmpty {
                    Text("No settings match.")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(pages, id: \.self) { page in
                    Button { model.accountPage = page } label: {
                        HStack(spacing: 9) {
                            Image(systemName: page.icon)
                                .font(.system(size: 13))
                                .frame(width: Theme.AvatarSize.sm)
                            Text(page.title).lineLimit(1)
                        }
                    }
                    .buttonStyle(SidebarRowStyle(selected: shown == page))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Identity

/// Photo, name and key. A photo is chosen or dropped, uploaded at once,
/// and removed after a second click; its link is never shown.
private struct IdentitySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PictureField(
            picture: Avatar(name: model.me.avatarName, url: model.myPhotoURL, size: Theme.AvatarSize.xxl, hue: model.myHue),
            upload: { try await model.uploadPhoto($0) },
            remove: model.myPhotoURL == nil ? nil : .confirmed("Remove photo") { try await model.removePhoto() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(model.me.name)
                    .font(Theme.font(24, .bold))
                    .lineLimit(1)
                if let key = model.myPubkey {
                    Text(Formatting.shortKey(key))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .help(key)
                }
            }
            .padding(.leading, Theme.Space.sm)
            Spacer(minLength: 12)
        }
    }
}

/// The QR code and contact info someone needs to add this account.
private struct ContactInfoSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Theme.Space.xl) {
                QRCodeTile(text: model.myContactInfo, label: "QR code of your contact info")
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Your contact info")
                        .font(Theme.font(15, .bold))
                    if model.myContactInfo == nil {
                        Text("Not ready yet")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if let info = model.myContactInfo {
                        CopyButton("Copy contact info", text: info)
                            .buttonStyle(.peel(.outline))
                            .id(info)
                            .padding(.top, Theme.Space.xs)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.lg)
        }
    }
}

// MARK: - Rows

private struct NameRow: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var draft = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 14) {
                FormItem(label: "Name") {
                    FormTextField(label: "Name", text: $draft)
                        .onSubmit { Task { await save() } }
                        .disabled(working)
                }
                .padding([.horizontal, .top], settingsRowPadding)
                FormFooter(problem: problem) {
                    Button("Cancel") { editing = false }
                        .buttonStyle(.peel(.outline))
                        .disabled(working)
                    // On while it saves, keeping its fill under the spinner;
                    // `save` ignores a second click.
                    Button { Task { await save() } } label: { Text("Save").buttonProgress(working) }
                        .buttonStyle(.peel(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmed.isEmpty || draft.trimmed == model.myAlias)
                }
                .padding([.horizontal, .bottom], settingsRowPadding)
            }
        } else {
            Fact("Name") {
                // A restore settled before this Mac asked for a name can
                // still leave it unset; the Composer disables Send for it.
                Text(model.myAlias?.nilIfEmpty ?? "Not set")
                    .foregroundStyle(model.myAlias?.nilIfEmpty == nil ? Theme.secondaryText : Theme.text)
            } trailing: {
                Button("Edit") {
                    draft = model.myAlias ?? ""
                    problem = nil
                    editing = true
                }
                .buttonStyle(.peel(.outline))
            }
        }
    }

    private func save() async {
        guard !draft.trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.setName(draft)
            editing = false
        } catch {
            problem = PeelError.problem(error, couldNot: "save your name")
        }
    }
}

/// Old PIN, new PIN, the new one again; then the words are sealed again.
private struct ChangePINRow: View {
    @Environment(AppModel.self) private var model

    private enum Step { case closed, old, new, confirm }
    @State private var step = Step.closed
    @State private var old = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Fact("PIN") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Six digits")
                    if let note, step == .closed {
                        Text(note)
                            .muted()
                    }
                }
            } trailing: {
                if step == .closed {
                    Button("Change") { reset(to: .old) }
                        .buttonStyle(.peel(.outline))
                } else {
                    Button("Cancel") { reset(to: .closed) }
                        .buttonStyle(.peel(.outline))
                        .disabled(working)
                }
            }
            if step != .closed {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text(prompt)
                        .font(Theme.font(13))
                        .foregroundStyle(note == nil ? Theme.secondaryText : Theme.text)
                    Group {
                        switch step {
                        case .old: PinField(pin: $old) { step = .new }
                        case .new: PinField(pin: $new) { step = .confirm }
                        default: PinField(pin: $confirmation) { Task { await submit() } }
                        }
                    }
                    .id(step)
                    .frame(maxWidth: 360)
                    .disabled(working)
                    ProgressView().controlSize(.small).opacity(working ? 1 : 0)
                }
                .padding(.horizontal, settingsRowPadding)
                .padding(.bottom, Theme.Space.sm)
            }
        }
    }

    private var prompt: String {
        if let note { return note }
        return switch step {
        case .old: "Enter your current PIN."
        case .new: "Choose a new six-digit PIN."
        default: "Enter the new PIN again."
        }
    }

    /// Clears the digits typed so far and moves to `step`.
    private func reset(to step: Step, note: String? = nil) {
        if step != .new { old = "" }
        new = ""
        confirmation = ""
        self.note = note
        self.step = step
    }

    private func submit() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await model.changePIN(from: old, to: new, confirmation: confirmation)
            reset(to: .closed, note: "PIN changed")
        } catch let error as SecretStoreFailure where error == .wrongPIN {
            reset(to: .old, note: PIN.problem(error))
        } catch {
            reset(to: .new, note: PeelError.problem(error, couldNot: "change the PIN") + " Choose the new PIN again.")
        }
    }
}

private struct PINTimeoutRow: View {
    @Environment(AppModel.self) private var model

    private static let choices = [0, 1, 4, 12, 24]

    var body: some View {
        Fact("Ask for the PIN") {
            SettingDropdown(
                selection: model.pinTimeoutHours,
                options: presets(Self.choices, including: model.pinTimeoutHours).map { ($0, Self.label($0)) }
            ) { try await model.setPINTimeout(hours: $0) }
        }
    }

    private static func label(_ hours: Int) -> String {
        switch hours {
        case 0: "Only when Peel opens"
        case 1: "After an hour"
        case 24: "After a day"
        default: "After \(hours) hours"
        }
    }
}

/// The twelve words, after the PIN: hidden behind dots until asked, gone
/// again after a short while, when Peel leaves the front, or when the screen
/// closes. Copying warns first and the clipboard is cleared after a minute.
private struct WordsRow: View {
    @Environment(AppModel.self) private var model

    private static let shownFor: TimeInterval = 30

    @State private var askingPIN = false
    @State private var pin = ""
    @State private var working = false
    @State private var problem: String?
    @State private var words: [String] = []
    /// Checking the words rather than showing them (Check words): three
    /// typed back from paper, the words read with the PIN but never shown.
    @State private var checking = false
    /// Never nil and never fewer answers, even once closed: a box being
    /// edited as the row closes still reads its answer.
    @State private var check = WordCheck()
    @State private var hideAt = Date.distantPast
    @State private var visible = false
    @State private var confirmingCopy = false
    /// When the words were last copied: the Copy button shows its check.
    @State private var copiedAt: Date?
    /// Bumped by `hide`, so a PIN check still running when the words are
    /// hidden (Cancel, Peel leaving the front) does not show them after all.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Fact("Twelve words") {
                Text(model.wordsConfirmed ? "Checked" : "Not checked yet")
            } trailing: {
                if words.isEmpty, !askingPIN {
                    HStack(spacing: 8) {
                        if !model.wordsConfirmed {
                            Button("Check words") { start(checking: true) }
                                .buttonStyle(.peel(.outline))
                        }
                        Button("Show words") { start(checking: false) }
                            .buttonStyle(.peel(.outline))
                    }
                } else {
                    Button(words.isEmpty || checking ? "Cancel" : "Hide") { hide() }
                        .buttonStyle(.peel(.outline))
                }
            }
            if askingPIN {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    prompt("Enter your PIN")
                    PinField(pin: $pin) { Task { await reveal() } }
                        .frame(maxWidth: 360)
                        .disabled(working)
                    ProgressView().controlSize(.small).opacity(working ? 1 : 0)
                }
                .padding(.horizontal, settingsRowPadding)
                .padding(.bottom, Theme.Space.sm)
            } else if !words.isEmpty {
                if checking { boxes } else { shown }
            } else if let problem {
                ProblemText(problem)
                    .padding([.horizontal, .bottom], settingsRowPadding)
            }
        }
        .onDisappear { hide() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hide() }
        #endif
    }

    private var shown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anyone with these words controls your account. Keep them on paper.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            NumberedWordGrid(places: Array(words.indices)) { index in
                Text(visible ? words[index] : "••••••")
                    .font(Theme.font(15))
                    .foregroundStyle(visible ? Theme.text : Theme.secondaryText)
                Spacer(minLength: 0)
            }
            .privacySensitive()
            HStack(spacing: Theme.Space.sm) {
                Button(visible ? "Mask" : "Reveal") { visible.toggle() }
                    .buttonStyle(.peel(.outline))
                // Not a loss, so the second click is the commit button, not red.
                InlineConfirm(
                    prompt: "Other apps can see the clipboard.", confirm: "Copy words",
                    confirmKind: .primary, confirming: $confirmingCopy
                ) {
                    Clipboard.copySecret(words.joined(separator: " "), clearAfter: .seconds(60))
                    copiedAt = .now
                    CopyFeedback.announce()
                } trigger: {
                    CopyLabel("Copy", copiedAt: copiedAt)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Hides in \(max(0, Int(hideAt.timeIntervalSince(context.date).rounded(.up)))) s")
                        .monospacedDigit()
                        .muted()
                }
            }
        }
        .padding([.horizontal, .bottom], settingsRowPadding)
        .task(id: hideAt) {
            try? await Task.sleep(for: .seconds(Self.shownFor))
            if !Task.isCancelled { hide() }
        }
    }

    /// Three words typed back; the words themselves stay off the screen.
    private var boxes: some View {
        VStack(alignment: .leading, spacing: 14) {
            prompt("Type these three words from your paper")
            WordCheckGrid(check: $check) { Task { await confirm() } }
            FormFooter(problem: nil) {
                Button { Task { await confirm() } } label: { Text("Check").buttonProgress(working) }
                    .buttonStyle(.peel(.primary))
                    .disabled(!check.isFilled)
            }
        }
        .padding([.horizontal, .bottom], settingsRowPadding)
    }

    /// The line over the PIN or the boxes: what to do, or why it was not
    /// accepted.
    private func prompt(_ text: String) -> some View {
        Text(problem ?? text)
            .font(Theme.font(13))
            .foregroundStyle(problem == nil ? Theme.secondaryText : Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func confirm() async {
        guard !working, check.isFilled else { return }
        working = true
        defer { working = false }
        let started = generation
        do {
            try await model.confirmWords(check.byPosition, of: words)
            hide()
        } catch {
            // Cancelled meanwhile: nothing to say under a closed row.
            guard generation == started else { return }
            problem = PeelError.problem(error)
        }
    }

    private func start(checking: Bool) {
        self.checking = checking
        check = WordCheck()
        problem = nil
        if model.profile?.requiresPIN == true {
            pin = ""
            askingPIN = true
        } else {
            Task { await reveal() }
        }
    }

    private func reveal() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let started = generation
        do {
            let revealed = try await model.revealWords(pin: pin)
            guard generation == started else { return }
            words = revealed
            askingPIN = false
            visible = false
            hideAt = .now.addingTimeInterval(Self.shownFor)
        } catch {
            guard generation == started else { return }
            problem = PIN.problem(error)
        }
        pin = ""
    }

    private func hide() {
        generation += 1
        problem = nil
        words = []
        checking = false
        check = WordCheck()
        pin = ""
        askingPIN = false
        visible = false
        confirmingCopy = false
        copiedAt = nil
    }
}

// MARK: - Time zone

/// The zone your time is shown in: this Mac's, or one chosen from a
/// searchable list (`ZonePicker`).
private struct TimeZoneRow: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: String?
    @State private var picking = false
    @State private var hovering = false
    @State private var problem: String?

    /// What is sent: the chosen zone, else this Mac's.
    private var zone: TimeZone { chosen.flatMap(TimeZoneOffset.zone) ?? .autoupdatingCurrent }

    var body: some View {
        Fact("Time zone") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Button { picking = true } label: {
                    HStack(spacing: Theme.Space.sm) {
                        Text(chosen.map(ZonePicker.label) ?? ZonePicker.automatic)
                            .lineLimit(1)
                        Text(TimeZoneOffset.format(zone))
                            .foregroundStyle(Theme.secondaryText)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .font(Theme.font(13))
                    .monospacedDigit()
                    .dropdownBoxed(hovering: hovering)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .fixedSize()
                .peelPopover(isPresented: $picking) {
                    ZonePicker(chosen: chosen, close: { picking = false }) { identifier in
                        picking = false
                        Task { await choose(identifier) }
                    }
                }
                if let problem { ProblemText(problem) }
            }
        }
        .task { chosen = try? await model.engine?.chosenTimeZone() }
    }

    private func choose(_ identifier: String?) async {
        do {
            try await model.setTimeZone(identifier)
            chosen = identifier
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: "change the time zone")
        }
    }
}

/// Automatic, then every zone this Mac knows, filtered as you type a city
/// or an offset.
private struct ZonePicker: View {
    let chosen: String?
    let close: () -> Void
    let choose: (String?) -> Void

    struct Zone: Identifiable {
        let id: String
        let label: String
        let offset: String
        /// What a search matches, lowercased once.
        let searched: String
    }

    @State private var query = ""
    /// Offsets as of opening, so they follow summer time.
    @State private var zones: [Zone] = []

    /// "America/New York".
    static func label(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    static var automatic: String { "Automatic · \(TimeZone.current.identifier)" }

    var body: some View {
        let query = query.trimmed.lowercased()
        let matches = query.isEmpty ? zones : zones.filter { $0.searched.contains(query) }
        Panel("Time zone", compact: true, close: close) {
            FormTextField(
                label: "Search time zones", prompt: "Search cities or GMT+…", text: $query,
                systemImage: "magnifyingglass", focusOnAppear: true
            )
            .onSubmit { if !query.isEmpty, let first = matches.first { choose(first.id) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        ZoneRow(title: "Automatic", detail: "\(TimeZone.current.identifier) · \(TimeZoneOffset.format(.current))",
                                checked: chosen == nil) { choose(nil) }
                        Theme.divider.frame(height: 1).padding(.vertical, Theme.Space.xs)
                        SectionHeader("All time zones")
                            .padding(.horizontal, Theme.Space.sm)
                            .padding(.vertical, 2)
                    }
                    ForEach(matches) { zone in
                        ZoneRow(title: zone.label, detail: zone.offset, checked: zone.id == chosen) { choose(zone.id) }
                    }
                    if matches.isEmpty {
                        EmptyState("No time zone matches.", size: .sm)
                    }
                }
            }
            .frame(height: 300)
            // The rows' own inset lines their text up with the field's.
            .padding(.horizontal, -8)
        }
        .onAppear {
            zones = TimeZone.knownTimeZoneIdentifiers.compactMap { id in
                TimeZone(identifier: id).map { zone in
                    let label = Self.label(id), offset = TimeZoneOffset.format(zone)
                    return Zone(id: id, label: label, offset: offset, searched: "\(label) \(offset)".lowercased())
                }
            }
        }
    }
}

/// A zone: ticked when it is the one chosen.
private struct ZoneRow: View {
    let title: String
    let detail: String
    let checked: Bool
    let action: () -> Void

    var body: some View {
        ListRow(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 12))
                .opacity(checked ? 1 : 0)
                .frame(width: 16)
        } title: {
            Text(title).lineLimit(1)
        } trailing: {
            Text(detail)
                .font(Theme.font(13))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

// MARK: - Notifications

/// Whether macOS lets Peel show notifications, and the way to change it.
private struct NotificationsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Fact("Notifications") {
            Text(state)
        } trailing: {
            switch model.notifier.permission {
            case .notAsked:
                Button("Turn on") { Task { await model.enableNotifications() } }
                    .buttonStyle(.peel(.primary))
            case .allowed, .denied:
                Button("System Settings…") { model.openNotificationSettings() }
                    .buttonStyle(.peel(.outline))
            case .unavailable:
                EmptyView()
            }
        }
    }

    private var state: String {
        switch model.notifier.permission {
        case .allowed: "On"
        case .notAsked: "Off"
        case .denied: "Off in System Settings"
        case .unavailable: "Unavailable"
        }
    }
}

private struct NotificationTextRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Fact("Message text") {
            SettingDropdown(
                selection: model.notifier.showsText,
                options: [(true, "Show"), (false, "Hide")]
            ) { try await model.setNotificationShowsText($0) }
        }
    }
}

private struct NotificationStyleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Fact("Notification Type") {
            SettingDropdown(
                selection: model.notifier.style,
                options: [(.banner, "Banner only"), (.bannerAndSound, "Banner + Sound"),
                          (.soundOnly, "Sound only"), (.none, "None")]
            ) { try await model.setNotificationStyle($0) }
        }
    }
}

/// The sound a notification plays: the system's and the user's own, by name.
/// Chosen with a preview; off where the type plays none.
private struct NotificationSoundRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sounds = Self.available()
        let chosen = sounds.contains(model.notifier.sound) ? model.notifier.sound : ""
        Fact("Notification Sound") {
            SettingDropdown(
                selection: chosen,
                options: [("", "Default")] + sounds.map { ($0, $0) }
            ) {
                try await model.setNotificationSound($0)
                if !$0.isEmpty { NSSound(named: $0)?.play() } else { NSSound.beep() }
            }
            .disabled(!model.notifier.style.playsSound)
        }
    }

    /// The names of the sounds in /System/Library/Sounds and ~/Library/Sounds.
    private static func available() -> [String] {
        let folders = [URL(filePath: "/System/Library/Sounds"),
                       FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds")]
        let names = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .map { ($0 as NSString).deletingPathExtension }
        }
        return Array(Set(names)).sorted()
    }
}

/// Sign-ins and site data from pages opened in Peel's web pane: this
/// profile's own store, cleared in place.
private struct WebsiteDataRow: View {
    @Environment(AppModel.self) private var model
    @State private var cleared = false

    var body: some View {
        Fact("Website data") {
            Text(cleared ? "Cleared" : "Sign-ins from pages opened in Peel")
                .muted()
        } trailing: {
            InlineConfirm(trigger: "Clear…", prompt: "Sign out of every site?", confirm: "Clear") {
                await model.web.clearWebsiteData()
                cleared = true
            }
        }
    }
}

// MARK: - Building blocks

let settingsRowPadding: CGFloat = 12

/// A group of Account rows, titled when its page has more than one: a
/// `FactList` with the page's wider label column.
struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                SectionHeader(title)
                    .padding(.horizontal, Theme.Space.xs)
            }
            FactList(labelWidth: 150) { content }
        }
        .padding(.top, Theme.Space.md)
    }
}

