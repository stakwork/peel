import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
import PeelCore

/// A thread, by its chat and its original's uuid.
struct ThreadRef: Hashable {
    let chat: String
    let uuid: String
}

/// A message to bring into view; see `AppModel.focus(on:)`.
struct FocusTarget: Equatable {
    let message: Message
    let inThread: Bool
}

/// Which composer: a chat's own, or a thread panel's.
enum ComposerID: Hashable {
    case chat(String)
    case thread(ThreadRef)

    var chat: String {
        switch self {
        case .chat(let chat): chat
        case .thread(let thread): thread.chat
        }
    }

    var thread: String? {
        if case .thread(let thread) = self { thread.uuid } else { nil }
    }
}

/// The image viewer: one sender's images in a run, and which one shows.
struct ImageViewerState: Equatable {
    var messages: [Message]
    var index: Int

    var current: Message { messages[min(index, messages.count - 1)] }
}

/// One attachment's download, upload progress and local copy. Observed on
/// its own so a progress tick redraws only the tile that shows it.
@MainActor @Observable
final class AttachmentHandle {
    enum State {
        case idle
        case downloading
        case ready(DownloadedAttachment)
        case failed(String)
    }

    var state: State = .idle
    /// Bytes so far of the total, while an upload or download runs.
    var progress: (bytes: Int64, total: Int64)?
    /// For one of ours still uploading: the file picked on this Mac.
    var localFile: URL?
    /// Where its file was saved in Downloads, once it was.
    var savedTo: URL?
    /// The download running now, for others asking meanwhile to wait on.
    @ObservationIgnored var download: Task<Void, Never>?

    func transfer(bytes: Int64, total: Int64) {
        progress = bytes < total ? (bytes, total) : nil
    }

    var file: URL? {
        if case .ready(let downloaded) = state { downloaded.file } else { localFile }
    }

    var downloaded: DownloadedAttachment? {
        if case .ready(let downloaded) = state { downloaded } else { nil }
    }
}

extension AppModel {
    // MARK: Replies and threads

    /// Replies to a message from the composer it was chosen in.
    func reply(to message: Message, in composer: ComposerID) {
        replyTargets[composer] = message
        composerFocus[composer, default: 0] += 1
    }

    func cancelReply(in composer: ComposerID) {
        replyTargets[composer] = nil
    }

    /// Escape in a composer: stops replying, else closes its thread panel.
    /// Returns whether it was taken.
    func escape(in composer: ComposerID) -> Bool {
        if replyTargets[composer] != nil {
            replyTargets[composer] = nil
            return true
        }
        guard composer.thread != nil else { return false }
        closeThread()
        return true
    }

    /// Who sent a message, as lists, quotes and the viewer name them: you,
    /// the member in a tribe, else the contact. `avatarName` picks the
    /// initials when there is no photo; `hue` is their colour.
    func sender(of message: Message) -> (name: String, avatarName: String, photoURL: String?, hue: PersonHue) {
        if message.fromMe { return ("You", myAlias ?? "?", myPhotoURL, myHue) }
        let conversation = conversations.first { $0.chat == message.chat }
        if conversation?.isTribe ?? false {
            let details = message.senderDetails
            return (details.alias ?? "Someone", details.alias ?? "?", details.photoURL,
                    hue(pubkey: message.chat, alias: details.alias, inTribe: true))
        }
        let name = conversation?.name ?? "Someone"
        return (name, name, conversation?.photoURL, hue(pubkey: message.chat, alias: nil, inTribe: false))
    }

    /// Whether Delete is offered: the engine's rule (`Message.isDeletable`),
    /// with the thread's size read when the menu opens.
    func canDelete(_ message: Message, inTribe: Bool) -> Bool {
        guard let uuid = message.uuid, let storage = engine?.storage else { return false }
        let owns = selectedTribe.map { $0.pubkey == message.chat && $0.canManage } ?? false
        let count = (try? storage.threadCount(uuid, in: message.chat)) ?? 0
        return message.isDeletable(inTribe: inTribe, ownsTribe: owns, threadCount: count)
    }

