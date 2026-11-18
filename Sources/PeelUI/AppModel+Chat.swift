import Foundation
import Observation
import PeelCore
import PeelDiagnostics

/// A thread, by its chat and its original's uuid.
public struct ThreadRef: Hashable, Sendable, Identifiable {
    public let chat: String
    public let uuid: String

    /// Itself, so a sheet can be presented for one.
    public var id: Self { self }

    public init(chat: String, uuid: String) {
        self.chat = chat
        self.uuid = uuid
    }
}

/// A message to bring into view; see `AppModel.focus(on:)`.
public struct FocusTarget: Equatable, Sendable {
    public let message: Message
    public let inThread: Bool
}

/// Where a message list stood when last still: following the newest, or a
/// row (never a divider) with its top `offset` points below the list's top,
/// negative when it is cut off above. Kept per list (`AppModel.anchor(of:)`)
/// so a list made again, or a chat come back to, opens where it was.
public enum ListAnchor: Equatable, Sendable {
    case newest
    case row(id: String, offset: Double)
}

/// Which composer: a chat's own, a thread panel's, or the agent chat's.
public enum ComposerID: Hashable, Sendable {
    case chat(String)
    case thread(ThreadRef)
    /// The agent chat's list before its DM is the chat: the earlier turns,
    /// read only, with no composer.
    case agent

    /// The Sphinx chat it writes in; nil for the agent's.
    public var chat: String? {
        switch self {
        case .chat(let chat): chat
        case .thread(let thread): thread.chat
        case .agent: nil
        }
    }

    /// Whether files can go with what it sends.
    public var takesFiles: Bool { self != .agent }

    public var thread: String? {
        if case .thread(let thread) = self { thread.uuid } else { nil }
    }
}

/// The image viewer: one sender's images in a run, and which one shows.
public struct ImageViewerState: Equatable, Sendable {
    public var messages: [Message]
    public var index: Int

    public var current: Message { messages[min(index, messages.count - 1)] }
}

/// One attachment's download, upload progress and local copy. Observed on
/// its own so a progress tick redraws only the tile that shows it.
@MainActor @Observable
public final class AttachmentHandle {
    public enum State: Sendable {
        case idle
        case downloading
        case ready(DownloadedAttachment)
        /// Too large to fetch on its own (a video or recording): it waits
        /// for a click. Its size, when known.
        case held(Int64?)
        /// A failure that may pass (offline, a timeout, the app was
        /// backgrounded mid-transfer, a server hiccup, the file not there
        /// yet): not final. An automatic retry may be scheduled
        /// (`AppModel.download`), and it is tried again when the app returns
        /// to the front, the connection comes back or the tile is tapped.
        /// `attempt` counts the failures so far.
        case retrying(reason: String, attempt: Int)
        /// A failure no retry mends (`MediaFetch.isTransient`): final until a tap.
        case failed(String)
    }

    public var state: State = .idle
    /// Bytes so far of the total, while an upload or download runs.
    public var progress: (bytes: Int64, total: Int64)?
    /// For one of ours still uploading: the file picked on this Mac.
    public var localFile: URL?
    /// Where its file was saved in Downloads, once it was.
    public var savedTo: URL?
    /// The download running now, for others asking meanwhile to wait on.
    @ObservationIgnored public var download: Task<Void, Never>?
    /// Automatic retries spent since the last tap, foreground or reconnect.
    @ObservationIgnored var attempts = 0
    /// The scheduled automatic retry, owned by the model like `download`.
    @ObservationIgnored var retry: Task<Void, Never>?
    /// What a retry fetches: the message, and whether a person asked for it
    /// (a retry then ignores the automatic limits).
    @ObservationIgnored var retrying: (message: Message, userAsked: Bool)?

    public func transfer(bytes: Int64, total: Int64) {
        progress = bytes < total ? (bytes, total) : nil
    }

    public var file: URL? {
        if case .ready(let downloaded) = state { downloaded.file } else { localFile }
    }

