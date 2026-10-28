import Observation
import PeelCore
import PeelUI
import SwiftUI

/// The phone's tabs (docs/design/iphone.md, decision 1): Chats, Payments,
/// You, and the system's separate search tab.
enum PhoneTab: Hashable {
    case chats, payments, you, search
}

/// What Chats (and Search, which opens chats too) can push.
enum ChatsRoute: Hashable {
    case automations, threads, mentions
    /// The Stadeum workspaces' pinned apps (`AppsScreen`).
    case apps
    /// A tribe or a direct message, by its chat id. The agent is a DM, so
    /// its chat is one of these too.
    case chat(String)
    /// A chat's details: a contact's, or a tribe's (`openDetails`).
    case details(String)
    /// A tribe's members, from its details.
    case members(String)

    /// The model's destination while this route is on top.
    var destination: AppModel.Destination {
        switch self {
        case .automations: .automations
        case .apps: .apps
        case .threads: .threads
        case .mentions: .mentions
        case .chat(let chat), .details(let chat), .members(let chat): .chat(chat)
        }
    }

    /// The route showing `destination`; nil for one Chats does not push.
    init?(_ destination: AppModel.Destination) {
        switch destination {
        case .automations: self = .automations
        case .apps: self = .apps
        case .threads: self = .threads
        case .mentions: self = .mentions
        case .chat(let chat): self = .chat(chat)
        case .payments, .account, .agent, .app: return nil
        }
    }

    /// A conversation or a screen of one (its details, its members): the
    /// tab bar hides while it is shown, and it goes when its chat does.
    var isConversation: Bool {
        switch self {
        case .chat, .details, .members: true
        case .automations, .apps, .threads, .mentions: false
        }
    }
}

/// What Payments can push.
enum PaymentsRoute: Hashable {
    /// One payment's detail, by `PaymentItem.id`.
    case payment(PaymentItem.ID)
}

/// What You can push.
enum YouRoute: Hashable {
    case agent, words, changePIN, boostAmount, server
}

/// Which tab is shown and each tab's stack: the one place the phone's
/// navigation lives, so a screen, a notification or a link can open any of
/// it (`openChat`, `open(_:)`, `openThread`, `openPayment`).
///
/// The model's `destination` is still what is open, as on the Mac: it is
/// what marks a chat read, closes a thread that is not its chat's and
/// keeps money notifications away from Payments. The router writes it from
/// what is on screen (`shown`), and follows it when the model moves it
/// itself (`focus(on:)`, `openThread`, `openFromNotification`, a chat
/// removed), through `follow`.
@MainActor @Observable
final class PhoneRouter {
    var tab = PhoneTab.chats {
        didSet { if tab != oldValue { changedTab(from: oldValue) } }
    }
    var chats: [ChatsRoute] = [] { didSet { publish() } }
    var search: [ChatsRoute] = [] { didSet { publish() } }
    var payments: [PaymentsRoute] = []
    var you: [YouRoute] = []
    /// An org's page over everything (`OrgPageSheet`): a deliverable from
    /// the agent's DM, or a workspace's app.
    var orgPage: OrgPageRequest?
    /// The call screen is up over everything (`IOSCallScreen`); the call
    /// goes on, with its bar over the tabs, while it is down.
    var callShown = false

    @ObservationIgnored private let model: AppModel
    /// The thread open over a chat when its tab (Chats or Search) was
    /// left, opened again on coming back to that chat: leaving clears the
    /// model's, as the destination moves.
    @ObservationIgnored private var threadAway: [PhoneTab: ThreadRef] = [:]
    /// Set while `follow` changes the tab and a stack together, so the
    /// model hears the outcome once rather than the tab with the old stack.
    @ObservationIgnored private var holding = false
    /// The thread whose sheet is going down (`thread`).
    private var closingThread: ThreadRef?

    init(model: AppModel) {
        self.model = model
    }

    /// What the visible screen is, as the model names it.
    var shown: AppModel.Destination? {
        switch tab {
        case .chats: chats.last?.destination
        case .search: search.last?.destination
        case .payments: .payments
        case .you: .account
        }
    }

    /// Back to a fresh Chats tab with nothing pushed: onboarding (an account
    /// forgotten from You, or a restore) must not reopen on the tab the last
    /// account was left on (Profile).
    func reset() {
        holding = true
        tab = .chats
        chats = []
        search = []
        payments = []
        you = []
        orgPage = nil
        holding = false
        publish()
    }

