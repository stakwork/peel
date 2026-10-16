import AgentKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

// MARK: - A memory tool's row, opened

/// What a memory tool did, in sentences, inside its opened row: the facts
/// `remember` wrote, each over the one it replaced, who they were about and
/// any new words; what `recall` found; the node `read_memory` read. A fact
/// or a name opens that one memory beside the chat (`MemoryPanelView`).
/// Read from the row's JSON here, so only a change to the row reads it again.
struct MemoryRowDetail: View {
    let tool: String
    let input: AgentKit.JSONValue
    let row: AgentKit.JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let asked = MemoryResult.asked(tool: tool, input: input) {
                Text(asked)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            switch MemoryResult(tool: tool, row: row) {
            case .remembered(let remembered)?: Remembered(remembered: remembered)
            case .found(let refs)?: Found(refs: refs)
            case .read(let node)?: Read(node: node)
            case nil: Text("Nothing to show.").foregroundStyle(Theme.secondaryText)
            }
        }
        .font(Theme.font(12))
        .padding(.vertical, 2)
    }

    private struct Remembered: View {
        let remembered: MemoryResult.Remembered

        var body: some View {
            ForEach(remembered.facts, id: \.fact.id) { written in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        MemoryLink(ref: written.fact)
                        if !written.isNew {
                            Text("already known")
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize()
                        }
                    }
                    ForEach(written.replaced, id: \.id) { old in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                            Text("replaces")
                                .foregroundStyle(Theme.tertiaryText)
                            MemoryLink(ref: old, replaced: true)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if remembered.facts.isEmpty {
                Text("No facts.")
                    .foregroundStyle(Theme.secondaryText)
            }
            if !remembered.about.isEmpty {
                SectionHeader("About")
                    .padding(.top, Theme.Space.xs)
                ChipFlow(spacing: Theme.Space.xs) {
                    ForEach(remembered.about, id: \.entity.id) { MemoryChip(ref: $0.entity, isNew: $0.isNew) }
                }
                ForEach(remembered.about.filter { !$0.similar.isEmpty }, id: \.entity.id) { mention in
                    Text("\(mention.entity.name) may be the same as \(mention.similar.map(\.name).joined(separator: ", ")).")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if !remembered.proposed.isEmpty || !remembered.notes.isEmpty {
                SectionHeader("New words")
                    .padding(.top, Theme.Space.xs)
                if !remembered.proposed.isEmpty {
                    Text(remembered.proposed.joined(separator: ", "))
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(remembered.notes, id: \.self) { note in
                    Text(note)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private struct Found: View {
        let refs: [MemoryRef]

        var body: some View {
            if refs.isEmpty {
                Text("Nothing matched.")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(refs, id: \.id) { ref in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    MemoryLink(ref: ref)
                    Spacer(minLength: Theme.Space.md)
                    Text(ref.type.map(MemoryWords.type) ?? "")
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                }
                .padding(.vertical, 1)
            }
        }
    }

    private struct Read: View {
        let node: MemoryNode

        var body: some View {
            switch node {
            case .entity(let entity):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MemoryLink(ref: node.ref)
                        .fontWeight(.semibold)
                    Text([MemoryWords.type(entity.ref.type ?? ""), Formatting.count(entity.facts.count, "fact")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(entity.facts, id: \.fact.id) { MemoryLink(ref: $0.fact).padding(.vertical, 1) }
            case .fact(let fact):
                MemoryLink(ref: node.ref, replaced: fact.expired != nil)
                if let subject = fact.subject {
                    Text("About \(subject.name) · \(MemoryWords.predicate(fact.predicate))")
                        .foregroundStyle(Theme.secondaryText)
                }
            case .episode:
                MemoryLink(ref: node.ref)
            }
        }
    }
}

/// A fact's sentence or a name: a replaced fact struck through and faint;
/// one strut named only by its ref_id, "An earlier fact".
private func memoryText(_ ref: MemoryRef, replaced: Bool = false) -> some View {
    Text(ref.name.isEmpty ? "An earlier fact" : ref.name)
        .strikethrough(replaced && !ref.name.isEmpty, color: Theme.tertiaryText.opacity(0.6))
        .foregroundStyle(replaced ? Theme.tertiaryText : Theme.text)
}

/// A fact's sentence or a name that opens that memory beside the chat:
/// the text's own colour, the link's under the pointer.
private struct MemoryLink: View {
    @Environment(AppModel.self) private var model
    let ref: MemoryRef
    var replaced = false
    @State private var hovering = false

    var body: some View {
        // Memory turned off since: the words, without a way in.
        if model.memoryServer == nil {
            memoryText(ref, replaced: replaced)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            link
        }
    }

    private var link: some View {
        Button {
            model.openMemory(ref)
        } label: {
            memoryText(ref, replaced: replaced)
                .underline(hovering, color: Theme.link.opacity(0.5))
                .foregroundStyle(hovering ? Theme.link : replaced ? Theme.tertiaryText : Theme.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in memory")
    }
}

/// An entity as a chip that opens it, "new" after the name when the
/// remember that showed it made it.
private struct MemoryChip: View {
    @Environment(AppModel.self) private var model
    let ref: MemoryRef
    var isNew = false

    var body: some View {
        Chip(.inset, action: { model.openMemory(ref) }) {
            ChipText(title: ref.name, on: false, note: isNew ? "new" : nil)
        }
        .help(ref.type.map(MemoryWords.type) ?? "")
    }
}

/// A heading over a group in the panel.
private struct MemorySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionHeader(title)
            content
        }
    }
}

/// Memory's words as people read them.
enum MemoryWords {
    /// "lives_in" → "lives in".
    static func predicate(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// A type beside a name ("Kate · Person"). None for the user: memory
    /// names them "Me", which says it already.
    static func type(_ name: String) -> String {
        name == "Self" ? "" : title(name)
    }

    /// A type on its own, as the panel's title: the user is "You".
    static func title(_ name: String) -> String {
        switch name {
        case "Self": "You"
        case "Episode": "Said"
        default: name
        }
    }
}

// MARK: - One memory, beside the chat

/// The one memory a row's fact or name opened, beside the agent chat as a
/// thread is beside a chat: an entity with what memory knows about it now;
/// a fact with who it is about, since when, what it replaced and what was
/// said; something said with who it mentions. Its facts and names open in
/// its place, with Back. Read when it opens, so it is memory as it is now.
struct MemoryPanelView: View {
    @Environment(AppModel.self) private var model
    let panel: MemoryPanel

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: title) {
                if panel.canGoBack {
                    IconButton("chevron.left", help: "Back") { panel.back() }
                }
            } trailing: {
                IconButton("xmark", help: "Close") { model.closeMemory() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let problem = panel.problem {
                        Callout(detail: problem, icon: .problem)
                    } else if let node = panel.node {
                        switch node {
                        case .entity(let entity): EntityDetail(entity: entity)
                        case .fact(let fact): FactDetail(fact: fact)
                        case .episode(let episode): EpisodeDetail(episode: episode)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.panel)
    }

    /// What is open: "Person", "You", "Fact", "Said".
    private var title: String {
        switch panel.node {
        case .entity(let entity)?: MemoryWords.title(entity.ref.type ?? "")
        case .fact?: "Fact"
        case .episode?: "Said"
        case nil: panel.current?.type.map(MemoryWords.title) ?? "Memory"
        }
    }

    private struct EntityDetail: View {
        let entity: MemoryNode.Entity

        var body: some View {
            PanelHero(name: entity.ref.name) {
                EmptyView()
            } lines: {
                Text(([MemoryWords.title(entity.ref.type ?? "")]
                      + (entity.aliases.isEmpty ? [] : ["also " + entity.aliases.joined(separator: ", ")]))
                    .joined(separator: " · "))
            }
            MemorySection("What it knows") {
                if entity.facts.isEmpty {
                    EmptyState("Nothing about \(entity.ref.name) yet.", size: .sm)
                } else {
                    FactRows(facts: entity.facts.map { ($0.fact, $0.since) })
                }
            }
            if entity.mentionedIn > 0 {
                Text("Mentioned \(Formatting.count(entity.mentionedIn, "time"))").muted()
            }
        }
    }

    private struct FactDetail: View {
        @Environment(AppModel.self) private var model
        let fact: MemoryNode.Fact

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.text)
                    .font(Theme.font(16, .bold))
                    .foregroundStyle(fact.expired == nil ? Theme.text : Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(MemoryWords.predicate(fact.predicate) + (fact.expired == nil ? "" : " · replaced")).muted()
            }
            FactList(labelWidth: 84) {
                if let subject = fact.subject {
                    Fact("About") { open(subject) }
                }
                if let object = fact.object {
                    Fact("Also about") { open(object) }
                }
                if let since = fact.since {
                    Fact("Since", text: Formatting.dateAndTime(since))
                }
                if let expired = fact.expired {
                    Fact("Replaced", text: Formatting.dateAndTime(expired))
                }
                Fact("Written by", text: fact.byAgent ? "Peel's agent" : "You")
            }
            if !fact.replaced.isEmpty {
                MemorySection("It replaced") { FactRows(facts: fact.replaced.map { ($0, nil) }, replaced: true) }
            }
            if !fact.replacedBy.isEmpty {
                MemorySection("Replaced by") { FactRows(facts: fact.replacedBy.map { ($0, nil) }) }
            }
            if !fact.from.isEmpty {
                MemorySection("From what was said") { ForEach(fact.from, id: \.id) { SaidCard(said: $0) } }
            }
        }

        private func open(_ ref: MemoryRef) -> some View {
            Button(ref.name) { model.openMemory(ref) }
                .buttonStyle(.peel(.link))
        }
    }

    private struct EpisodeDetail: View {
        let episode: MemoryNode.Episode

        var body: some View {
            SaidCard(said: episode.said)
            if !episode.mentions.isEmpty {
                MemorySection("Mentions") {
                    ChipFlow(spacing: Theme.Space.xs) {
                        ForEach(episode.mentions, id: \.id) { MemoryChip(ref: $0) }
                    }
                }
            }
        }
    }

    /// Facts in a card, each a row that opens it, its date in a column.
    private struct FactRows: View {
        @Environment(AppModel.self) private var model
        let facts: [(MemoryRef, Date?)]
        var replaced = false

        var body: some View {
            FactList {
                ForEach(facts, id: \.0.id) { ref, since in
                    ListRow(alignment: .firstTextBaseline, action: { model.openMemory(ref) }) {
                        EmptyView()
                    } title: {
                        memoryText(ref, replaced: replaced)
                            .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        if let since {
                            Text(Formatting.date(since))
                                .font(Theme.font(12))
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .padding(Theme.Space.xs)
                }
            }
        }
    }

    /// What someone said, as memory kept it, with when.
    private struct SaidCard: View {
        let said: MemoryNode.Said

        var body: some View {
            Card(.inset) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(said.words)
                        .font(Theme.font(13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let at = said.at {
                        Text(Formatting.dateAndTime(at))
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