    /// The one Reply: inline, under the conversation or in the open thread,
    /// except for a message folded into a collapsed tribe thread (not its
    /// own row in the chat), which is answered in that thread's panel.
    /// Either way the engine sends the same links: a reply joins or starts
    /// the parent's thread, as in the official apps.
    func startReply(to message: Message, from composer: ComposerID) {
        if case .chat = composer, message.chat == selectedChat, timeline.threads[message.threadRoot] != nil {
            let thread = ThreadRef(chat: message.chat, uuid: message.threadRoot)
            openThread(thread)
            reply(to: message, in: .thread(thread))
        } else {
            reply(to: message, in: composer)
        }
    }

    /// Opens the thread a message is in, or the one it would start.
    func openThread(of message: Message) {
        let root = message.threadRoot
        guard !root.isEmpty else { return }
        openThread(ThreadRef(chat: message.chat, uuid: root))
    }

    /// Opens a thread from anywhere (the Threads list), in its chat.
    func openThread(_ thread: ThreadRef) {
        if selectedChat != thread.chat { destination = .chat(thread.chat) }
        openThread = thread
        composerFocus[.thread(thread), default: 0] += 1
    }

    /// From the Threads list: the thread, at its first new reply when it has some.
    func openThread(_ summary: ThreadSummary) {
        let marker = readStates[summary.chat]?.lastRead ?? -1
        if summary.unread > 0,
           let first = try? engine?.storage.firstUnreadReply(inThread: summary.uuid, in: summary.chat, after: marker) {
            focus(on: first, inThread: true)
        } else {
            openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid))
        }
    }

    func closeThread() {
        if let openThread { replyTargets[.thread(openThread)] = nil }
        openThread = nil
    }

    /// A joined tribe's record, for a menu opened on its row: the open one
    /// as observed, any other read once.
    func tribe(_ pubkey: String) -> Tribe? {
        if let selectedTribe, selectedTribe.pubkey == pubkey { return selectedTribe }
        return (try? engine?.storage.tribes())?.first { $0.pubkey == pubkey }
    }

    /// Leaves a tribe, or removes one this account can no longer post in;
    /// a failure shows in that chat.
    func leave(_ pubkey: String) async {
        do {
            try await leaveTribe(pubkey)
        } catch {
            conversationNotices[pubkey] = "Could not leave: \(PeelError.readable(error))"
        }
    }

    /// Threads with replies past their chat's read marker.
    var unreadThreads: Int { threads.filter { $0.unread > 0 }.count }

    /// Marks a chat read up to its newest message; thread unread clears with it.
    func markRead(_ chat: String) async {
        await attempt("mark as read", in: chat) { try await $0.markRead(chat) }
    }

    func markAllThreadsRead() async {
        for chat in Set(threads.filter { $0.unread > 0 }.map(\.chat)) {
            await markRead(chat)
        }
    }

    // MARK: Sending

    /// Who `@` offers in a tribe's composers.
    func mentionLoader(_ chat: String) -> @MainActor @Sendable () async -> [TribeMember] {
        { [weak self] in await self?.mentionCandidates(in: chat) ?? [] }
    }

    /// Sends a composer's draft and files; if nothing went, the text comes
    /// back unless something new was typed meanwhile.
    func sendDraft(from composer: ComposerID) async {
        let text = (drafts[composer] ?? "").trimmed
        drafts[composer] = nil
        if await !send(text, from: composer), (drafts[composer] ?? "").isEmpty, !text.isEmpty {
            drafts[composer] = text
        }
    }

    /// Sends what a composer holds: its files, one message each, with the
    /// text as the last one's caption (or on its own), all with the reply
    /// and thread links the composer was set to. Returns whether the text
    /// went (true when there was none); refused files go back in the tray
    /// with the reply target. Files go one after another, each once its
    /// upload is done, so they arrive in order.
    @discardableResult
    func send(_ text: String, from composer: ComposerID) async -> Bool {
        guard let engine else { return false }
        let chat = composer.chat
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
                conversationNotices[chat] = "Could not send: \(PeelError.readable(error))"
                replyTargets[composer] = reply
                return false
            }
        }
        var refused: [(file: URL, reason: String)] = []
        var captionSent = text.isEmpty
        for (index, file) in files.enumerated() {
            let caption = index == files.count - 1 ? text : ""
            do {
                // Shown from this Mac while it uploads.
                let id = try await engine.sendAttachment(
                    file, text: caption, to: chat, replyTo: replyTo, inThread: inThread, priceSats: priceSats
                ) {
                    [weak self] id in Task { @MainActor in self?.attachment(id).localFile = file }
                }
                // A pasted or promised file of Peel's is done with once
                // uploaded: the engine keeps its own copy in the cache. One
                // whose upload failed stays as the row's preview until the
                // account closes.
                if IncomingFiles.owns(file), (try? engine.storage.message(id: id))?.uploadState == .done {
                    release(file)
                }
                if !caption.isEmpty { captionSent = true }
                sent(in: chat)
            } catch {
                refused.append((file, "\(file.lastPathComponent): \(PeelError.readable(error))"))
            }
        }
        // The file the caption rode on was refused: the words still go.
        if !captionSent, (try? await engine.sendText(text, to: chat, replyTo: replyTo, inThread: inThread)) != nil {
            captionSent = true
        }
        if !refused.isEmpty {
            conversationNotices[chat] = "Could not send " + refused.map(\.reason).joined(separator: "; ")
            // What did not go waits in the composer again, with the reply it was for.
            pendingFiles[composer, default: []].insert(contentsOf: refused.map(\.file), at: 0)
            // With their price: a refused paid file must never go again free.
            if let priceText, !priceText.isEmpty { attachmentPrices[composer] = priceText }
            if replyTargets[composer] == nil { replyTargets[composer] = reply }
        }
        return captionSent
    }

    /// The composer a reply to `message` belongs in: the open thread's if
    /// the message is in it, else its chat's.
    func composer(for message: Message) -> ComposerID {
        if let open = openThread, open.chat == message.chat, message.threadRoot == open.uuid {
            return .thread(open)
        }
        return .chat(message.chat)
    }

    func addFiles(_ urls: [URL], to composer: ComposerID) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        pendingFiles[composer, default: []].append(contentsOf: files)
        composerFocus[composer, default: 0] += 1
    }

    #if os(macOS)
    /// Files dropped or pasted, into the tray in their order; what could not
    /// be had is said in the conversation.
    func attach(_ items: [PasteboardFiles.Item], to composer: ComposerID) {
        let account = engine
        Task {
            let (files, refused) = await PasteboardFiles.files(from: items)
            // The account closed or changed while they were written.
            guard let account, account === engine else {
                files.forEach { IncomingFiles.discard($0) }
                return
            }
            addFiles(files, to: composer)
            if !refused.isEmpty {
                conversationNotices[composer.chat] = "Could not attach: " + refused.joined(separator: "; ")
            }
        }
    }

    /// Shows or clears the drop overlay over `composer`'s conversation.
    func dropTargeted(_ targeted: Bool, composer: ComposerID) {
        if targeted { dropTarget = composer } else if dropTarget == composer { dropTarget = nil }
    }
    #endif

    func removeFile(_ url: URL, from composer: ComposerID) {
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
    func chooseFiles(for composer: ComposerID) {
        addFiles(Self.chooseFiles(prompt: "Attach", multiple: true), to: composer)
    }

    /// Files picked in an open panel beside the window, of the given types if any.
    static func chooseFiles(prompt: String, multiple: Bool, types: [UTType] = []) -> [URL] {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
        #else
        return []
        #endif
    }

    // MARK: Attachments

    func attachment(_ id: Int64) -> AttachmentHandle {
        if let handle = attachmentHandles[id] { return handle }
        let handle = AttachmentHandle()
        attachmentHandles[id] = handle
        return handle
    }

    /// Downloads an attachment into the cache, or finds it there, once at a
    /// time. Ours still uploading has nothing on the server yet.
    func download(_ message: Message) async {
        guard let id = message.id, let engine, message.uploadState != .pending, message.uploadState != .failed
        else { return }
        let handle = attachment(id)
        if case .ready = handle.state { return }
        // One download per attachment; a second caller waits for it, so it
        // can read the file once this returns.
        if let running = handle.download {
            _ = await running.value
            return
        }
        handle.state = .downloading
        // Owned by the model, not the view that asked: a lazy row is made and
        // dropped as the list lays out, and its task's cancellation would cut
        // the download off (as it once did photos, see `PhotoCache`).
        let download = Task {
            do {
                handle.state = .ready(try await engine.downloadAttachment(messageID: id))
            } catch {
                handle.state = .failed(PeelError.readable(error))
            }
            handle.progress = nil
            handle.download = nil
        }
        handle.download = download
        await download.value
    }

    /// Lets the person pick where the file goes, then copies it there
    /// (Save as…). Quarantined; nothing is opened.
    func save(_ message: Message) async {
        await download(message)
        #if os(macOS)
        guard let id = message.id, let file = attachment(id).file else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(of: message) ?? file.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try await Task.detached { try UserFiles.copy(file, to: target, replacing: true) }.value
        } catch {
            conversationNotices[message.chat] = "Could not save: \(PeelError.readable(error))"
        }
        #endif
    }

    /// The one click on a file: downloads and decrypts it, then puts it in
    /// Downloads (as "name (1).ext" when the name is taken), quarantined.
    /// Nothing is opened; the card then offers Show in Finder.
    func saveToDownloads(_ message: Message) async {
        await download(message)
        guard let id = message.id, let file = attachment(id).file,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let name = fileName(of: message) ?? file.lastPathComponent
        do {
            attachment(id).savedTo = try await Task.detached { try UserFiles.save(file, named: name, in: downloads) }.value
        } catch {
            conversationNotices[message.chat] = "Could not save to Downloads: \(PeelError.readable(error))"
        }
    }

    /// Shows a saved file in the Finder, selected. Never opens it.
    func showInFinder(_ file: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        #endif
    }

    private func fileName(of message: Message) -> String? {
        message.id.flatMap { attachment($0).downloaded?.fileName } ?? message.fileName
    }

    /// Puts an image on the clipboard; false when it is not downloaded or cannot be read.
    func copyImage(_ message: Message) -> Bool {
        guard let id = message.id, let file = attachment(id).file else { return false }
        return Clipboard.copyImage(at: file)
    }

    func showImages(_ messages: [Message], at index: Int) {
        guard messages.indices.contains(index) else { return }
        viewer = ImageViewerState(messages: messages, index: index)
    }

    /// The previous (-1) or next (1) image in the viewer, if there is one.
    func stepViewer(_ by: Int) {
        guard let viewer, viewer.messages.indices.contains(viewer.index + by) else { return }
        self.viewer?.index += by
    }
}

/// Images decoded off the main thread at the size they are drawn, kept
/// while memory allows.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 200 * 1024 * 1024
        return cache
    }()

    /// Decodes running now, so rows made and dropped while scrolling share one.
    private var decoding: [NSString: Task<CGImage?, Never>] = [:]

    /// Already decoded, to draw a row that scrolls back without a blank frame.
    func cached(_ file: URL?, maxPixels: Int) -> CGImage? {
        file.flatMap { cache.object(forKey: Self.key($0, maxPixels)) }
    }

    /// The image at `file`, at most `maxPixels` on its long side, upright.
    func image(_ file: URL, maxPixels: Int) async -> CGImage? {
        let key = Self.key(file, maxPixels)
        if let image = cache.object(forKey: key) { return image }
        let decode = decoding[key] ?? Task.detached(priority: .userInitiated) {
            ImageDecoding.thumbnail(file, maxPixels: maxPixels)
        }
        decoding[key] = decode
        let image = await decode.value
        decoding[key] = nil
        if let image { cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    private static func key(_ file: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(file.path)" as NSString }
}
