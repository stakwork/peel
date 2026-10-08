import ImageIO
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

    var body: some View {
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
        return PhotoCache.shared.cached(photo)
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
            if let photo, let image = await PhotoCache.shared.image(for: photo) { loaded = (photo, image) }
        }
        .frame(width: size, height: size)
        .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.25)))
    }
}

/// Photos fetched once per URL and kept for the session. A row in a lazy list
/// is made and dropped as it scrolls; each `AsyncImage` fetched on its own and
/// a row dropped mid-fetch was left on its initial for good, so every run of a
/// tribe member's messages after the first showed no photo. Here the fetch
/// belongs to the cache, not the row, and every row with that URL shares it.
@MainActor
final class PhotoCache {
    static let shared = PhotoCache()

    private var images: [URL: CGImage] = [:]
    /// A fetch that throws (no answer, or the server busy or failing) is tried
    /// again next time; one that returns nil got no image and joins `failed`.
    private var loads: [URL: Task<CGImage?, any Error>] = [:]
    /// URLs whose server gave no image, not asked for again this session.
    private var failed: Set<URL> = []

    func cached(_ url: URL) -> CGImage? { images[url] }

    func image(for url: URL) async -> CGImage? {
        if let image = images[url] { return image }
        guard !failed.contains(url) else { return nil }
        let load: Task<CGImage?, any Error>
        if let running = loads[url] {
            load = running
        } else {
            load = Task.detached(priority: .utility) {
                guard let data = try await Web.photo(at: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                // Decoded here, at avatar size (the short side still covers a
                // 36pt avatar at 2x for photos up to 3:1, as it is filled), so
                // drawing neither decodes on the main thread nor keeps the full photo.
                return ImageDecoding.thumbnail(source, maxPixels: 256)
            }
            loads[url] = load
        }
        let result = await load.result
        loads[url] = nil
        switch result {
        case .success(let image?): images[url] = image; return image
        case .success(nil): failed.insert(url); return nil
        case .failure: return nil
        }
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
