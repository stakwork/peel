import PeelCore
import PeelUI
import SwiftUI

/// A strut proposal's card in the agent chat (`ProposalRecord`,
/// docs/agent-on-strut.md, "Built: proposal cards"): `Callout`'s box with
/// the title, where it is, what the step read, the facts the person
/// decides on (`Fact`'s rows on the chat's inset card; a field with
/// `danger` tinted as a loss, the one red), the model's reason apart, and
/// either the card's own two buttons or how it ended, as a badge at the top right.
/// One renderer for every step, Peel's own strut's (on its request's line,
/// `DeviceRequestLine`), a workspace's (at the end of the chat,
/// `AgentListRow.proposal`) and one on Jamie's post in a tribe
/// (`TribeProposalCards`, decided by the tribe's owner from there). Amber
/// while it waits, as the approval card; the same keys as it
/// (`answerKeys`): Return accepts only a card read whole with nothing in
/// it that warns, Escape rejects.
struct ProposalCardView: View {
    /// How it stands here, beyond the record: waiting on you with the
    /// buttons; answered on this Mac (how, from the request's result: nil
    /// while the Mac has not), the record to follow; being decided on the
    /// workspace, or answered in the tribe (the reply on its way); in a
    /// tribe, someone else's to decide (the owner's). The owner's answer
    /// in a tribe is the record's own (`KeptProposal.answer`).
    enum Stance: Equatable {
        case waiting
        case answered(ControlEnvelope.Status?)
        case deciding(accept: Bool)
        case theirs
    }

    /// Under a tribe's card the owner answered that Jamie has not ended in time.
    static let noAnswerYet = "No answer yet: the reply may not have reached Jamie. You can answer again."
    /// A tribe's card for everyone but its owner.
    static let ownersLine = "The tribe's owner decides this."

    let proposal: KeptProposal
    /// The workspace it is on, by name; nil for Peel's own strut.
    let org: String?
    let stance: Stance
    /// What the last read or decision said that the record does not.
    let note: String?
    /// The whole input, opened under the card when the fields do not cover it.
    let input: AgentDisclosure
    /// Accept or reject; nil once it is not yours to answer here.
    let answer: ((Bool) -> Void)?
    /// Everything under the title, opened by a click on it; nil where it
    /// always shows. A tribe's card starts shut: the post is someone else's.
    var details: AgentDisclosure?

    @Environment(\.listRowExpanding) private var expanding

    var body: some View {
        TimelineView(.redrawing(at: changesAt)) { context in
            card(at: context.date)
        }
    }