    public var downloaded: DownloadedAttachment? {
        if case .ready(let downloaded) = state { downloaded } else { nil }
    }

    /// Why its download failed for good, when it did; a transient failure
    /// is `isRetrying`, not this.
    public var failureReason: String? {
        if case .failed(let reason) = state { reason } else { nil }
    }

    /// Whether it waits for a tap because of its size.
    public var isHeld: Bool {
        if case .held = state { true } else { false }
    }

    /// Whether nothing was tried yet.
    public var isIdle: Bool {
        if case .idle = state { true } else { false }
    }

    /// Whether its last download failed in a way that may pass.
    public var isRetrying: Bool {
        if case .retrying = state { true } else { false }
    }

    /// Why its last download failed, when it may pass.
    public var retryReason: String? {
        if case .retrying(let reason, _) = state { reason } else { nil }
    }
}

extension AppModel {
    // MARK: Replies and threads

    /// Replies to a message from the composer it was chosen in.
    public func reply(to message: Message, in composer: ComposerID) {
        replyTargets[composer] = message
        composerFocus[composer, default: 0] += 1
    }

    public func cancelReply(in composer: ComposerID) {
        replyTargets[composer] = nil
    }

    /// Whether files can go with what `composer` sends: the agent's DM
    /// takes them too (its agent reads them, `AttachmentText`).
    public func takesFiles(_ composer: ComposerID) -> Bool {
        composer.takesFiles
    }

    /// Whether `file`, waiting in `composer`, has the "Let the model see
    /// this picture" switch: a picture in the agent chat only.
    public func offersModelSight(_ file: URL, in composer: ComposerID) -> Bool {
        isAgentChat(composer) && ModelSight.offers(file)
    }

    public func modelMaySee(_ file: URL, in composer: ComposerID) -> Bool {
        modelSight.allows(file, in: composer)
    }

    public func setModelMaySee(_ on: Bool, for file: URL, in composer: ComposerID) {
        guard offersModelSight(file, in: composer) else { return }
        modelSight.set(on, for: file, in: composer)
    }

    /// Whether `composer` may sell files and take a price for them: not the agent's DM.
    public func sellsFiles(_ composer: ComposerID) -> Bool {
        takesFiles(composer) && !isAgentChat(composer)
    }

    /// Whether `composer` is the agent chat's: its DM's.
    public func isAgentChat(_ composer: ComposerID) -> Bool {
        composer.chat != nil && composer.chat == agentChat
    }

    /// Escape in a composer: stops replying, else closes its thread panel.
    /// Returns whether it was taken.
    public func escape(in composer: ComposerID) -> Bool {
        if isAgentChat(composer), agentHost?.closeMemory(in: self) == true { return true }
        if replyTargets[composer] != nil {
            replyTargets[composer] = nil
            return true
        }
        guard composer.thread != nil else { return false }
        closeThread()
        return true
    }

    /// Who sent a message, by the rows' own rule (`People.sender(of:inTribe:)`);
    /// lists, quotes and the viewer name them by `label`.
    public func sender(of message: Message) -> Sender {
        let conversation = conversations.first { $0.chat == message.chat }
        return people(in: message.chat, conversation: conversation)
            .sender(of: message, inTribe: conversation?.isTribe ?? false)
    }

    /// Whether Delete is offered: the engine's rule (`Message.isDeletable`),
    /// with the thread's size read when the menu opens.
    public func canDelete(_ message: Message, inTribe: Bool) -> Bool {
        guard let uuid = message.uuid, let storage = engine?.storage else { return false }
        let owns = tribes[message.chat]?.canManage ?? false
        let count = (try? storage.threadCount(uuid, in: message.chat)) ?? 0
        return message.isDeletable(inTribe: inTribe, ownsTribe: owns, threadCount: count)
    }