    // MARK: Opening things

    /// A chat, pushed over the Chats list (or the list it was opened from,
    /// if Threads or Mentions is open), in the Chats tab.
    func openChat(_ chat: String) {
        model.destination = .chat(chat)
    }

    /// A message: its chat at the message, lit for a moment; with
    /// `inThread`, the thread sheet over it (`AppModel.focus(on:)`).
    func open(_ message: Message, inThread: Bool = false) {
        model.focus(on: message, inThread: inThread)
    }

    /// A chat's details (a contact's or a tribe's), pushed over its
    /// conversation: on top of it when it is the one shown, else with it
    /// under, in the tab showing chats.
    func openDetails(_ chat: String) {
        changeChatStack { stack in
            if stack.last != ChatsRoute.chat(chat) {
                stack = stack.filter { !$0.isConversation } + [.chat(chat)]
            }
            stack.append(.details(chat))
        }
    }

    /// A tribe's members, over its details.
    func openMembers(_ chat: String) {
        changeChatStack { $0.append(.members(chat)) }
    }

    /// Changes the stack chats are shown in: Search's while it is the tab,
    /// else Chats', which it brings to the front.
    private func changeChatStack(_ change: (inout [ChatsRoute]) -> Void) {
        if tab == .search {
            change(&search)
        } else {
            var stack = chats
            change(&stack)
            tab = .chats
            chats = stack
        }
    }

    /// A thread: its chat with the thread sheet over it.
    func openThread(_ thread: ThreadRef) {
        model.openThread(thread)
    }

    /// One payment's detail in Payments.
    func openPayment(_ id: PaymentItem.ID) {
        tab = .payments
        payments = [.payment(id)]
    }

    /// The thread sheet's binding: the model's open thread. Dismissed, it
    /// stays open in the model, rows and all, until the sheet has gone
    /// (`threadDismissed`), so it never slides down blank.
    var thread: Binding<ThreadRef?> {
        Binding { [self] in
            model.openThread == closingThread ? nil : model.openThread
        } set: { [self] thread in
            if let thread {
                closingThread = nil
                model.openThread(thread)
            } else {
                closingThread = model.openThread
            }
        }
    }

    /// The thread sheet has gone: its thread closes (its draft kept, as the
    /// model keeps drafts), unless it was opened again meanwhile.
    func threadDismissed() {
        if let closingThread, model.openThread == closingThread { model.closeThread() }
        closingThread = nil
    }

    // MARK: Keeping the model and the stacks together

    /// Tells the model what is now on screen, and opens the thread that
    /// was open over it when its tab was left.
    private func publish() {
        guard !holding else { return }
        let shown = shown
        if model.destination != shown {
            var quietly = Transaction()
            quietly.disablesAnimations = true
            withTransaction(quietly) { model.destination = shown }
        }
        if let thread = threadAway.removeValue(forKey: tab), model.selectedChat == thread.chat {
            model.openThread = thread
        }
    }

    private func changedTab(from old: PhoneTab) {
        if old == .chats || old == .search, let thread = model.openThread {
            threadAway[old] = thread
        }
        // Search's words filter the chat list everywhere (`sidebarSections`).
        if old == .search { model.searchQuery = "" }
        publish()
    }

    /// The model moved its destination itself (`focus(on:)`, `openThread`,
    /// a notification, a chat removed): show it. A chat goes on top of the
    /// list it was opened from (Threads, Mentions), replacing a chat
    /// already open; any other destination is its tab or its list. Called
    /// on every change, locked or not (`RootView`).
    func follow(_ destination: AppModel.Destination?) {
        guard destination != shown else { return }
        holding = true
        switch destination {
        case .chat(let chat):
            changeChatStack { $0 = $0.filter { !$0.isConversation } + [.chat(chat)] }
        case .threads, .mentions, .automations, .apps:
            tab = .chats
            chats = destination.flatMap(ChatsRoute.init).map { [$0] } ?? []
        case .payments:
            tab = .payments
        case .account:
            tab = .you
        case .agent, .app:
            // The Mac's own agent chat and an app in its detail column; on the
            // phone the agent is a DM and an app opens over everything
            // (`orgPage`), so the model is put back on what Chats shows.
            tab = .chats
        case nil:
            // What was open is gone (a chat removed): back to its list.
            chats.removeAll { $0.isConversation }
            search.removeAll { $0.isConversation }
        }
        holding = false
        publish()
    }
}