    private func card(at now: Date) -> some View {
        let shown = Self.state(of: proposal, stance: stance, at: now)
        let card = proposal.record.shownCard
        let waiting = shown == .waiting
        let open = details?.isOpen ?? true
        // `Callout`'s box and tokens, drawn here: inside its baseline-aligned row a
        // long field, changed in place (the badge, the input opened), measured a line short.
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header(card, shown: shown, open: open)
            if open {
                if let summary = card.summary {
                    Text(summary).muted().textSelection(.enabled)
                }
                if !card.fields.isEmpty {
                    Card(.inset) {
                        VStack(spacing: 0) {
                            ForEach(Array(card.fields.enumerated()), id: \.offset) { index, field in
                                if index > 0 { Theme.divider.frame(height: 1) }
                                ProposalFact(field: field)
                            }
                        }
                    }
                }
                if proposal.record.cardUnreadable {
                    Text("Peel can't read this card's details; what is shown comes from the input.")
                        .muted()
                        .foregroundStyle(Theme.attention)
                }
                if !card.full {
                    ProposalFullInput(record: proposal.record, disclosure: input)
                }
                if let rationale = proposal.record.rationale {
                    (Text("The assistant's reason: ").foregroundStyle(Theme.secondaryText) + Text(rationale).italic())
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = Self.outcomeLine(shown, record: proposal.record) {
                    Text(line).muted().textSelection(.enabled)
                }
                if let note = note ?? (proposal.isAnswerStale(at: now) ? Self.noAnswerYet : nil) {
                    Text(note).muted().foregroundStyle(Theme.attention)
                }
                if waiting, let answer {
                    HStack(spacing: Theme.Space.sm) {
                        Button(card.accept) { answer(true) }
                            .buttonStyle(.peel(.primary, size: .sm))
                            .help(proposal.record.acceptsByKey ? "Return" : "Click to accept")
                        Button(card.reject) { answer(false) }
                            .buttonStyle(.peel(.ghost, size: .sm))
                            .help("Escape")
                        Text("Nothing changes until you accept.")
                            .muted()
                            .padding(.leading, Theme.Space.xs)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(waiting ? Theme.attention.opacity(0.07) : Theme.panel, in: shape)
        .overlay(shape.strokeBorder(waiting ? Theme.attention.opacity(0.28) : Theme.divider))
        .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
        // Shut, it takes no key: what Return would accept is not on the screen.
        .answerKeys(enabled: waiting && answer != nil && open, returnAccepts: proposal.record.acceptsByKey) {
            answer?(true)
        } reject: {
            answer?(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(waiting ? "Waiting on you: \(card.title)" : "\(card.title): \(shown.label?.lowercased() ?? "")")
    }

    /// The title, where it is from and how it stands. With `details` a
    /// click on it opens or shuts the rest, and shut, one waiting on you says so.
    @ViewBuilder
    private func header(_ card: ProposalCard, shown: State, open: Bool) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            if details != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
            Image(systemName: "checklist")
                .font(.system(size: 13))
                .foregroundStyle(shown == .waiting ? Theme.attention : Theme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                let title = Text(card.title)
                    .font(Theme.font(13, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                // A title that opens the card takes the click, not a selection.
                if details == nil { title.textSelection(.enabled) } else { title }
                Text([org.map { "From \($0)" }, proposal.record.step].compactMap { $0 }.joined(separator: " · "))
                    .muted()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.sm)
            if !open, shown == .waiting {
                Text("Waiting on you").muted().foregroundStyle(Theme.attention)
            } else {
                ProposalStatus(shown: shown)
            }
        }
        if let details {
            Button {
                details.toggle(expanding: expanding)
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the details" : "Show the details")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
        } else {
            row
        }
    }

    /// When the card says something else without a new read: the second its
    /// request runs out, while it waits; in a tribe, when the owner's reply
    /// has waited long enough on Jamie's word.
    private var changesAt: Date? {
        guard proposal.record.isOpen, !proposal.isOver else { return nil }
        if let notAfter = proposal.notAfter { return Date(timeIntervalSince1970: TimeInterval(notAfter + 1)) }
        return proposal.answerStaleAt?.addingTimeInterval(1)
    }

    /// What the card shows of where the proposal stands.
    enum State: Equatable {
        /// Pending and yours to answer here.
        case waiting
        /// Pending; this Mac's card is not up (not asked again yet), or it is being decided elsewhere.
        case pending
        /// Pending, and the tribe's owner's to decide, not yours.
        case theirs
        /// Answered here; strut is being told.
        case telling(accepted: Bool)
        /// Accepted: the step runs.
        case running
        case applied
        case rejected
        case failed
        /// Its card ran out while it waited here.
        case expired
        /// strut no longer has it.
        case gone
        /// Not this person's to see.
        case notYours
        /// Its record never read.
        case unreadable

        /// The badge's word; none while it waits on you (the buttons say it).
        var label: String? {
            switch self {
            case .waiting: nil
            case .pending, .theirs: "Pending"
            case .telling(let accepted): accepted ? "Accepting…" : "Rejecting…"
            case .running: "Running…"
            case .applied: "Applied"
            case .rejected: "Rejected"
            case .failed: "Failed"
            case .expired: "Expired"
            case .gone: "Gone"
            case .notYours: "Not yours"
            case .unreadable: "Unread"
            }
        }

        /// Something is under way: a spinner beside the word.
        var isWorking: Bool {
            switch self {
            case .telling, .running: true
            default: false
            }
        }

        /// The badge's style: green for done, amber for a step that failed
        /// (nothing was lost), a plain outline for the rest.
        var badge: Badge.Style {
            switch self {
            case .applied: .success
            case .failed: .attention
            default: .outline
            }
        }
    }

    static func state(of proposal: KeptProposal, stance: Stance, at now: Date) -> State {
        switch proposal.ending {
        case .gone?: return .gone
        case .forbidden?: return .notYours
        case .unreadable?: return .unreadable
        case .final?, nil: break
        }
        switch proposal.record.status {
        case .applied: return .applied
        case .rejected: return .rejected
        case .failed: return .failed
        case .accepted: return .running
        case .pending: break
        }
        // Past the card's time with no word from strut: whatever was answered here, it waits on strut now.
        let expired = proposal.isExpired(at: now)
        if case .answered(let status) = stance, let status {
            switch status {
            case .done: return expired ? .pending : .telling(accepted: true)
            case .denied: return expired ? .pending : .telling(accepted: false)
            case .expired: return .expired
            case .failed, .unknown: return .pending
            }
        }
        if case .deciding(let accept) = stance { return .telling(accepted: accept) }
        if stance == .theirs { return .theirs }
        // The owner's reply in a tribe, until Jamie's word; the buttons again once it has waited too long.
        if let accept = proposal.answer, proposal.answeredAt != nil {
            return proposal.isAnswerStale(at: now) ? .waiting : .telling(accepted: accept)
        }
        if expired { return .expired }
        return stance == .waiting ? .waiting : .pending
    }

    /// The line under the facts once it is over, or on its way; the watch's
    /// note says why for gone, not yours and unreadable.
    static func outcomeLine(_ state: State, record: ProposalRecord) -> String? {
        switch state {
        case .waiting, .telling, .running, .gone, .notYours, .unreadable: return nil
        case .pending: return "Waiting for a decision."
        case .theirs: return ownersLine
        case .applied: return "Done" + (record.result?.at.map { " at \(Formatting.time($0))" } ?? "") + "."
        case .rejected: return "Not done" + (record.decision?.reason.map { ": \($0)" } ?? ".")
        case .failed: return "The step did not work" + (record.result?.error.map { ": \($0)" } ?? ".")
        case .expired: return "The card ran out before it was answered; nothing was done."
        }
    }
}

/// One field of the card, as a `Fact` lays one out (its name in the
/// column, the value as `FactText`: code monospaced, a warning's icon and
/// tint) without `Fact`'s layout for an action at the end, which has none here.
private struct ProposalFact: View {
    let field: ProposalCard.Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(field.label)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 110, alignment: .leading)
            FactText(text: field.shownValue, symbol: field.danger ? "exclamationmark.triangle.fill" : nil,
                     tint: field.danger ? Theme.destructive : nil, monospaced: field.kind == .code)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font(13))
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
    }
}

/// The badge at the card's top right: nothing while it waits on you, a
/// spinner with the word while strut is told or the step runs, then how it ended.
private struct ProposalStatus: View {
    let shown: ProposalCardView.State

    var body: some View {
        if let label = shown.label {
            if shown.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(label).muted()
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            } else {
                Badge(label, shown.badge)
            }
        }
    }
}

/// Under fields that leave part of the input out: that not everything is
/// shown, and the whole input on a click, as text; or that it is more than
/// Peel keeps of one, or that it never came (a tribe's post).
private struct ProposalFullInput: View {
    @Environment(\.listRowExpanding) private var expanding
    let record: ProposalRecord
    let disclosure: AgentDisclosure

    var body: some View {
        let text = record.inputText
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Not everything is shown.").muted()
                if text != nil {
                    Button(disclosure.isOpen ? "Hide the full input" : "Show the full input") {
                        disclosure.toggle(expanding: expanding)
                    }
                    .buttonStyle(.peel(.link, size: .sm))
                } else if record.inputCut {
                    Text("The full input is larger than Peel keeps; strut has it.").muted()
                } else {
                    // A tribe's post carries the card alone.
                    Text("The rest wasn't sent with it.").muted()
                }
            }
            if disclosure.isOpen, let text {
                ScrollView(.horizontal) {
                    Text(text)
                        .font(Theme.code(11))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(Theme.Space.sm)
                }
                .frame(maxHeight: 320)
                .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
        }
    }
}

/// A workspace's proposal at the end of the agent chat (`AgentListRow.proposal`):
/// its card as the watch hands it (`OrgCard`), decided there with the
/// person's token (`ProposalWatch.decide`).
struct OrgProposalRow: View {
    @Environment(AppModel.self) private var model
    let card: OrgCard
    let rowID: String

    var body: some View {
        let watch = model.proposals
        ProposalCardView(
            proposal: card.kept, org: card.org, stance: card.deciding.map { .deciding(accept: $0) } ?? .waiting, note: card.note,
            input: AgentDisclosures(rowID: rowID, rows: model.agentOpenRows).open("input"),
            answer: card.deciding != nil || card.kept.isOver ? nil : { accept in Task { await watch.decide(card.key, accept: accept) } }
        )
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// strut's proposals a member's (Jamie's) post in a tribe made, each as
/// its card under the post (`ChatRow.strutProposals`, docs/hive-tribes.md,
/// "Proposals in a tribe"), as the watch keeps it from the tribe's posts
/// (`AppModel.proposals`): a card only for a proposal whose post this is
/// (a later post claiming one draws none). Each starts shut to its title
/// and how it stands; a click on the title opens it. The tribe's owner (`canAnswer`)
/// gets the card's buttons, and answers by a reply to the post
/// (`ProposalWatch.answerInTribe`); everyone else sees the card, how it
/// stands, and that the owner decides it.
struct TribeProposalCards: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    let canAnswer: Bool

    var body: some View {
        if let proposals = row.strutProposals {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(proposals.proposed, id: \.id) { record in
                    card(ProposalKey(source: .org(proposals.workspace), id: record.id))
                }
            }
            .agentNoteRow()
        }
    }

    @ViewBuilder
    private func card(_ key: ProposalKey) -> some View {
        let watch = model.proposals
        let disclosures = AgentDisclosures(rowID: row.id, rows: model.agentOpenRows)
        if let proposal = watch.kept[key], proposal.post?.uuid == row.message.uuid {
            let stance: ProposalCardView.Stance = if let accept = watch.deciding[key] {
                .deciding(accept: accept)
            } else {
                canAnswer ? .waiting : .theirs
            }
            ProposalCardView(
                proposal: proposal, org: watch.orgName(key.source), stance: stance, note: watch.notes[key],
                input: disclosures.open("input-\(key.id)"),
                answer: canAnswer && !proposal.isOver
                    ? { accept in Task { await watch.answerInTribe(key, accept: accept, on: row.message) } } : nil,
                details: disclosures.open("card-\(key.id)")
            )
        }
    }
}

extension ProposalRecord {
    /// A first guess at its card's height, for a row not yet measured
    /// (`AgentListRow`): the header and the buttons or badge, a
    /// row per field, the summary and the reason when there are any.
    var estimatedCardHeight: CGFloat {
        let shown = shownCard
        return 110 + CGFloat(shown.fields.count) * 37 + (shown.summary == nil ? 0 : 50) + (rationale == nil ? 0 : 20)
    }

    /// The same for a card shut to its title (a tribe's, `ChatRow`).
    static let estimatedShutCardHeight: CGFloat = 56
}