    /// The one Reply: inline, under the conversation or in the open thread,
    /// except for a message folded into a collapsed tribe thread (not its
    /// own row in the chat), which is answered in that thread's panel.
    /// Either way the engine sends the same links: a reply joins or starts
    /// the parent's thread, as in the official apps.
    public func startReply(to message: Message, from composer: ComposerID) {
        if case .chat = composer, message.chat == selectedChat, timeline.threads[message.threadRoot] != nil {
            let thread = ThreadRef(chat: message.chat, uuid: message.threadRoot)
            openThread(thread)
            reply(to: message, in: .thread(thread))
        } else {
            reply(to: message, in: composer)
        }
    }

    /// Opens the thread a message is in, or the one it would start.
    public func openThread(of message: Message) {
        let root = message.threadRoot
        guard !root.isEmpty else { return }
        openThread(ThreadRef(chat: message.chat, uuid: root))
    }

    /// Opens a thread from anywhere (the Threads list), in its chat.
    public func openThread(_ thread: ThreadRef) {
        if selectedChat != thread.chat { destination = .chat(thread.chat) }
        openThread = thread
        composerFocus[.thread(thread), default: 0] += 1
    }

    /// From the Threads list: the thread, at its first new reply when it has some.
    public func openThread(_ summary: ThreadSummary) {
        let marker = readStates[summary.chat]?.lastRead ?? -1
        if summary.unread > 0,
           let first = try? engine?.storage.firstUnreadReply(inThread: summary.uuid, in: summary.chat, after: marker) {
            focus(on: first, inThread: true)
        } else {
            openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid))
        }
    }

    /// Opens a chat's details (a contact's, a tribe's) in the side panel,
    /// closing the open thread.
    public func openDetails(of chat: String) {
        closeThread()
        detailsChat = chat
    }

    public func closeThread() {
        if let openThread { replyTargets[.thread(openThread)] = nil }
        openThread = nil
    }

    /// Leaves a tribe, or removes one this account can no longer post in
    /// (`Tribe.exit`): the one way the menu, the members panel, the details
    /// and the status bar go. A failure shows in that chat.
    public func leave(_ pubkey: String) async {
        guard let engine else { return }
        let exit = tribes[pubkey]?.exit
        do {
            try await engine.leaveTribe(pubkey)
            if selectedChat == pubkey { destination = nil }
        } catch {
            conversationNotices[pubkey] = PeelError.noted(error, couldNot: (exit ?? .leave).failure)
        }
    }

    /// Threads with replies past their chat's read marker.
    public var unreadThreads: Int { threads.filter { $0.unread > 0 }.count }

    /// Marks a chat read up to its newest message; thread unread clears with it.
    public func markRead(_ chat: String) async {
        await attempt("mark as read", in: chat) { try await $0.markRead(chat) }
    }

    /// Mark as read or Mark as unread for a chat's menu (`ReadToggle`):
    /// storage is read only when nothing is unread, as the menu is built.
    public func readToggle(for chat: String) -> ReadToggle? {
        ReadToggle.offered(unread: readStates[chat]?.unread ?? 0) {
            (try? engine?.storage.newestIncomingIndex(in: chat)) != nil
        }
    }

    public func markAllThreadsRead() async {
        for chat in Set(threads.filter { $0.unread > 0 }.map(\.chat)) {
            await markRead(chat)
        }
    }

    // MARK: Sending

    /// Who `@` offers in a tribe's composers.
    public func mentionLoader(_ chat: String) -> @MainActor @Sendable () async -> [TribeMember] {
        { [weak self] in await self?.mentionCandidates(in: chat) ?? [] }
    }

    /// Sends a composer's draft and files; if nothing went, the text comes
    /// back unless something new was typed meanwhile.
    public func sendDraft(from composer: ComposerID) async {
        let text = (drafts[composer] ?? "").trimmed
        drafts[composer] = nil
        if await !send(text, from: composer), (drafts[composer] ?? "").isEmpty, !text.isEmpty {
            drafts[composer] = text
        }
    }

    /// Sends `text` to `chat` (a reply to `replyTo`, in `inThread`) and
    /// marks the chat as sent to: the composer's text-only send, and the
    /// tribe owner's answer to a proposal on Jamie's post.
    func sendText(_ text: String, to chat: String, replyTo: String? = nil, inThread: String? = nil) async throws {
        guard let engine else { throw PeelError("the account is closed.") }
        try await engine.sendText(text, to: chat, replyTo: replyTo, inThread: inThread)
        sent(in: chat)
    }

    /// A text on its own to `chat`, as voice mode sends what was said: none
    /// of the composer's files, reply target or thread go with it, and they
    /// stay in the composer. Returns whether it went; why not is the chat's
    /// notice.
    public func sendDictated(_ text: String, to chat: String) async -> Bool {
        guard engine != nil else { return false }
        guard myAlias?.nilIfEmpty != nil else {
            conversationNotices[chat] = "Set your name before sending messages"
            return false
        }
        Diagnostics.setAction(.send)
        defer { Diagnostics.setAction(.other) }
        conversationNotices[chat] = nil
        do {
            try await sendText(text, to: chat)
            return true
        } catch {
            conversationNotices[chat] = PeelError.noted(error, couldNot: "send")
            return false
        }
    }

    /// Sends what a composer holds: its files, one message each, with the
    /// text as the last one's caption (or on its own), all with the reply
    /// and thread links the composer was set to. Returns whether the text
    /// went (true when there was none); refused files go back in the tray
    /// with the reply target. The engine sends the files
    /// (`Engine.sendAttachments`).
    @discardableResult
    public func send(_ text: String, from composer: ComposerID) async -> Bool {
        guard let engine, let chat = composer.chat else { return false }
        // A restore with no sent history to recover it from can settle with
        // no name; nothing goes out under none (the composers also disable
        // Send for the same reason, this is the backstop).
        guard myAlias?.nilIfEmpty != nil else {
            conversationNotices[chat] = "Set your name before sending messages"
            return false
        }
        Diagnostics.setAction(.send)
        defer { Diagnostics.setAction(.other) }
        let files = pendingFiles[composer] ?? []
        // Nothing is sold to the agent, even by a price left over from another chat.
        let priceText = isAgentChat(composer) ? nil : attachmentPrices[composer]
        let seen = modelSight.take(files, from: composer)
        let priceSats = priceText.flatMap { UInt64($0) }
        let reply = replyTargets[composer]
        let replyTo = reply?.uuid
        let inThread = composer.thread
        pendingFiles[composer] = nil
        attachmentPrices[composer] = nil
        replyTargets[composer] = nil
        conversationNotices[chat] = nil
        if files.isEmpty {
            do {
                try await sendText(text, to: chat, replyTo: replyTo, inThread: inThread)
                return true
            } catch {
                conversationNotices[chat] = PeelError.noted(error, couldNot: "send")
                replyTargets[composer] = reply
                return false
            }
        }
        let outcome = await engine.sendAttachments(
            files, text: text, to: chat, replyTo: replyTo, inThread: inThread, priceSats: priceSats,
            modelMaySee: isAgentChat(composer) ? seen : []
        ) { [weak self] file, id in
            // Shown from this Mac while it uploads.
            Task { @MainActor in self?.attachment(id).localFile = file }
        }
        var refused: [(file: URL, reason: String)] = []
        for (file, result) in outcome.results {
            switch result {
            case .success(let id):
                // A pasted or promised file of Peel's is done with once
                // uploaded: the engine keeps its own copy in the cache. One
                // whose upload failed stays as the row's preview until the
                // account closes.
                if IncomingFiles.owns(file), (try? engine.storage.message(id: id))?.uploadState == .done {
                    release(file)
                }
                sent(in: chat)
            case .failure(let error):
                refused.append((file, PeelError.noted(error, couldNot: "send \(file.lastPathComponent)")))
            }
        }
        if !refused.isEmpty {
            conversationNotices[chat] = refused.map(\.reason).joined(separator: " ")
            // What did not go waits in the composer again, with the reply it was for.
            pendingFiles[composer, default: []].insert(contentsOf: refused.map(\.file), at: 0)
            modelSight.restore(refused.map(\.file), on: seen, in: composer)
            // With their price: a refused paid file must never go again free.
            if let priceText, !priceText.isEmpty { attachmentPrices[composer] = priceText }
            if replyTargets[composer] == nil { replyTargets[composer] = reply }
        }
        return outcome.textSent
    }

    /// The composer a reply to `message` belongs in: the open thread's if
    /// the message is in it, else its chat's.
    public func composer(for message: Message) -> ComposerID {
        if let open = openThread, open.chat == message.chat, message.threadRoot == open.uuid {
            return .thread(open)
        }
        return .chat(message.chat)
    }

    /// Files into the tray; one over the send limit is refused here, with
    /// the reason in the conversation, rather than after its upload fails.
    public func addFiles(_ urls: [URL], to composer: ComposerID) {
        var refused: [String] = []
        let files = urls.filter { file in
            guard file.isFileURL else { return false }
            do {
                try Engine.checkSendable(file)
                return true
            } catch {
                refused.append(PeelError.noted(error))
                IncomingFiles.discard(file)
                return false
            }
        }
        if !refused.isEmpty, let chat = composer.chat {
            conversationNotices[chat] = PeelError.problem(refused.joined(separator: " "), couldNot: "attach")
        }
        guard !files.isEmpty else { return }
        pendingFiles[composer, default: []].append(contentsOf: files)
        composerFocus[composer, default: 0] += 1
    }

    /// Shows or clears the drop overlay over `composer`'s conversation.
    public func dropTargeted(_ targeted: Bool, composer: ComposerID) {
        if targeted { dropTarget = composer } else if dropTarget == composer { dropTarget = nil }
    }

    public func removeFile(_ url: URL, from composer: ComposerID) {
        pendingFiles[composer]?.removeAll { $0 == url }
        modelSight.drop(url, from: composer)
        release(url)
    }

    /// Removes a pasted or promised file of Peel's, and any preview of a sent
    /// row still pointing at it; any other file is left alone.
    private func release(_ file: URL) {
        guard IncomingFiles.owns(file) else { return }
        for handle in attachmentHandles.values where handle.localFile == file { handle.localFile = nil }
        IncomingFiles.discard(file)
    }

    /// Picks files to attach, beside the window.
    public func chooseFiles(for composer: ComposerID) {
        addFiles(platform.files.open(prompt: "Attach", multiple: true, directories: false, types: []) ?? [], to: composer)
    }

    // MARK: Attachments

    public func attachment(_ id: Int64) -> AttachmentHandle {
        if let handle = attachmentHandles[id] { return handle }
        let handle = AttachmentHandle()
        attachmentHandles[id] = handle
        return handle
    }

    /// Downloads an attachment into the cache, or finds it there, once at a
    /// time. Ours still uploading has nothing on the server yet. With
    /// `upTo`, one larger is held (`.held`) until asked for without it.
    /// A failure that may pass (`MediaFetch.isTransient`) leaves it
    /// `.retrying` and schedules up to three more tries, 2, 10 and 30 seconds
    /// apart (`MediaFetch.retryDelay`); a call that is not `automatic` (a tap,
    /// Save, Play) starts the budget over.
    public func download(_ message: Message, upTo: Int? = nil, cachedOnly: Bool = false, automatic: Bool = false) async {
        guard let id = message.id, let engine, message.uploadState != .pending, message.uploadState != .failed
        else { return }
        let handle = attachment(id)
        if !automatic { handle.attempts = 0 }
        // One download per attachment; a second caller waits for it, so it
        // can read the file once this returns (or, held back by a limit this
        // call does not have, fetch it whole).
        while let running = handle.download { _ = await running.value }
        switch handle.state {
        case .ready: return
        case .held where upTo != nil: return
        // A retry is already scheduled: the tile showing again must not start a second.
        case .retrying where automatic && handle.retry != nil: return
        case .idle, .downloading, .held, .failed, .retrying: break
        }
        handle.retry?.cancel()
        handle.retry = nil
        handle.state = .downloading
        // Time to finish if the app leaves the front mid-transfer (the iPhone's grace period).
        let work = platform.backgroundWork
        let background = work.begin(name: "Attachment download", onExpire: {})
        // Owned by the model, not the view that asked: a lazy row is made and
        // dropped as the list lays out, and its task's cancellation would cut
        // the download off (as it once did photos, see `ImageCache`).
        let download = Task {
            do {
                handle.state = .ready(try await engine.downloadAttachment(messageID: id, upTo: upTo, cachedOnly: cachedOnly))
            } catch Engine.Failure.notDownloaded {
                handle.state = .idle
            } catch Engine.Failure.largeAttachment(let size) {
                handle.state = .held(size)
            } catch Engine.Failure.attachmentWithoutKey where automatic {
                // A paid one not bought yet: nothing wrong with it, nothing to fetch.
                handle.state = .idle
            } catch {
                let reason = PeelError.noted(error, couldNot: "download")
                if MediaFetch.isTransient(error) {
                    handle.attempts += 1
                    handle.state = .retrying(reason: reason, attempt: handle.attempts)
                    self.scheduleRetry(of: message, userAsked: !automatic, handle)
                } else {
                    handle.state = .failed(reason)
                }
            }
            handle.progress = nil
            handle.download = nil
            work.end(background)
        }
        handle.download = download
        await download.value
    }

    /// Tries `message` again after the next delay of the schedule, if any is
    /// left; the model's task, so it outlives the view.
    private func scheduleRetry(of message: Message, userAsked: Bool, _ handle: AttachmentHandle) {
        handle.retrying = (message, userAsked)
        guard let delay = MediaFetch.retryDelay(attempt: handle.attempts) else { return }
        handle.retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            handle.retry = nil
            await self.fetch(message, userAsked: userAsked)
        }
    }

    /// A tap's fetch, or an automatic one that applies the setting and the limits again.
    private func fetch(_ message: Message, userAsked: Bool) async {
        if userAsked {
            await download(message, automatic: true)
        } else {
            await autoDownload(message)
        }
    }

    /// Tries every attachment that failed in a way that may pass once more,
    /// with a fresh budget: as the app returns to the front and when the
    /// connection comes back. One that failed for good stays failed.
    public func retryPendingMedia() {
        for handle in attachmentHandles.values {
            guard handle.isRetrying, handle.download == nil, let pending = handle.retrying else { continue }
            handle.retry?.cancel()
            handle.retry = nil
            handle.attempts = 0
            Task { await self.fetch(pending.message, userAsked: pending.userAsked) }
        }
    }

    /// A received attachment, as it arrives: fetched through `autoDownload`
    /// (the setting and the limits) without waiting for its tile to show.
    /// Not a paid one (nothing of it is fetched until bought).
    func autoDownloadReceived(_ message: Message) {
        guard !message.fromMe, !message.deleted, message.type == MessageType.attachment, message.id != nil,
              message.attachmentPriceMsat == nil else { return }
        Task { await self.autoDownload(message) }
    }

    /// Lets the person pick where the file goes, then copies it there
    /// (Save as…). Quarantined; nothing is opened.
    public func save(_ message: Message) async {
        await download(message)
        guard let id = message.id, let file = attachment(id).file,
              let target = platform.files.saveLocation(named: fileName(of: message) ?? file.lastPathComponent) else { return }
        do {
            try await Task.detached { try UserFiles.copy(file, to: target, replacing: true) }.value
        } catch {
            conversationNotices[message.chat] = PeelError.noted(error, couldNot: "save the file")
        }
    }

    /// The one click on a file: downloads and decrypts it, then puts it in
    /// Downloads (as "name (1).ext" when the name is taken), quarantined.
    /// Nothing is opened; the card then offers Show in Finder.
    public func saveToDownloads(_ message: Message) async {
        await download(message)
        guard let id = message.id, let file = attachment(id).file else { return }
        do {
            attachment(id).savedTo = try await UserFiles.saveToDownloads(file, named: fileName(of: message) ?? file.lastPathComponent)
        } catch {
            conversationNotices[message.chat] = PeelError.noted(error, couldNot: "save to Downloads")
        }
    }

    /// Shows a saved file in the Finder, selected. Never opens it.
    public func showInFinder(_ file: URL) {
        platform.files.reveal(file)
    }

    private func fileName(of message: Message) -> String? {
        message.id.flatMap { attachment($0).downloaded?.fileName } ?? message.fileName
    }

    /// Whether a file attachment opens as a page in the web pane: HTML.
    public func opensAsPage(_ message: Message) -> Bool {
        WebPage.isHTML(fileName: fileName(of: message), mediaType: message.mediaType)
    }

    /// Downloads and decrypts an HTML attachment, then shows it in the web
    /// pane like a clicked link, offline and without script
    /// (`WebPane.openDocument`).
    public func openPage(_ message: Message) async {
        await download(message)
        guard let id = message.id, let file = attachment(id).file, opensAsPage(message) else { return }
        do {
            try await webPresenter.openDocument(file, named: fileName(of: message) ?? "Page")
        } catch {
            conversationNotices[message.chat] = PeelError.noted(error, couldNot: "open the page")
        }
    }

    /// What an attachment is: what its bytes turned out to be once
    /// downloaded (a fake video is a file), else what it says.
    public func attachmentKind(of message: Message) -> AttachmentKind? {
        message.id.flatMap { attachment($0).downloaded?.kind } ?? message.attachmentKind
    }

    /// Downloads an attachment as it shows, as `AutoDownloadPolicy` decides:
    /// images up to `Engine.autoDownloadImageLimit`, videos and recordings
    /// up to `Engine.autoDownloadLimit`, larger ones held for a tap, files
    /// never. With Auto download media off it only finds what is already in
    /// the cache; anything else waits for `awaitsManualDownload`'s button.
    public func autoDownload(_ message: Message) async {
        let kind = message.attachmentKind
        switch AutoDownloadPolicy.decide(kind: kind, size: message.fileSize, setting: autoDownloadsMedia) {
        case .fetchNow(let limit):
            await download(message, upTo: limit, automatic: true)
        case .cachedOnly:
            await download(message, cachedOnly: true, automatic: true)
        case .hold:
            // The engine holds it by its declared size, after looking in the cache.
            await download(message, upTo: AutoDownloadPolicy.limit(for: kind), automatic: true)
        }
    }

    /// Whether an image, video or recording is not here and will not be
    /// fetched unasked (Auto download media is off): its tile shows a button.
    public func awaitsManualDownload(_ message: Message) -> Bool {
        guard !autoDownloadsMedia, AutoDownloadPolicy.limit(for: message.attachmentKind) != nil,
              let id = message.id else { return false }
        let handle = attachment(id)
        guard handle.file == nil else { return false }
        switch handle.state {
        case .idle, .failed: return true
        case .downloading, .ready, .held, .retrying: return false
        }
    }

    /// Plays a video or recording, downloading it first if it was held
    /// (the click asked for it).
    public func play(_ message: Message) async {
        await download(message)
        guard let id = message.id, let file = attachment(id).file,
              attachmentKind(of: message) == message.attachmentKind else { return }
        platform.playback.play(id, file: file)
    }

    /// Puts an image on the clipboard; false when it is not downloaded or cannot be read.
    public func copyImage(_ message: Message) -> Bool {
        guard let id = message.id, let file = attachment(id).file else { return false }
        return platform.pasteboard.copyImage(at: file)
    }

    public func showImages(_ messages: [Message], at index: Int) {
        guard messages.indices.contains(index) else { return }
        viewer = ImageViewerState(messages: messages, index: index)
    }

    /// The previous (-1) or next (1) image in the viewer, if there is one.
    public func stepViewer(_ by: Int) {
        guard let viewer, viewer.messages.indices.contains(viewer.index + by) else { return }
        self.viewer?.index += by
    }
}
