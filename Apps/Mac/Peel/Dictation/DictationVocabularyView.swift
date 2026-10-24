import PeelCore
import PeelUI
import SwiftUI

/// The Vocabulary (docs/dictation-lingo.md, "The dictionary"): the words
/// dictation puts right, each with how it is misheard, as the memory graph
/// holds them. A view over the graph, not a second list: what is added or
/// removed here is written to Peel's strut, and what dictation learns
/// shows here.
struct DictationVocabularyView: View {
    static let id = "dictation-vocabulary"

    @State private var word = ""
    @State private var heard = ""
    @State private var problem: String?
    @Environment(AppModel.self) private var model
    private var lingo: DictationLingo { DictationController.shared.lingo }

    var body: some View {
        VStack(spacing: 0) {
            // Behind the PIN like the rest of memory: locking leaves the strut running.
            if model.unlockedStorage == nil {
                EmptyState("Unlock Peel to see your vocabulary")
            } else {
                add
                Theme.divider.frame(height: 1)
                list
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .task { await lingo.refresh() }
    }

    /// One word and how dictation writes it instead.
    private var add: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .bottom, spacing: Theme.Space.md) {
                FormTextField(label: "Word", prompt: "Stakwork", text: $word)
                FormTextField(label: "Dictation writes it as", prompt: "stack work", text: $heard)
                Button("Add") { Task { await addPair() } }
                    .buttonStyle(.peel(.primary))
                    .disabled(word.trimmed.isEmpty || heard.trimmed.isEmpty)
            }
            if let problem {
                ProblemText(problem)
            } else {
                Text("Dictation types the word wherever it hears it written this way. Corrections you make after dictating add to this too.")
                    .muted()
            }
        }
        .padding(Theme.Space.lg)
    }

    @ViewBuilder private var list: some View {
        let entries = lingo.lexicon.words
        if let problem = lingo.problem {
            EmptyState(problem)
        } else if entries.isEmpty {
            EmptyState("Words you teach dictation show here")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.refID) { entry in
                        VocabularyRow(entry: entry, problem: $problem)
                        Theme.divider.frame(height: 1).padding(.leading, Theme.Space.lg)
                    }
                }
                .padding(.bottom, Theme.Space.lg)
            }
        }
    }

    private func addPair() async {
        do {
            try await lingo.add(written: word.trimmed, heard: heard.trimmed)
            problem = nil
            word = ""
            heard = ""
        } catch {
            problem = PeelError.problem(error, couldNot: "add it")
        }
    }
}

/// A word, its type, how dictation mishears it (each removable), and
/// whether dictation uses it at all.
private struct VocabularyRow: View {
    let entry: LingoLexicon.Entry
    @Binding var problem: String?
    private var lingo: DictationLingo { DictationController.shared.lingo }

    var body: some View {
        ListRow(size: .md, alignment: .firstTextBaseline) {
            EmptyView()
        } title: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(entry.name).font(Theme.font(13, .semibold))
                Text(entry.type).font(Theme.font(11)).foregroundStyle(Theme.secondaryText)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.heard, id: \.refID) { heard in
                    HStack(spacing: Theme.Space.sm) {
                        Text("“\(heard.value)”" + (heard.form.map { " → \($0)" } ?? ""))
                        Button("Remove") {
                            Task {
                                do { try await lingo.remove(heard.refID) } catch {
                                    problem = PeelError.problem(error, couldNot: "remove it")
                                }
                            }
                        }
                        .buttonStyle(.peel(.link, size: .sm))
                    }
                }
            }
        } trailing: {
            PeelSwitch(isOn: Binding(
                get: { !entry.dictationOff },
                set: { on in
                    Task {
                        do { try await lingo.setDictation(entry, on: on) } catch {
                            problem = PeelError.problem(error, couldNot: "change it")
                        }
                    }
                }
            ))
            .accessibilityLabel("Use in dictation")
            .help(entry.dictationOff ? "Dictation leaves this word alone" : "Dictation puts this word right")
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}
