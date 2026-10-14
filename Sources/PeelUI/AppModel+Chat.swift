import Foundation
import Observation
import PeelCore

/// A thread, by its chat and its original's uuid.
public struct ThreadRef: Hashable, Sendable {
    public let chat: String
    public let uuid: String

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

/// Which composer: a chat's own, a thread panel's, or the agent chat's.
public enum ComposerID: Hashable, Sendable {
    case chat(String)
    case thread(ThreadRef)
    /// The agent chat's: text only, to the agent (`AppModel.sendDraft`).
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

    public func transfer(bytes: Int64, total: Int64) {
        progress = bytes < total ? (bytes, total) : nil
    }

    public var file: URL? {
        if case .ready(let downloaded) = state { downloaded.file } else { localFile }
    }

    public var downloaded: DownloadedAttachment? {
        if case .ready(let downloaded) = state { downloaded } else { nil }
    }

    /// Why its download failed, when it did.
    public var failureReason: String? {
        if case .failed(let reason) = state { reason } else { nil }
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

    /// Escape in a composer: stops replying, else closes its thread panel.
    /// Returns whether it was taken.
    public func escape(in composer: ComposerID) -> Bool {
        if composer == .agent, agentHost?.closeMemory(in: self) == true { return true }
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
            conversationNotices[pubkey] = PeelError.problem(error, couldNot: (exit ?? .leave).failure)
        }
    }

    /// Threads with replies past their chat's read marker.
    public var unreadThreads: Int { threads.filter { $0.unread > 0 }.count }

    /// Marks a chat read up to its newest message; thread unread clears with it.
    public func markRead(_ chat: String) async {
        await attempt("mark as read", in: chat) { try await $0.markRead(chat) }
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
        if composer == .agent {
            agent?.send(text)
            return
        }
        if await !send(text, from: composer), (drafts[composer] ?? "").isEmpty, !text.isEmpty {
            drafts[composer] = text
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
        let files = pendingFiles[composer] ?? []
        let priceText = attachmentPrices[composer]
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
                try await engine.sendText(text, to: chat, replyTo: replyTo, inThread: inThread)
                sent(in: chat)
                return true
            } catch {
                conversationNotices[chat] = PeelError.problem(error, couldNot: "send")
                replyTargets[composer] = reply
                return false
            }
        }
        let outcome = await engine.sendAttachments(
            files, text: text, to: chat, replyTo: replyTo, inThread: inThread, priceSats: priceSats
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
                refused.append((file, PeelError.problem(error, couldNot: "send \(file.lastPathComponent)")))
            }
        }
        if !refused.isEmpty {
            conversationNotices[chat] = refused.map(\.reason).joined(separator: " ")
            // What did not go waits in the composer again, with the reply it was for.
            pendingFiles[composer, default: []].insert(contentsOf: refused.map(\.file), at: 0)
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

    public func addFiles(_ urls: [URL], to composer: ComposerID) {
        let files = urls.filter(\.isFileURL)
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
    public func download(_ message: Message, upTo: Int? = nil) async {
        guard let id = message.id, let engine, message.uploadState != .pending, message.uploadState != .failed
        else { return }
        let handle = attachment(id)
        // One download per attachment; a second caller waits for it, so it
        // can read the file once this returns (or, held back by a limit this
        // call does not have, fetch it whole).
        while let running = handle.download { _ = await running.value }
        switch handle.state {
        case .ready: return
        case .held where upTo != nil: return
        case .idle, .downloading, .held, .failed: break
        }
        handle.state = .downloading
        // Owned by the model, not the view that asked: a lazy row is made and
        // dropped as the list lays out, and its task's cancellation would cut
        // the download off (as it once did photos, see `ImageCache`).
        let download = Task {
            do {
                handle.state = .ready(try await engine.downloadAttachment(messageID: id, upTo: upTo))
            } catch Engine.Failure.largeAttachment(let size) {
                handle.state = .held(size)
            } catch {
                handle.state = .failed(PeelError.problem(error, couldNot: "download"))
            }
            handle.progress = nil
            handle.download = nil
        }
        handle.download = download
        await download.value
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
            conversationNotices[message.chat] = PeelError.problem(error, couldNot: "save the file")
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
            conversationNotices[message.chat] = PeelError.problem(error, couldNot: "save to Downloads")
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
            conversationNotices[message.chat] = PeelError.problem(error, couldNot: "open the page")
        }
    }

    /// What an attachment is: what its bytes turned out to be once
    /// downloaded (a fake video is a file), else what it says.
    public func attachmentKind(of message: Message) -> AttachmentKind? {
        message.id.flatMap { attachment($0).downloaded?.kind } ?? message.attachmentKind
    }

    /// Downloads an attachment as it shows: images whole, videos and
    /// recordings up to `Engine.autoDownloadLimit` (larger ones are held).
    public func autoDownload(_ message: Message) async {
        let media = message.attachmentKind == .video || message.attachmentKind == .audio
        await download(message, upTo: media ? Engine.autoDownloadLimit : nil)
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
