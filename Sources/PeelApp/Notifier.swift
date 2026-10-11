#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import PeelCore
import SwiftUI
import UserNotifications

/// Local notifications for messages that arrive while Peel runs, and the Dock
/// badge. Remote push is not an option: the server keeps one push token per
/// account and it belongs to the official app.
///
/// What notifies is PeelCore's `NotificationPolicy`: messages and payment
/// requests from others past the chat's read marker, a request to join a
/// tribe this account owns, a call someone started (as "Started a call"
/// under who started it), all by the chat's mute level; someone adding this
/// account as a contact (`contactAdded`); sats received, one notification
/// per arrival however many payments it holds (`moneyReceived`). Nothing
/// from the first history of a session or a restore, nothing where the
/// policy says the chat is quiet, and more than a few at once from one chat
/// (a catch-up after sleep) become one summary.
@MainActor @Observable
final class Notifier {
    enum Permission { case unavailable, notAsked, denied, allowed }

    private(set) var permission: Permission = .unavailable
    /// Whether a notification may say what a message says; kept with the account.
    var showsText = true
    /// "Not now" on the offer, for this Mac.
    private(set) var offerDismissed = UserDefaults.standard.bool(forKey: Notifier.offerDismissedKey)

    /// The chats, read states and lock state that decide what to show.
    @ObservationIgnored weak var model: AppModel?

    /// Nil when running outside an app bundle, where the notification
    /// center is not available, and offscreen, which posts nothing.
    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private let delegate: Delegate?
    @ObservationIgnored private var storage: Storage?
    /// True until the first history run of the session ends: what it brings
    /// is what the sidebar already counts on opening.
    @ObservationIgnored private var firstSync = true
    @ObservationIgnored private var pending: [Message] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Guards against a message delivered twice in one session.
    @ObservationIgnored private var posted: Set<String> = []
    @ObservationIgnored private var badge = 0
    /// Chats that may have notifications in Notification Center.
    @ObservationIgnored private var chatsShown: Set<String> = []

    private static let offerDismissedKey = "notificationOfferDismissed"
    private static let category = "message"
    /// More than this many from one chat at once become one summary.
    private static let summaryAbove = 3
    /// Messages arriving this close together are shown together.
    private static let gathering: Duration = .milliseconds(400)
    private static let hiddenText = "New message"
    /// The thread of money notifications; a click opens Payments.
    static let paymentsThread = "payments"

