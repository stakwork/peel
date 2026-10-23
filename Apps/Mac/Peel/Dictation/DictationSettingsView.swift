import AppKit
import SwiftUI
import PeelAgent
import PeelUI

/// Account › Dictation: on or off, the key (Right Option for now), and what macOS has been asked for.
struct DictationSettingsSection: View {
    @Environment(\.openWindow) private var openWindow
    private var dictation: DictationController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section
            DictationModelsSection(models: dictation.models)
        }
        .onAppear { dictation.refresh() }
    }

    private var section: some View {
        SettingsSection {
            Fact("Dictation") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateText)
                    if let note { Text(note).muted() }
                }
            } trailing: {
                PeelSwitch(isOn: Binding(get: { dictation.isEnabled }, set: { dictation.setEnabled($0) }))
                    .accessibilityLabel("Dictation")
            }
            Fact("Key") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictation.hotkey.label)
                    Text("Hold to dictate, let go to finish. Press Space while holding to keep going hands-free.").muted()
                }
            }
            Fact("Vocabulary") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vocabularyText)
                    Text("Names and words dictation puts right, kept in your memory. Fix a word after dictating and it's learned.").muted()
                }
            } trailing: {
                Button("Open") { openWindow(id: DictationVocabularyView.id) }
                    .buttonStyle(.peel(.outline))
            }
            Fact("History") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictation.historyOn ? "Kept for 30 days" : "Off: earlier ones stay until cleared or 30 days old")
                    Text("What you dictate, kept on this Mac so you can copy it again. Nothing is sent anywhere.").muted()
                }
            } trailing: {
                HStack(spacing: Theme.Space.sm) {
                    Button("Open") { openWindow(id: DictationHistoryView.id) }
                        .buttonStyle(.peel(.outline))
                    PeelSwitch(isOn: Binding(get: { dictation.historyOn }, set: { dictation.setHistoryOn($0) }))
                        .accessibilityLabel("History")
                }
            }
            DictationPermissionRows(permissions: dictation.permissions)
        }
    }

    private var vocabularyText: String {
        if dictation.lingo.problem != nil { return "Not available: Peel's strut can't read it" }
        let count = dictation.lingo.lexicon.wordCount
        return count == 0 ? "No words yet" : Formatting.count(count, "word")
    }

    private var stateText: String {
        if !dictation.isEnabled { return "Off" }
        if !dictation.permissions.requiredGranted { return "Waiting for permissions" }
        return dictation.isListening ? "On" : "Starting…"
    }

    private var note: String? {
        if dictation.secureInput { return "Another app is blocking keyboard shortcuts (secure input), so the key may not work." }
        if dictation.isListening && !dictation.canSwallow {
            return "Without Accessibility, the Space that keeps dictation going also types a space."
        }
        return nil
    }
}

/// Offered once, at the foot of the window, until dictation's permissions are in
/// or the offer is turned down.
struct DictationOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OfferBar(
            icon: "mic", text: "Dictation that works everywhere and stays local and private.", action: "Set up",
            dismiss: { DictationController.shared.dismissOffer() },
            accept: {
                DictationController.shared.dismissOffer()
                model.openAccount(.dictation)
            }
        )
    }
}

/// The app menu's line for dictation: its state, and a way to turn it off or on.
struct DictationMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let dictation = DictationController.shared
        Button(dictation.isEnabled ? "Turn Dictation Off" : "Turn Dictation On") {
            dictation.setEnabled(!dictation.isEnabled)
        }
        Button("Dictation History…") { openWindow(id: DictationHistoryView.id) }
        Text("Dictation: " + (dictation.isListening ? "On (\(dictation.hotkey.label))" : "Off"))
    }
}

/// Account › Dictation's models, one row for each job: the model doing it
/// and what it does for you, with Change to pick another. A pick that
/// isn't on this Mac downloads first (its progress shown) and strut
/// switches to it once it's there. Strut names and describes each model.
private struct DictationModelsSection: View {
    let models: DictationModels
    private var dictation: DictationController { .shared }

    var body: some View {
        let speech = models.models.filter { $0.kind == .speech }
        let fixers = models.models.filter { $0.kind == .fixer }
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection("Speech to text") {
                if speech.isEmpty {
                    // Strut not up yet, or its list not read: what dictation's own model is doing.
                    Fact("Speech") { Text(speechText) }
                } else {
                    DictationModelSummary(models: models, kind: .speech, choices: speech, learned: nil)
                }
            }
            if !fixers.isEmpty {
                SettingsSection("Clean-up and learning") {
                    DictationModelSummary(models: models, kind: .fixer, choices: fixers, learned: dictation.lingo.lexicon.wordCount)
                }
            }
            Group {
                if let problem = models.problem {
                    ProblemText(problem)
                } else {
                    Text("Runs on this Mac. Nothing you say leaves it.").muted()
                }
            }
            .padding(.horizontal, 4)
        }
        // Read on show, and every second while a model downloads; it stops when the section goes.
        .task(id: models.downloading) { await models.follow() }
    }

    private var speechText: String {
        switch dictation.speech.model {
        case .waiting: "Waiting for Peel's strut to start"
        case .checking: dictation.isEnabled ? "Getting the speech model ready…" : "The speech model (\(StrutSpeech.modelSize)) downloads when dictation is on"
        case .downloading: "Downloading the speech model (\(StrutSpeech.modelSize))…"
        case .installed: "Ready"
        case .failed(let why): why
        }
    }
}

