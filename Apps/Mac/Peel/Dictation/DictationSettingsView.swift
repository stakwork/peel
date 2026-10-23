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
        SettingsSection("Dictation") {
            Fact("Dictation") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateText)
                    if let note { Text(note).muted() }
                }
            } trailing: {
                Toggle("Dictation", isOn: Binding(get: { dictation.isEnabled }, set: { dictation.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
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
                    Toggle("History", isOn: Binding(get: { dictation.historyOn }, set: { dictation.setHistoryOn($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            DictationPermissionRows(permissions: dictation.permissions)
        }
    }

    private var vocabularyText: String {
        if dictation.lingo.problem != nil { return "Not available: Peel's strut can't read it" }
        let count = dictation.lingo.lexicon.entries.filter { !$0.heard.isEmpty }.count
        return count == 0 ? "No words yet" : count == 1 ? "1 word" : "\(count) words"
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
            icon: "mic", text: "Dictate anywhere on your Mac by holding a key?", action: "Set up",
            dismiss: { DictationController.shared.dismissOffer() },
            accept: {
                DictationController.shared.dismissOffer()
                model.destination = .account
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
/// switches to it once it's there.
private struct DictationModelsSection: View {
    let models: DictationModels
    private var dictation: DictationController { .shared }

    var body: some View {
        let speech = models.models.filter { $0.kind == .speech }
        let fixers = models.models.filter { $0.kind == .fixer }
        VStack(alignment: .leading, spacing: 6) {
            if !speech.isEmpty {
                SettingsSection("Speech to text") {
                    DictationModelSummary(models: models, kind: .speech, choices: speech, learned: nil)
                }
            }
            if !fixers.isEmpty {
                SettingsSection("Clean-up and learning") {
                    DictationModelSummary(models: models, kind: .fixer, choices: fixers, learned: learnedCount)
                }
            }
            Text(models.problem ?? "Runs on this Mac. Nothing you say leaves it.")
                .font(Theme.font(12))
                .foregroundStyle(models.problem == nil ? Theme.secondaryText : Theme.attention)
                .padding(.horizontal, 4)
        }
        .task { await models.load() }
    }

    private var learnedCount: Int {
        dictation.lingo.lexicon.entries.filter { !$0.heard.isEmpty }.count
    }
}

/// One job's row: an icon, the picked model's name, what it does, its size
/// (and, for clean-up, how many words it has learned), a download under
/// way, and Change, which opens the choices beside it.
private struct DictationModelSummary: View {
    @Environment(\.menuPresenter) private var presenter
    let models: DictationModels
    let kind: DictationModel.Kind
    let choices: [DictationModel]
    /// Words learned, for clean-up.
    let learned: Int?
    @State private var anchor = MenuAnchor()

    /// Nil for clean-up when none is picked: Off.
    private var picked: DictationModel? { choices.first(where: \.selected) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Image(systemName: kind == .speech ? "waveform" : "wand.and.stars")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(picked.map(Self.name) ?? "Off")
                Text(summary).muted().fixedSize(horizontal: false, vertical: true)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Change") { presenter?.show(entries(), at: anchor, minWidth: 300, highlightChecked: true) }
                .buttonStyle(.peel(.outline))
                .menuAnchor(anchor)
        }
        .font(Theme.font(13))
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
    }

    private var summary: String {
        guard let picked else { return Self.offText }
        var parts = [Self.blurb(picked)]
        if let size = AttachmentFormat.size(picked.bytes) { parts.append(size) }
        if let learned, picked.state == .installed {
            parts.append(learned == 1 ? "1 word learned" : "\(learned) words learned")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        if let picked, picked.state == .downloading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: picked.progress ?? 0)
                    .tint(Theme.accent)
                    .frame(maxWidth: 240)
                Text(Self.downloadText(picked)).muted().monospacedDigit()
            }
            .padding(.top, 2)
        } else if let failed = choices.first(where: { $0.error != nil }), let error = failed.error {
            Text("\(Self.name(failed)) didn't download: \(error)")
                .font(Theme.font(12))
                .foregroundStyle(Theme.attention)
                .lineLimit(2)
                .help(error)
        }
    }

    /// Each choice with what it means; Off for clean-up; Remove for what is
    /// on this Mac but not in use (never the speech model dictation falls back on).
    private func entries() -> [MenuEntry] {
        var picks: [MenuEntry] = []
        if kind == .fixer {
            picks.append(.button("Off", subtitle: Self.offText, checked: picked == nil) {
                Task { await models.selectNoFixer() }
            })
        }
        for model in choices {
            let size = AttachmentFormat.size(model.bytes).map { " · \($0)" } ?? ""
            let later = model.state == .installed ? "" : " Downloads first."
            let lead = model.id == Self.recommended ? "Recommended. " : ""
            picks.append(.button(Self.name(model) + size, subtitle: lead + Self.blurb(model) + later, checked: model.selected) {
                Task { await models.select(model) }
            })
        }
        let removable = choices.filter { $0.state == .installed && !$0.selected && $0.id != StrutSpeech.model }
        let removals: [MenuEntry] = removable.map { model in
            .destructive("Remove \(Self.name(model))", confirm: "Remove \(Self.name(model)) from this Mac") {
                Task { await models.remove(model) }
            }
        }
        return .sections(picks, removals)
    }

    static let offText = "No clean-up, nothing learned."
    static let recommended = "qwen3-1.7b-q4"

    static func downloadText(_ model: DictationModel) -> String {
        let done = model.progress.map { AttachmentFormat.progress(Int64(Double(model.bytes) * $0), of: model.bytes) }
        return (done.map { "Downloading \($0)" } ?? "Downloading…") + ". Switches over when it's done."
    }

    /// Peel's names for the models it knows; any other by its id.
    static func name(_ model: DictationModel) -> String {
        switch model.id {
        case "zipformer-en-kroko": "Kroko"
        case "parakeet-tdt-en-0.6b-v2": "Parakeet"
        case "qwen3-0.6b-q4": "Qwen3 0.6B"
        case "qwen3-1.7b-q4": "Qwen3 1.7B"
        default: model.id
        }
    }

    /// What it does for you; strut's own description for a model Peel doesn't know.
    static func blurb(_ model: DictationModel) -> String {
        switch model.id {
        case "zipformer-en-kroko": "Fastest and smallest."
        case "parakeet-tdt-en-0.6b-v2": "More accurate with names and jargon."
        case "qwen3-0.6b-q4": "Small and capable."
        case "qwen3-1.7b-q4": "Most accurate at learning your lingo."
        default: model.description
        }
    }
}
