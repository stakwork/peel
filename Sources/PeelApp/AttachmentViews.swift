import SwiftUI
import UniformTypeIdentifiers
import PeelCore
import PeelUI

/// An attachment in a message: an image (or a grid of a run of them), a
/// video, a recording or a file card. Images download as soon as they
/// show, videos and recordings up to `Engine.autoDownloadLimit`; files
/// when asked. Nothing is ever opened outside Peel; an HTML file, when
/// clicked, shows offline in the web pane.
struct AttachmentView: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    /// Each tile's own menu, in a run of images.
    var tileMenu: (@MainActor (Message) -> [MenuEntry])?

    var body: some View {
        if let purchase = row.purchase, !row.message.fromMe, purchase != .unlocked {
            // Someone else's paid attachment: nothing of it is fetched until bought.
            LockedAttachment(row: row, state: purchase)
        } else if row.images.count > 1 {
            ImageGrid(images: row.images, tileMenu: tileMenu)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                // What the bytes turned out to be once downloaded: a fake video is a file.
                switch model.attachmentKind(of: row.message) {
                case .image: ImageTile(message: row.message, group: [row.message], index: 0, size: nil)
                case .video: VideoTile(message: row.message)
                case .audio: AudioCard(message: row.message)
                case .pdf, .text, .file, nil: FileCard(message: row.message)
                }
                if case .forSale(let purchases) = row.purchase, let price = row.message.attachmentPriceMsat {
                    ForSaleNote(priceMsat: price, purchases: purchases)
                }
            }
        }
    }
}

enum AttachmentFormat {
    /// Why a downloaded picture that did not decode is not drawn: "Too large
    /// to show" when it holds more pixels than are decoded
    /// (`ImageDecoding.isTooLarge`); nil otherwise. Read off the main actor.
    static func notShown(_ file: URL) async -> String? {
        await Task.detached(priority: .utility) { ImageDecoding.isTooLarge(file) ? "Too large to show" : nil }.value
    }

    /// "48 KB".
    static func size(_ bytes: Int64?) -> String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// "2.1 of 3.4 MB".
    static func progress(_ bytes: Int64, of total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let whole = formatter.string(fromByteCount: total)
        formatter.includesUnit = false
        return "\(formatter.string(fromByteCount: bytes)) of \(whole)"
    }

    /// What a file is, from its name: "PDF document", "Markdown".
    static func kind(_ name: String?) -> String? {
        let ext = ((name ?? "") as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }

    /// What a file says it is, before its name is known: "PDF document".
    static func kind(mediaType: String?) -> String? {
        mediaType.flatMap { UTType(mimeType: $0)?.localizedDescription }
    }

    /// A picture `width` by `height` pixels drawn at its own shape on a
    /// Retina screen: its long side at most `maxSide`, and small ones not tiny.
    static func fitted(width: CGFloat, height: CGFloat, maxSide: CGFloat) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: 240, height: 180) }
        let longest = max(width, height) / 2
        let scale = min(maxSide, max(longest, 160)) / longest
        return CGSize(width: width / 2 * scale, height: height / 2 * scale)
    }

    /// The short label on a file's icon: "PDF", "LOG"; from the declared
    /// type until a download gives the name.
    static func badge(_ name: String?, mediaType: String? = nil) -> String {
        var ext = ((name ?? "") as NSString).pathExtension
        if ext.isEmpty { ext = AttachmentKind.fileExtension(mediaType: mediaType) ?? "" }
        return ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
    }
}

/// Up to four of a run's images, the last with "+N" for the rest.
struct ImageGrid: View {
    let images: [Message]
    var tileMenu: (@MainActor (Message) -> [MenuEntry])?

    private static let tile: CGFloat = 148

