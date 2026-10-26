#if os(macOS)
import AppKit
import os
import PeelCore
import PeelUI
import UniformTypeIdentifiers

/// Files for a composer from a pasteboard: a drag's (onto a conversation or
/// its field) or the clipboard's (Paste in the field). Files from Finder go
/// as they are; image bytes and promised files (the screenshot thumbnail)
/// are written to Peel's own folder first (`IncomingFiles`).
enum PasteboardFiles {
    enum Item: Sendable {
        case file(URL)
        case image(Data, UTType)
        /// The files a source is writing, as it writes them.
        case promised(AsyncStream<Result<URL, any Error>>)
    }

    private static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes

    /// What a conversation is offered a drop of; `hasFiles` decides.
    static let dropTypes: [UTType] = [.fileURL, .image] + promiseTypes.compactMap(UTType.init)

    /// Whether anything on `pasteboard` would go in the tray.
    static func hasFiles(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.pasteboardItems ?? []).contains { source(of: $0, promised: isPromise($0)) != nil }
    }

    private static func isPromise(_ item: NSPasteboardItem) -> Bool {
        item.types.contains { promiseTypes.contains($0.rawValue) }
    }

    /// The item's text is read only when an image of it could give way to it.
    private static func source(of item: NSPasteboardItem, promised: Bool) -> IncomingFiles.Source? {
        IncomingFiles.source(
            types: item.types.map(\.rawValue), promised: promised, plainText: item.string(forType: .string)
        )
    }

    /// What `pasteboard` holds for the tray, in its order. Read at once: a
    /// drag's pasteboard is gone after the drop, and a promise is asked for
    /// at once too (`promises`, drags only), while its source still waits.
    static func items(on pasteboard: NSPasteboard, promises: Bool) -> [Item] {
        let receivers = promises
            ? pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? [] : []
        // One receiver for each item that carries a promise, in order.
        var nextReceiver = receivers.makeIterator()
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            let receiver = isPromise(item) ? nextReceiver.next() : nil
            switch source(of: item, promised: receiver != nil) {
            case .file:
                // Finder may write a file reference URL; this resolves it to a path.
                let url = item.string(forType: .fileURL).flatMap { NSURL(string: $0)?.filePathURL }
                return url.map(Item.file)
            case .promise:
                return receiver.map(receive)
            case .image(let type):
                return item.data(forType: NSPasteboard.PasteboardType(type.identifier)).map { .image($0, type) }
            case nil:
                return nil
            }
        }
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// How long a source may take to write what it promised.
    private static let promiseTimeout: Duration = .seconds(120)

    /// Asks the source to write its files into a new folder of Peel's,
    /// each checked by `IncomingFiles.accept` as it arrives. A source that
    /// never writes them all is given up on after `promiseTimeout`.
    private static func receive(_ receiver: NSFilePromiseReceiver) -> Item {
        let (stream, continuation) = AsyncStream<Result<URL, any Error>>.makeStream()
        let folder: URL
        do {
            folder = try IncomingFiles.newFolder()
        } catch {
            continuation.yield(.failure(error))
            continuation.finish()
            return .promised(stream)
        }
        let expected = max(receiver.fileTypes.count, 1)
        let counts = OSAllocatedUnfairLock(initialState: (received: 0, accepted: 0))
        // Held until the source is done, whatever AppKit keeps.
        nonisolated(unsafe) let receiver = receiver
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { file, error in
            withExtendedLifetime(receiver) {}
            let result = Result {
                if let error { throw error }
                return try IncomingFiles.accept(file, in: folder)
            }
            continuation.yield(result)
            let (received, accepted) = counts.withLock {
                $0.received += 1
                if case .success = result { $0.accepted += 1 }
                return $0
            }
            guard received >= expected else { return }
            if accepted == 0 { try? FileManager.default.removeItem(at: folder) }
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(for: promiseTimeout)
            continuation.finish()
        }
        continuation.onTermination = { _ in timeout.cancel() }
        return .promised(stream)
    }

    /// The files for the tray, in order, and why any could not be had.
    static func files(from items: [Item]) async -> (files: [URL], refused: [String]) {
        var files: [URL] = [], refused: [String] = []
        var images = 0
        let date = Date()
        for item in items {
            switch item {
            case .file(let url):
                files.append(url)
            case .image(let data, let type):
                let index = images
                images += 1
                do {
                    files.append(try await Task.detached {
                        try IncomingFiles.write(data, type: type, index: index, date: date)
                    }.value)
                } catch {
                    refused.append(PeelError.problem(error))
                }
            case .promised(let stream):
                for await result in stream {
                    switch result {
                    case .success(let file): files.append(file)
                    case .failure(let error): refused.append(PeelError.problem(error))
                    }
                }
            }
        }
        return (files, refused)
    }
}

extension AppModel {
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
            if !refused.isEmpty, let chat = composer.chat {
                // The kind only: the refusals name files.
                Diagnostics.note(errorKind: .refused)
                conversationNotices[chat] = PeelError.problem(refused.joined(separator: " "), couldNot: "attach")
            }
        }
    }
}
#endif
