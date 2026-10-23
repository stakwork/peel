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
            Fact("Speech") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speechText)
                    Text("Recognised by Peel's own strut, on this Mac. Nothing you say leaves it.").muted()
                }
            } trailing: {
                if case .failed = dictation.speech.model {
                    Button("Try again") { Task { try? await dictation.speech.ensureModel() } }
                        .buttonStyle(.peel(.outline))
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

    private var speechText: String {
        let size = StrutSpeech.modelSize
        return switch dictation.speech.model {
        case .waiting: "Waiting for Peel's strut to start"
        case .checking: dictation.isEnabled ? "Getting the English model ready…" : "English model (\(size)) downloads when dictation is on"
        case .downloading: "Downloading the English model (\(size))…"
        case .installed: "Ready"
        case .failed(let why): why
        }
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

/// Account › Dictation's two pickers: the speech model and the fixer, each
/// model with its size and what it is for. Select downloads it first if it
/// has to (its progress shown), and strut uses it once it is there; an
/// installed model can be removed, but for the default speech model, which
/// dictation falls back on.
private struct DictationModelsSection: View {
    let models: DictationModels

    var body: some View {
        let speech = models.models.filter { $0.kind == .speech }
        let fixers = models.models.filter { $0.kind == .fixer }
        VStack(alignment: .leading, spacing: 6) {
            if !speech.isEmpty {
                SettingsSection("Speech model") {
                    ForEach(speech) { DictationModelRow(models: models, model: $0) }
                }
            }
            if !fixers.isEmpty {
                SettingsSection("Fixer") {
                    ForEach(fixers) { DictationModelRow(models: models, model: $0) }
                    Fact("None") {
                        Text("Dictation types what it hears, with your vocabulary.").muted()
                    } trailing: {
                        DictationModelChoice(selected: !fixers.contains(where: \.selected)) { await models.selectNoFixer() }
                    }
                }
                Text("A fixer is a small model on this Mac that puts right what dictation mishears and learns from your edits.")
                    .muted()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if let problem = models.problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .padding(.horizontal, 4)
            }
        }
        .task { await models.load() }
    }
}

/// One model: its name, size and use, a download's progress or failure,
/// Select or the check, and Remove once it is on this Mac.
private struct DictationModelRow: View {
    let models: DictationModels
    let model: DictationModel
    @State private var removing = false

    var body: some View {
        Fact(Self.name(model)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(AttachmentFormat.size(model.bytes) ?? "") · \(Self.blurb(model))")
                    .muted()
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
        } trailing: {
            HStack(spacing: Theme.Space.sm) {
                if !removing {
                    DictationModelChoice(selected: model.selected) { await models.select(model) }
                }
                if model.state == .installed, model.id != StrutSpeech.model {
                    InlineConfirm(trigger: "Remove", confirm: "Remove", confirming: $removing) {
                        await models.remove(model)
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.state == .downloading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.progress ?? 0)
                    .tint(Theme.accent)
                    .frame(maxWidth: 220)
                Text(downloadText).muted().monospacedDigit()
            }
            .padding(.top, 2)
        } else if let error = model.error {
            Text("The download failed: " + error)
                .font(Theme.font(12))
                .foregroundStyle(Theme.attention)
                .lineLimit(2)
                .help(error)
        }
    }

    private var downloadText: String {
        let done = model.progress.map { AttachmentFormat.progress(Int64(Double(model.bytes) * $0), of: model.bytes) }
        let progress = done.map { "Downloading, \($0)" } ?? "Downloading…"
        return model.selected ? progress + ". Used once it's here." : progress
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

    /// What it is for, in a few words; strut's own description for a model Peel doesn't know.
    static func blurb(_ model: DictationModel) -> String {
        switch model.id {
        case "zipformer-en-kroko": "The default. Quick and light."
        case "parakeet-tdt-en-0.6b-v2": "More accurate, a little slower."
        case "qwen3-0.6b-q4": "The quickest, less sure what you meant."
        case "qwen3-1.7b-q4": "Recommended. Better at telling a mishearing from a new word."
        default: model.description
        }
    }
}

/// The picked one's check, or Select.
private struct DictationModelChoice: View {
    let selected: Bool
    let select: () async -> Void
    @State private var working = false

    var body: some View {
        if selected {
            Image(systemName: "checkmark")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 28)
                .accessibilityLabel("Selected")
        } else {
            Button {
                working = true
                Task {
                    await select()
                    working = false
                }
            } label: {
                Text("Select").buttonProgress(working, size: .small)
            }
            .buttonStyle(.peel(.outline))
            .disabled(working)
        }
    }
}
