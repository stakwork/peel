import SwiftUI
import PeelCore

/// A contact's photo, or a tribe's icon.
struct ConversationIcon: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let size: CGFloat

    var body: some View {
        if conversation.isTribe {
            TribeIcon(name: conversation.name, url: conversation.photoURL, pubkey: conversation.chat, size: size)
        } else {
            Avatar(name: conversation.name, url: conversation.photoURL, size: size,
                   hue: model.hue(pubkey: conversation.chat, alias: nil, inTribe: false))
        }
    }
}

/// A tribe's image, or its initial on its own colour, on a rounded square:
/// the square is what tells a tribe from a person.
struct TribeIcon: View {
    let name: String
    let url: String?
    /// The tribe's key, which picks its colour from people's palette.
    let pubkey: String
    let size: CGFloat

    var body: some View { avatar }

    var avatar: Avatar {
        Avatar(name: name, url: url, size: size, hue: PersonHue(pubkey: pubkey, alias: nil, inTribe: false),
               shape: .roundedSquare)
    }
}

/// A person's photo, or their initials on their colour (`PersonHue`, from
/// `AppModel.hue`); a tribe's the same on a rounded square, coloured by its
/// key. Only https photos are ever loaded.
struct Avatar: View {
    enum Shape { case circle, roundedSquare }

    let name: String
    let url: String?
    let size: CGFloat
    let hue: PersonHue
    var shape: Shape = .circle

    private var photo: URL? {
        url?.httpsOnly.flatMap(URL.init)
    }

    /// "Tom Smith" and "Tom_Smith" are TS, "Bot" is B; a tribe, or anyone
    /// under 18 pt (two letters there are too small to read), the initial.
    private var initials: String {
        let words = name.split { $0 == " " || $0 == "_" }.prefix(shape == .roundedSquare || size < 18 ? 1 : 2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// The fetched photo, kept with its URL so a view reused for another
    /// person never shows the last one's photo while the new one loads.
    @State private var loaded: (url: URL, image: CGImage)?

    private var image: CGImage? {
        guard let photo else { return nil }
        if let loaded, loaded.url == photo { return loaded.image }
        return ImageCache.photos.cached(photo: photo)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                hue.avatarFill.overlay {
                    // At every size, down to a boost chip's 16 pt: the letter
                    // is how you tell people apart.
                    let initials = initials
                    Text(initials)
                        .font(Theme.font(size * (initials.count > 1 ? 0.38 : size < 24 ? 0.55 : 0.42), .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .task(id: photo) {
            if let photo, let image = await ImageCache.photos.image(photo: photo) { loaded = (photo, image) }
        }
        .frame(width: size, height: size)
        .clipShape(outline)
    }

    /// Its shape at its size, for what is drawn over it.
    var outline: AnyShape { Self.outline(shape, size: size) }

    /// A shape at a size: people round, tribes and agents a rounded square.
    static func outline(_ shape: Shape, size: CGFloat) -> AnyShape {
        shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.25))
    }
}

/// The app's icon, as the Dock shows it.
struct AppIcon: View {
    let size: CGFloat

    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
        #endif
    }
}