    init() {
        guard Bundle.main.bundleURL.pathExtension == "app", !Offscreen.isOn else {
            center = nil
            delegate = nil
            return
        }
        let center = UNUserNotificationCenter.current()
        self.center = center
        let delegate = Delegate()
        self.delegate = delegate
        center.delegate = delegate
        // When the system hides previews (the lock screen, by default), only
        // this shows: no sender, no text.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: Self.hiddenText, options: []
            ),
        ])
        delegate.open = { [weak self] chat, message in self?.model?.openFromNotification(chat, messageID: message) }
    }

    /// Whether to offer turning notifications on: never asked, not declined here.
    var offersPermission: Bool { permission == .notAsked && !offerDismissed }

    // MARK: Permission

    func refreshPermission() async {
        guard let center else { return }
        let current: Permission = switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        default: .allowed
        }
        if current != permission { permission = current }
    }

    /// Shows the system's question; the answer can be changed only in System Settings.
    func requestPermission() async {
        _ = try? await center?.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshPermission()
    }

    func dismissOffer() {
        offerDismissed = true
        UserDefaults.standard.set(true, forKey: Self.offerDismissedKey)
    }

    /// Peel's page in System Settings > Notifications.
    func openSystemSettings() {
        #if os(macOS)
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: Account

    func attach(_ storage: Storage, showsText: Bool) {
        clearSession()
        self.storage = storage
        self.showsText = showsText
        center?.getDeliveredNotifications { [weak self] notifications in
            let chats = Set(notifications.map(\.request.content.threadIdentifier))
            Task { @MainActor in self?.chatsShown.formUnion(chats) }
        }
    }

    /// The account is gone from this Mac: nothing of it stays on screen.
    func reset() {
        clearSession()
        setBadge(0)
        removeAllDelivered()
    }

    private func clearSession() {
        storage = nil
        flushTask?.cancel()
        flushTask = nil
        firstSync = true
        pending = []
        posted = []
    }

    /// Nothing an earlier notification said stays readable, for when Peel locks.
    func removeAllDelivered() {
        chatsShown = []
        center?.removeAllDeliveredNotifications()
    }

    // MARK: Messages

    func received(_ message: Message, _ arrival: Engine.Arrival) {
        guard center != nil, permission == .allowed else { return }
        switch arrival {
        case .live: break
        case .history: guard !firstSync else { return }
        case .restore: return
        }
        guard NotificationPolicy.kind(of: message, callServer: model?.callServer) != nil else { return }
        pending.append(message)
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gathering)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func historyEnded() {
        firstSync = false
    }

    private func flush() {
        flushTask = nil
        let batch = pending.filter { $0.uuid.map { posted.insert($0).inserted } ?? false }
        pending = []
        guard let center, let model, storage != nil else { return }
        let (policy, locked) = policy(model)
        for (chat, messages) in Dictionary(grouping: batch, by: \.chat) {
            let owns = model.tribes[chat]?.isOwner == true
            let shown = messages.filter {
                policy.notifies($0, ownsTribe: owns, callServer: model.callServer) != nil
            }
            guard !shown.isEmpty else { continue }
            // A call always shows on its own; more than a few others become one summary.
            let others = shown.filter { $0.type != MessageType.call }
            var single = shown
            if others.count > Self.summaryAbove {
                single = shown.filter { $0.type == MessageType.call }
                let (name, place) = names(chat, sender: others.last?.senderAlias)
                post(center, id: "summary-\(chat)", chat: chat, message: others.first?.id, locked: locked,
                     title: place ?? name, subtitle: nil, body: Formatting.count(others.count, "new message"))
            }
            for message in single {
                let member = Sender(member: message)
                let (name, place) = names(chat, sender: member.alias)
                post(center, id: message.uuid ?? UUID().uuidString, chat: chat, message: message.id, locked: locked,
                     title: place == nil ? name : member.name,
                     subtitle: place, body: body(of: message))
            }
            chatsShown.insert(chat)
        }
    }

    // MARK: Contacts

    /// Someone added this account (`Engine.Event.contactAdded`): the core
    /// accepted them already, so this is news, not a request. Not held to the
    /// read marker (answering them moves the server's past their key exchange
    /// at once); quiet for their chat open in front of you, and when muted.
    func contactAdded(_ message: Message) {
        guard let center, permission == .allowed, let model, storage != nil,
              message.uuid.map({ posted.insert($0).inserted }) ?? true else { return }
        let (policy, locked) = policy(model)
        guard !policy.isQuiet(message.chat) else { return }
        let (name, _) = names(message.chat, sender: message.senderAlias)
        post(center, id: "contact-\(message.uuid ?? UUID().uuidString)", chat: message.chat, message: nil,
             locked: locked, title: name, subtitle: nil, body: "Added you as a contact", hidden: "New contact")
        chatsShown.insert(message.chat)
    }

    // MARK: Money

    /// Sats received, gathered into one arrival: one notification for all of
    /// it. A payment or boost in a chat follows that chat's level (only
    /// "all" lets it through: it mentions nobody) and stays quiet for the chat
    /// open in front of you; a paid invoice (a request in a chat too) always
    /// shows. Nothing while Payments is open in front of you.
    func moneyReceived(_ receipts: [Receipt]) {
        guard let center, permission == .allowed, let model, storage != nil else { return }
        let (policy, locked) = policy(model)
        if !locked, model.isFrontmost, model.destination == .payments { return }
        let shown = receipts.filter { receipt in
            guard let chat = receipt.chat, receipt.kind != .invoice else { return true }
            return !policy.isQuiet(chat)
        }
        guard let first = shown.first else { return }
        var seen: Set<String> = []
        let sources = shown.map(source).filter { seen.insert($0).inserted }
        let body = shown.count == 1 ? describe(first, from: sources[0])
            : "From \(ListFormatter.localizedString(byJoining: sources))"
        post(center, id: "money-\(first.paymentHash ?? UUID().uuidString)", chat: Self.paymentsThread, message: nil, locked: locked,
             title: Receipt.label(shown), subtitle: nil, body: body, hidden: "Sats received")
        chatsShown.insert(Self.paymentsThread)
    }

    /// What decides, from what is on screen now, and whether Peel is locked
    /// (or due to lock), when a notification names nobody.
    private func policy(_ model: AppModel) -> (policy: NotificationPolicy, locked: Bool) {
        let locked = model.phase != .ready || model.isLockDue
        let inView = model.isFrontmost && !locked ? model.selectedChat : nil
        return (NotificationPolicy(chatInView: inView, readStates: model.readStates), locked)
    }

    /// A chat's name (a contact's, or the sender's when nothing is stored)
    /// and, for a tribe, "#name" as the place.
    private func names(_ chat: String, sender: String?) -> (name: String, place: String?) {
        let conversation = model?.conversations.first { $0.chat == chat }
        let name = conversation?.name ?? sender ?? Sender.unnamed
        return (name, conversation?.isTribe == true ? "#\(name)" : nil)
    }

    /// Who it came from: the contact, the tribe member and tribe, or an
    /// invoice (a request's chat names who paid it).
    private func source(_ receipt: Receipt) -> String {
        guard let chat = receipt.chat else { return "an invoice" }
        let (name, place) = names(chat, sender: receipt.member?.alias)
        guard let place else { return name }
        return "\(receipt.member?.name ?? Sender.unnamed) in \(place)"
    }

    private func describe(_ receipt: Receipt, from source: String) -> String {
        let note = self.note(receipt.note)
        switch receipt.kind {
        case .payment: return "From \(source)\(note)"
        case .boost: return "Boost from \(source)"
        case .invoice: return receipt.chat == nil ? "Invoice paid\(note)" : "\(source) paid your request\(note)"
        }
    }

    /// ": " and a payment's note or a request's memo, when notifications show text.
    private func note(_ text: String?) -> String {
        guard showsText, let text = text?.nilIfEmpty else { return "" }
        return ": \(text.prefix(200))"
    }

    private func body(of message: Message) -> String {
        if message.type == MessageType.memberRequest {
            return "\(Sender(member: message).name) wants to join"
        }
        // The title names who, the subtitle the tribe.
        if message.type == MessageType.call { return "Started a call" }
        if message.type == MessageType.invoice {
            guard let msat = message.amountMsat, msat > 0 else { return "Payment request\(note(message.preview))" }
            return "Requested \(Sats.format(msat: msat))\(note(message.preview))"
        }
        // Text, or for an attachment what it is ("Image", "File: notes.pdf").
        guard showsText, let preview = message.preview.nilIfEmpty else { return Self.hiddenText }
        return String(preview.prefix(400))
    }

    /// While Peel is locked a notification names nobody and says nothing.
    private func post(
        _ center: UNUserNotificationCenter, id: String, chat: String, message: Int64?, locked: Bool,
        title: String, subtitle: String?, body: String, hidden: String = hiddenText
    ) {
        let content = UNMutableNotificationContent()
        content.title = locked ? "Peel" : title
        if let subtitle, !locked { content.subtitle = subtitle }
        content.body = locked ? hidden : body
        content.sound = .default
        content.threadIdentifier = chat
        content.categoryIdentifier = Self.category
        var info: [String: Any] = ["chat": chat]
        info["message"] = message
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Read state

    /// Keeps the Dock badge equal to what the sidebar counts, and takes away
    /// the notifications of chats whose read marker moved, here or elsewhere.
    func readStatesChanged(to states: [String: ChatReadState], from previous: [String: ChatReadState], unread: Int) {
        setBadge(unread)
        let read = chatsShown.filter { chat in
            guard let before = previous[chat], let after = states[chat]?.lastRead else { return false }
            return after > before.lastRead ?? -1
        }
        removeDelivered(in: read)
    }

    private func setBadge(_ count: Int) {
        guard count != badge else { return }
        badge = count
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #endif
    }

    /// Takes away these chats' notifications, read or open in front of you.
    func removeDelivered(in chats: Set<String>) {
        let chats = chats.intersection(chatsShown)
        guard let center, !chats.isEmpty else { return }
        chatsShown.subtract(chats)
        // One that arrives while this runs is about a newer message: keep it.
        let now = Date.now
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { chats.contains($0.request.content.threadIdentifier) && $0.date <= now }
                .map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}

/// Receives clicks on notifications, which the system delivers off the main thread.
private final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Set once, on the main actor, before any notification is posted.
    @MainActor var open: ((String, Int64?) -> Void)?

    /// Shown even while Peel is in front: only chats other than the open one get here.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let chat = response.notification.request.content.userInfo["chat"] as? String else { return }
        let message = response.notification.request.content.userInfo["message"] as? Int64
        await MainActor.run { open?(chat, message) }
    }
}

/// Offers notifications once the account is open, saying what they are for.
struct NotificationOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "bell")
                .foregroundStyle(Theme.secondaryText)
            Text("Peel can show a notification when a message arrives while you're in another app or another chat.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The text gives way, never the buttons: their labels keep one line.
            Group {
                Button("Not now") { model.dismissNotificationOffer() }
                    .buttonStyle(.peel(.outline, size: .sm))
                Button("Turn on notifications") { Task { await model.enableNotifications() } }
                    .buttonStyle(.peel(.primary, size: .sm))
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }
}