/// One job's row: an icon, the model in use, what it does, its size (and,
/// for clean-up, how many words it has learned), a pick still downloading,
/// and Change, which opens the choices beside it.
private struct DictationModelSummary: View {
    @Environment(\.menuPresenter) private var presenter
    let models: DictationModels
    let kind: DictationModel.Kind
    let choices: [DictationModel]
    /// Words learned, for clean-up.
    let learned: Int?
    @State private var anchor = MenuAnchor()

    /// The one in use; nil for clean-up when it is off.
    private var active: DictationModel? { choices.first(where: \.active) }
    /// The user's pick; nil for clean-up when it is off.
    private var picked: DictationModel? { choices.first(where: \.selected) }

    var body: some View {
        ListRow(size: .md, alignment: .firstTextBaseline) {
            Image(systemName: kind == .speech ? "waveform" : "wand.and.stars")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
        } title: {
            Text(active?.name ?? (kind == .fixer ? "Off" : "Default"))
        } detail: {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).fixedSize(horizontal: false, vertical: true)
                status
            }
        } trailing: {
            HStack(spacing: Theme.Space.xs) {
                Button("Change") { presenter?.show(entries(), at: anchor, minWidth: 300, highlightChecked: true, edge: .trailing) }
                    .buttonStyle(.peel(.outline))
                    .menuAnchor(anchor)
                // Removing what is on this Mac but not in use: apart from choosing.
                if choices.contains(where: \.removable) {
                    MenuButton(systemImage: "ellipsis", help: "More", source: "dictation-models-\(kind)", edge: .trailing,
                               entries: removals)
                }
            }
        }
    }

    private var summary: String {
        guard let active else { return kind == .fixer ? Self.offText : "Strut's default speech model." }
        var parts = [active.summary]
        if let size = AttachmentFormat.size(active.bytes) { parts.append(size) }
        if let learned { parts.append(Formatting.count(learned, "word") + " learned") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        if let picked, picked.state == .downloading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: picked.progress ?? 0)
                    .tint(Theme.accent)
                    .frame(maxWidth: 240)
                Text(Self.downloadText(picked)).monospacedDigit()
            }
            .padding(.top, 2)
        } else if let failed = choices.first(where: { $0.error != nil }), let error = failed.error {
            ProblemText("\(failed.name) didn't download: \(error)")
                .help(error)
        } else if kind == .speech, case .failed(let why) = DictationController.shared.speech.model {
            // The default model dictation fetches itself, failed: say so here, with a retry.
            HStack(spacing: Theme.Space.sm) {
                ProblemText(why)
                Button("Try again") { Task { try? await DictationController.shared.speech.ensureModel() } }
                    .buttonStyle(.peel(.outline, size: .sm))
            }
        }
    }

    /// Each choice with what it means and its size; Off for clean-up;
    /// Remove for what strut says can go.
    private func entries() -> [MenuEntry] {
        var picks: [MenuEntry] = []
        if kind == .fixer {
            picks.append(.button("Off", subtitle: Self.offText, checked: picked == nil) {
                Task { await models.selectNoFixer() }
            })
        }
        for model in choices {
            let lead = model.recommended ? "Recommended. " : ""
            let later = model.state == .installed ? "" : " Downloads first."
            picks.append(.button(model.name, subtitle: lead + model.summary + later, detail: AttachmentFormat.size(model.bytes),
                                 checked: model.selected) {
                Task { await models.select(model) }
            })
        }
        return picks
    }

    /// The models on this Mac that aren't in use, to remove, each with the space it frees.
    private func removals() -> [MenuEntry] {
        choices.filter(\.removable).map { model in
            .destructive("Remove \(model.name)", subtitle: AttachmentFormat.size(model.bytes).map { "Frees \($0)" },
                         confirm: "Remove \(model.name) from this Mac") {
                Task { await models.remove(model) }
            }
        }
    }

    static let offText = "No clean-up, nothing learned."

    /// "Downloading Parakeet: 202.6 of 482.5 MB…", from what strut says has come.
    static func downloadText(_ model: DictationModel) -> String {
        let done = (model.downloaded ?? model.progress.map { Int64(Double(model.bytes) * $0) })
            .map { ": " + AttachmentFormat.progress($0, of: model.bytes) } ?? ""
        return "Downloading \(model.name)\(done)… Switches over when it's done."
    }
}
