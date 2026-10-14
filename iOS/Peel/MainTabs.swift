import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// The tab bar (docs/design/iphone.md, decision 1): Chats, Payments, You,
/// and the system's search tab. Each tab is its own `NavigationStack` with
/// large titles; which tab and what each has pushed is `PhoneRouter`'s.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: PhoneTab.chats) {
                ChatsTab()
            }
            // The Dock badge's count; blue (`UITabBarItem` appearance, `PeelPhoneApp`).
            .badge(model.unreadCount)
            Tab("Payments", systemImage: "bolt", value: PhoneTab.payments) {
                PaymentsTab()
            }
            Tab(value: PhoneTab.you) {
                YouTab()
            } label: {
                Label {
                    Text("You")
                } icon: {
                    YouTabIcon(selected: router.tab == .you)
                }
            }
            Tab(value: PhoneTab.search, role: .search) {
                SearchTab()
            }
        }
    }
}

/// Your photo as the You tab's icon, inside a 2 pt accent ring past a
/// 2 pt gap while selected; your initial on your colour without a photo.
/// The whole is 30 pt (the design's photo size), so the photo is 22: a
/// larger image runs into the tab's label once the ring is on. A tab bar
/// draws only images, so it is rendered to one.
private struct YouTabIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let selected: Bool
    @State private var image: UIImage?

    private static let photo: CGFloat = 22
    private static let ring: CGFloat = 2

    /// What the image is drawn from: drawn again only when one changes.
    private struct Key: Hashable {
        let name: String
        let photo: String?
        let hue: PersonHue
        let selected: Bool
        let scale: CGFloat
    }

    var body: some View {
        let key = Key(name: model.me.avatarName, photo: model.myPhotoURL, hue: model.myHue,
                      selected: selected, scale: displayScale)
        Image(uiImage: image ?? UIImage())
            .renderingMode(.original)
            .accessibilityHidden(true)
            .task(id: key) {
                // `Avatar` draws a photo only once it is in the cache.
                if let photo = key.photo?.httpsOnly.flatMap(URL.init), ImageCache.photos.cached(photo: photo) == nil {
                    _ = await ImageCache.photos.image(photo: photo)
                }
                image = Self.render(key)
            }
    }

    private static func render(_ key: Key) -> UIImage? {
        let side = photo + 4 * ring
        let icon = ZStack {
            if key.selected {
                Circle().strokeBorder(Theme.accent, lineWidth: ring)
            }
            Avatar(name: key.name, url: key.photo, size: photo, hue: key.hue)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = key.scale
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }
}

/// Payments: the balance for now. F2c builds the screen (docs/design/iphone.md,
/// screen 6): Receive and Send, and the history by day.
private struct PaymentsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.payments) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Balance")
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                    Text(model.balanceText ?? "–")
                        .phoneFont(PhoneFont(size: 40, weight: .bold, style: .largeTitle))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text("Sending, receiving and the history come next.")
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.top, Theme.Space.lg)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The large title's margins.
                .scenePadding(.horizontal)
            }
            .background(Theme.background)
            .navigationTitle("Payments")
            .navigationDestination(for: PaymentsRoute.self) { _ in
                ComingScreen(title: "Payment", detail: "A payment's details show here.")
            }
        }
    }
}

/// The system's search tab: chats whose name matches, through the same
/// sections as Chats (`sidebarSections` filters by `searchQuery`, which the
/// router clears on leaving). Results across messages are still to design.
private struct SearchTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        @Bindable var model = model
        @Bindable var router = router
        NavigationStack(path: $router.search) {
            Group {
                if model.searchQuery.trimmed.isEmpty {
                    ContentUnavailableView("Search chats", systemImage: "magnifyingglass",
                                           description: Text("Tribes and people by name."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                } else {
                    ChatList()
                }
            }
            .navigationTitle("Search")
            .searchable(text: $model.searchQuery, prompt: "Search chats")
            .chatsDestinations()
        }
    }
}
