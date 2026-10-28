import PeelCore
import PeelUI
import SwiftUI

// Pictures, video and files in a conversation on the phone: images (alone
// or a run's grid) and GIFs drawn, voice messages played, video in place
// (`VideoTile`), PDFs and other files as a card that previews and shares
// (`FileCard`), all downloaded through the model as on the Mac
// (`AppModel.autoDownload`, `ImageCache`). A tapped image opens full screen
// (`ImageViewer`); buying is the Mac's for now.

/// A message's attachment: a run of images as a grid, one image, or a file.
struct AttachmentBlock: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow

    var body: some View {
        let message = row.message
        if row.images.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(row.images, id: \.id) { image in
                    ImageTile(message: image, square: true, run: row.images)
                }
            }
            .frame(maxWidth: ImageTile.side)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.images.count) images")
        } else if message.attachmentPriceMsat != nil, !message.fromMe {
            FileMark(message: message, note: "Paid. Buy it on the Mac for now.")
        } else {
            // What the bytes turned out to be once downloaded: a fake video is a file.
            switch model.attachmentKind(of: message) {
            case .image: ImageTile(message: message)
            case .video: VideoTile(message: message)
            case .audio: VoiceBubble(message: message)
            case .pdf, .text, .file, nil: FileCard(message: message)
            }
        }
    }
}

/// An image, fitted within the chat's tile and kept at its shape once
/// known; a quiet square while it loads.
struct ImageTile: View {
    @Environment(AppModel.self) private var model
    let message: Message
    /// In a run's grid: cropped to a square.
    var square = false
    /// The run's images the viewer pages through, this one among them; empty for one alone.
    var run: [Message] = []

    @State private var image: CGImage?
    @State private var viewing: ImageViewerRequest?

    static let side: CGFloat = 240

    var body: some View {
        let handle = message.id.map(model.attachment)
        let file = handle?.file
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        Group {
            if let image {
                let picture = Image(decorative: image, scale: 1).resizable()
                if square {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { picture.scaledToFill() }
                } else {
                    picture.aspectRatio(contentMode: .fit)
                        .frame(maxWidth: Self.side, maxHeight: Self.side * 1.25, alignment: .leading)
                }
            } else {
                Theme.quote
                    .aspectRatio(square ? 1 : 4 / 3, contentMode: .fit)
                    .frame(maxWidth: Self.side)
                    .overlay {
                        if handle?.failureReason != nil {
                            Image(systemName: "photo").foregroundStyle(Theme.secondaryText)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.divider))
        .accessibilityElement()
        .accessibilityLabel("Image")
        .accessibilityAddTraits([.isImage, .isButton])
        .accessibilityHint("Opens the image full screen")
        .contentShape(shape)
        .onTapGesture {
            guard image != nil else { return }
            let messages = run.isEmpty ? [message] : run
            viewing = ImageViewerRequest(messages: messages, start: messages.firstIndex { $0.id == message.id } ?? 0)
        }
        .fullScreenCover(item: $viewing) { ImageViewer(request: $0) }
        // Again once an upload of ours is done (the Mac's `AutoDownload`).
        .task(id: TileKey(file: file, upload: message.upload)) {
            if let file {
                image = await ImageCache.shared.image(file, maxPixels: ImageCache.tilePixels)
            } else {
                await model.autoDownload(message)
            }
        }
    }
}

private struct TileKey: Hashable {
    let file: URL?
    let upload: String?
}

/// A GIF from Giphy, its first frame (the phone does not play them yet).
struct GiphyPicture: View {
    let giphy: Giphy

    @State private var frames: AnimationFrames?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        let shown = frames ?? giphy.url.flatMap { ImageCache.animations.cached(giphy: $0) }
        Group {
            if let first = shown?.frames.first {
                Image(decorative: first, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Theme.quote.aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { Text("GIF").phoneFont(.secondary).foregroundStyle(Theme.secondaryText) }
            }
        }
        .frame(maxWidth: ImageTile.side, alignment: .leading)
        .clipShape(shape)
        .accessibilityLabel("GIF")
        .accessibilityAddTraits(.isImage)
        .task(id: giphy.url) {
            guard let url = giphy.url, shown == nil else { return }
            frames = await ImageCache.animations.animation(giphy: url)
        }
    }
}

/// A paid attachment of someone else's: its kind's symbol, its name, and
/// why it does not open here.
struct FileMark: View {
    let message: Message
    let note: String

    var body: some View {
        PhoneCard {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.fileName ?? message.preview)
                        .phoneFont(.row)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(note)
                        .phoneFont(.time)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch message.attachmentKind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        default: "doc"
        }
    }
}