    var body: some View {
        let shown = Array(images.prefix(4))
        // Up to 148 pt a tile, narrower in a narrow column (the thread panel).
        let columns = Array(repeating: GridItem(.flexible(minimum: 60, maximum: Self.tile), spacing: Theme.Space.xs), count: 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                ImageTile(message: message, group: images, index: index, size: Self.tile)
                    .peelMenu(source: "m\(message.id ?? 0)") { tileMenu?(message) ?? [] }
                    .overlay {
                        if index == 3, images.count > 4 {
                            ZStack {
                                Color.black.opacity(0.55)
                                Text("+\(images.count - 4)")
                                    .font(Theme.font(20, .bold))
                                    .foregroundStyle(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(maxWidth: Self.tile * 2 + 4, alignment: .leading)
    }
}

/// One image: drawn at its own shape up to 320 pt (or square in a grid),
/// decoded off the main thread at the size shown. Ours shows from this Mac
/// while it uploads, with the upload's progress over it.
struct ImageTile: View {
    @Environment(AppModel.self) private var model
    let message: Message
    /// The run it belongs to, for the viewer.
    let group: [Message]
    let index: Int
    /// A square side in a grid; nil for an image on its own.
    let size: CGFloat?

    @State private var loaded: CGImage?
    @State private var loadedFrames: AnimationFrames?
    /// Downloaded but not drawn, and why (`AttachmentFormat.notShown`).
    @State private var notShown: String?

    static let maxSide = ImageCache.tileSide

    /// Pixels for the size drawn on a Retina screen: a grid tile's side, or
    /// the largest an image on its own is drawn.
    private var pixels: Int { Int((size ?? Self.maxSide) * 2) }

    /// The image, from the cache straight away when a row scrolls back, so it
    /// is laid out once at its own shape.
    private var image: CGImage? {
        let file = model.attachment(message.id ?? 0).file
        return loaded ?? ImageCache.shared.cached(file, maxPixels: pixels) ?? decodedFrames?.frames.first
    }

    /// A GIF's frames once decoded: the first is its image.
    private var decodedFrames: AnimationFrames? {
        loadedFrames ?? ImageCache.animations.cached(animation: model.attachment(message.id ?? 0).file, maxPixels: pixels)
    }

    /// A GIF's frames, when it has more than one.
    private var frames: AnimationFrames? { decodedFrames.flatMap { $0.isAnimated ? $0 : nil } }

    /// Declared a GIF, as the Mac app tells one (`isGif`); Peel sends any
    /// animated picture as one.
    private var isGIF: Bool { message.mediaType?.lowercased().contains("gif") == true }

    var body: some View {
        let handle = model.attachment(message.id ?? 0)
        if let downloaded = handle.downloaded, downloaded.kind != .image {
            // It said it was an image and is not: a plain file, never drawn.
            FileCard(message: message)
        } else {
            Button {
                model.showImages(group, at: index)
            } label: {
                picture(handle)
            }
            .buttonStyle(.plain)
            .disabled(image == nil)
            .gifPlayback(animated: frames != nil)
            .autoDownload(message)
            .task(id: handle.file) {
                guard let file = handle.file else { return }
                // A GIF decodes once, every frame; anything else its first.
                if isGIF { loadedFrames = await ImageCache.animations.animation(file, maxPixels: pixels) }
                if loadedFrames == nil { loaded = await ImageCache.shared.image(file, maxPixels: pixels) }
                if loaded == nil, loadedFrames == nil { notShown = await AttachmentFormat.notShown(file) }
            }
        }
    }

    /// At its own shape, as large as `displaySize` but narrower when the
    /// column is (a thread panel, a narrow window): never past its edge.
    private func picture(_ handle: AttachmentHandle) -> some View {
        Group {
            if let frames {
                AnimatedPicture(animation: frames)
            } else if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Theme.quote.overlay {
                    if let notShown {
                        Label(notShown, systemImage: "photo")
                            .muted()
                    } else if handle.failureReason != nil {
                        Label("Image not available", systemImage: "photo")
                            .muted()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .attachmentTile(fitted: displaySize, message: message, handle: handle)
        .help(handle.failureReason ?? "")
        .accessibilityLabel(isGIF ? "GIF" : message.content?.trimmed.nilIfEmpty ?? "Image")
    }

    /// A GIF by its own size (its frames may be decoded smaller, or evicted
    /// and decoding again), anything else by its image.
    private var displaySize: CGSize {
        if let size { return CGSize(width: size, height: size) }
        let own = decodedFrames?.size ?? ImageCache.animations.size(of: model.attachment(message.id ?? 0).file)
            ?? CGSize(width: image?.width ?? 0, height: image?.height ?? 0)
        return AttachmentFormat.fitted(width: own.width, height: own.height, maxSide: Self.maxSide)
    }
}

/// A GIF from Giphy, loaded from Giphy's CDN as it shows (`Giphy.data`),
/// at the shape the message gives it, so the row keeps its size when the
/// GIF arrives.
struct GiphyTile: View {
    let giphy: Giphy

    @State private var loaded: AnimationFrames?
    @State private var failed = false

    /// The 200 px variant is never scaled up to this.
    static let maxPixels = ImageCache.tilePixels

    var body: some View {
        let animation = loaded ?? giphy.url.flatMap { ImageCache.animations.cached(giphy: $0) }
        Group {
            if let animation {
                AnimatedPicture(animation: animation)
            } else {
                Theme.quote.overlay {
                    if failed || giphy.url == nil {
                        Label("GIF not available", systemImage: "photo")
                            .muted()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .attachmentTile(fitted: size)
        // The caption is the row's text.
        .accessibilityLabel("GIF")
        .accessibilityAddTraits(.isImage)
        .gifPlayback(animated: animation?.isAnimated == true)
        .task(id: giphy.url) {
            guard let url = giphy.url, animation == nil else { return }
            loaded = await Self.load(url)
            failed = loaded == nil
        }
    }

    /// No answer, or Giphy busy: asked again while the row shows, then given up.
    private static func load(_ url: URL) async -> AnimationFrames? {
        let cache = ImageCache.animations
        for wait in [0, 5, 30] {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return nil }
            if let frames = await cache.animation(giphy: url) { return frames }
            if cache.isMissing(giphy: url) { return nil }
        }
        return nil
    }

    /// 240 pt wide, or 320 tall when it is taller than wide; a shape past
    /// 4:1 either way is drawn at 4:1.
    private var size: CGSize {
        let ratio = min(max(giphy.aspectRatio, 0.25), 4)
        return AttachmentFormat.fitted(width: 480, height: 480 / ratio, maxSide: ImageTile.maxSide)
    }
}

/// "Uploading · 2.1 of 3.4 MB" with a bar, from the engine's `.transfer` events.
struct TransferBar: View {
    let label: String
    let progress: (bytes: Int64, total: Int64)?

    var body: some View {
        let fraction = progress.map { $0.total > 0 ? Double($0.bytes) / Double($0.total) : 0 } ?? 0
        VStack(alignment: .leading, spacing: 5) {
            Text(progress.map { "\(label) · \(AttachmentFormat.progress($0.bytes, of: $0.total))" } ?? "\(label)…")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.divider)
                    Capsule().fill(Theme.accent).frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.input.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// A file: its type, name and size. One click downloads it into Downloads
/// ("name (1).ext" when taken) and offers Show in Finder; Save as… in its menu asks where.
/// An HTML file also opens in the web pane, on a click on the card or its
/// globe, like a link (`AppModel.openPage`).
struct FileCard: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let handle = model.attachment(message.id ?? 0)
        let name = handle.downloaded?.fileName ?? message.fileName
        HStack(spacing: Theme.Space.md) {
            AttachmentMark(message: message, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                // The name comes with the download; until then, what it says it is.
                Text(name ?? AttachmentFormat.kind(mediaType: message.mediaType) ?? "File")
                    .font(Theme.font(14, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([AttachmentFormat.size(handle.downloaded.map { Int64($0.size) } ?? message.fileSize),
                      AttachmentFormat.kind(name)].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
                    .muted()
                AttachmentStatus(message: message, handle: handle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            action(handle)
        }
        // The name truncates in the middle.
        .attachmentCard()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { if model.opensAsPage(message) { openPage() } }
    }

    private func openPage() {
        Task { await model.openPage(message) }
    }

    @ViewBuilder private func action(_ handle: AttachmentHandle) -> some View {
        if message.fromMe, message.uploadState == .failed {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.attention)
                .help("Not uploaded")
        } else if message.uploadState != .pending {
            switch handle.state {
            case .downloading:
                EmptyView()
            case .idle, .held, .failed, .ready:
                if model.opensAsPage(message) {
                    IconButton("globe", help: "Open in Peel", action: openPage)
                }
                if handle.savedTo == nil {
                    IconButton("arrow.down.to.line", help: "Download to Downloads") {
                        Task { await model.saveToDownloads(message) }
                    }
                }
            }
        }
    }
}

/// Under a file or recording: its upload or download with a bar, then
/// "Saved to Downloads", or why its download failed. A recording's play
/// button and line already show it waiting or failed, so for one the bar
/// waits for the first bytes and no reason shows.
struct AttachmentStatus: View {
    let message: Message
    let handle: AttachmentHandle
    var isRecording = false

    var body: some View {
        if message.fromMe, message.uploadState == .pending {
            TransferBar(label: "Uploading", progress: handle.progress)
        } else if case .downloading = handle.state, !isRecording || handle.progress != nil {
            TransferBar(label: "Downloading", progress: handle.progress)
        } else if let saved = handle.savedTo {
            SavedNote(file: saved)
        } else if !isRecording, let reason = handle.failureReason {
            Text(reason)
                .font(Theme.font(11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
        }
    }
}

/// "Saved to Downloads · Show in Finder", once a file was saved there.
struct SavedNote: View {
    @Environment(AppModel.self) private var model
    let file: URL

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Saved to Downloads")
                .muted()
                .help(file.lastPathComponent)
            Button("Show in Finder") { model.showInFinder(file) }.buttonStyle(.peel(.link, size: .sm))
        }
    }
}

extension View {
    /// An image or video tile's corners and edge.
    func attachmentTile() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.divider))
    }

    /// An image or video tile filled by this view: at `size`'s shape, as
    /// large as `size` but narrower when the column is (a thread panel, a
    /// narrow window), never past its edge; ours with its upload over it.
    func attachmentTile(fitted size: CGSize, message: Message, handle: AttachmentHandle) -> some View {
        overlay(alignment: .bottom) {
            if message.fromMe, message.uploadState == .pending {
                TransferBar(label: "Uploading", progress: handle.progress).padding(Theme.Space.sm)
            }
        }
        .attachmentTile(fitted: size)
    }

    /// A tile filled by this view at `size`'s shape, as above.
    func attachmentTile(fitted size: CGSize) -> some View {
        Color.clear
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .frame(maxWidth: size.width)
            .overlay { self }
            .attachmentTile()
    }

    /// Downloads `message`'s attachment as it shows (`AppModel.autoDownload`),
    /// and again once an upload of ours is done (a retry claims no preview).
    func autoDownload(_ message: Message) -> some View {
        modifier(AutoDownload(message: message))
    }

    /// A file or audio card: an inset `Card`, as wide as a column allows,
    /// up to 300 pt.
    func attachmentCard() -> some View {
        Card(.inset) {
            padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 10)
                .frame(maxWidth: 300, alignment: .leading)
        }
        .foregroundStyle(Theme.text)
    }
}

private struct AutoDownload: ViewModifier {
    @Environment(AppModel.self) private var model
    let message: Message

    func body(content: Content) -> some View {
        content.task(id: "\(message.id ?? 0)/\(message.upload ?? "")") { await model.autoDownload(message) }
    }
}

/// A small square for an attachment: the image itself, a video's or a
/// recording's symbol, or the file's type.
struct AttachmentMark: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let size: CGFloat

    @State private var image: CGImage?

    var body: some View {
        let handle = model.attachment(message.id ?? 0)
        Group {
            if message.attachmentKind == .image, let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if let symbol = model.attachmentKind(of: message)?.symbol {
                Theme.selection.overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.36, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
            } else {
                Theme.selection.overlay {
                    Text(message.attachmentKind == .image ? "IMG" : AttachmentFormat.badge(message.fileName, mediaType: message.mediaType))
                        .font(Theme.font(size * 0.26, .bold))
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: handle.file) {
            guard message.attachmentKind == .image else { return }
            if handle.file == nil { await model.download(message) }
            if let file = handle.file { image = await ImageCache.shared.image(file, maxPixels: Int(size * 2)) }
        }
    }
}

// MARK: - Composer

/// The files waiting in a composer, each with a remove button, and a "+"
/// to add more.
struct PendingFilesTray: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID
    let files: [URL]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(files, id: \.self) { file in
                    PendingFile(file: file)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.removeFile(file, from: composer)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Theme.text, Theme.input)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(file.lastPathComponent)")
                            .offset(x: 5, y: -5)
                        }
                }
                Button {
                    model.chooseFiles(for: composer)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 64, height: 64)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.divider, style: StrokeStyle(dash: [4, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add files")
                AttachmentPriceField(composer: composer)
            }
            .padding(.top, Theme.Space.sm)
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
    }
}

/// A file waiting to be sent: a picture's thumbnail, or a card.
private struct PendingFile: View {
    let file: URL

    @State private var image: CGImage?

    private var isImage: Bool {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
    }

    var body: some View {
        Group {
            if isImage {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Theme.quote
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .task(id: file) { image = await ImageCache.shared.image(file, maxPixels: 128) }
            } else {
                HStack(spacing: Theme.Space.sm) {
                    Theme.selection
                        .overlay {
                            Text(AttachmentFormat.badge(file.lastPathComponent))
                                .font(Theme.font(10, .bold))
                        }
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.lastPathComponent)
                            .font(Theme.font(13, .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text([AttachmentFormat.size(Self.size(file)), AttachmentFormat.kind(file.lastPathComponent)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.font(11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: 150, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: 64)
                .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
        .help(file.lastPathComponent)
    }

    private static func size(_ file: URL) -> Int64? {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }
    }
}

extension View {
    /// Files dropped here wait in `composer` until it sends.
    func fileDrop(into composer: ComposerID) -> some View {
        modifier(FileDrop(composer: composer))
    }
}

private struct FileDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let composer: ComposerID

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            // Files, image data and file promises (the screenshot thumbnail).
            .onDrop(of: PasteboardFiles.dropTypes, delegate: Delegate(model: model, composer: composer))
            #else
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                model.addFiles(files, to: composer)
                return !files.isEmpty
            } isTargeted: { model.dropTarget = $0 ? composer : nil }
            #endif
            .overlay {
                if model.dropTarget == composer {
                    DropTarget()
                }
            }
    }
}

#if os(macOS)
extension FileDrop {
    /// Takes only drags with something for the tray: rich text that carries
    /// a picture of itself is not offered as a drop.
    /// The drag's own pasteboard is read rather than SwiftUI's item
    /// providers, so file promises are taken as AppKit documents them.
    struct Delegate: DropDelegate {
        let model: AppModel
        let composer: ComposerID
        private var drag: NSPasteboard { NSPasteboard(name: .drag) }

        func validateDrop(info: DropInfo) -> Bool { PasteboardFiles.hasFiles(drag) }
        func dropEntered(info: DropInfo) { model.dropTargeted(PasteboardFiles.hasFiles(drag), composer: composer) }
        func dropExited(info: DropInfo) { model.dropTargeted(false, composer: composer) }

        func performDrop(info: DropInfo) -> Bool {
            model.dropTargeted(false, composer: composer)
            let items = PasteboardFiles.items(on: drag, promises: true)
            guard !items.isEmpty else { return false }
            model.attach(items, to: composer)
            return true
        }
    }
}
#endif

/// Over a conversation while files are dragged onto it.
private struct DropTarget: View {
    var body: some View {
        ZStack {
            Theme.background.opacity(0.82)
            VStack(spacing: 10) {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .frame(width: 56, height: 56)
                    .background(Theme.selection, in: Circle())
                Text("Drop to attach")
                    .font(Theme.font(16, .bold))
            }
            .padding(24)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(10)
        )
        .allowsHitTesting(false)
    }
}
