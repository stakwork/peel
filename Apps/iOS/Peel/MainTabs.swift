import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// The tab bar (docs/design/iphone.md, decision 1): Chats, Payments, Apps,
/// You. Search is a button in Chats' bar, not a tab. Each tab is its own `NavigationStack` with
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
            // The Dock badge's count; blue (the tab bar appearance, `PeelPhoneApp`).
            .badge(model.unreadCount)
            Tab("Payments", systemImage: "bolt", value: PhoneTab.payments) {
                PaymentsTab(model: model)
            }
            // Sats just received, "+350", as the Mac's Payments row shows them.
            .badge(model.money.recentMsat > 0 ? Text(Sats.signed(msat: model.money.recentMsat, incoming: true)) : nil)
            Tab(String(localized: "Apps"), systemImage: "square.grid.2x2", value: PhoneTab.apps) {
                NavigationStack(path: $router.apps) {
                    AppsScreen()
                        .onCallBannerInset()
                        .navigationDestination(for: AppsRoute.self) { route in
                            switch route {
                            case .org(let page):
                                OrgPageSheet(page: page, leave: leaveApp)
                            case .visit(let page):
                                OrgPageSheet(page: page, appTitle: model.openedAppTitle(page.link), leave: leaveApp)
                            }
                        }
                }
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
            // Until the twelve words are checked (You's Back up now).
            .badge(model.wordsConfirmed ? nil : Text(verbatim: "!"))
        }
        // A link or a deliverable from a chat: full screen over it, ✕ to close (Apps pushes its own).
        .fullScreenCover(item: $router.orgPage) { page in
            OrgPageSheet(page: page)
        }
        // The Join sheet a tapped tribe link asked for (`AppModel.openTribeLink`).
        .sheet(isPresented: Binding(
            get: { model.joiningTribeLink != nil },
            set: { if !$0 { model.joiningTribeLink = nil } }
        )) {
            SheetStack { JoinTribeSheet(link: model.joiningTribeLink ?? "") }
        }
        // A tapped Hive link to an app opens it when its workspace is paired
        // here. Otherwise it says to connect that workspace first and still
        // goes to the browser, so Hive shows its own sign-in or not-found;
        // any other link is the system's, as before.
        .environment(\.openURL, OpenURLAction { url in
            // A tribe link opens in Peel: its chat, or the Join sheet filled in; never the system's.
            if model.openTribeLink(url.absoluteString) { return .handled }
            // A public app's link opens in Peel (queued while locked), never in the system's browser.
            if PublicAppLink(peelLink: url) != nil, router.open(peelLink: url) { return .handled }
            switch model.stadeum.tap(url) {
            case .open(let page, _):
                if case .page(let request) = model.stadeum.opening(page) { router.orgPage = request }
                return .handled
            case .connectFirst(let slug):
                CopyFeedback.announce(String(localized: "Connect @\(slug) first"))
                return .systemAction
            case .notOurs:
                return .systemAction
            }
        })
        // Its workspace no longer in use (revoked, disconnected, renewed
        // without it), or its box no longer linked: the page and its token go.
        .onChange(of: model.stadeum.live) { closeGoneOrgPage() }
        .onChange(of: model.boxes.links) { closeGoneOrgPage() }
        // A box's link waiting for the person's yes (`Boxes.asking`): nothing
        // is signed without it. The alert's buttons answer it; no other way shuts it.
        .alert(
            model.boxes.asking.map(BoxWords.title) ?? "",
            isPresented: Binding(get: { model.boxes.asking != nil }, set: { _ in }),
            presenting: model.boxes.asking
        ) { _ in
            Button("Link") { model.boxes.accept() }
            Button("Cancel", role: .cancel) { model.boxes.decline() }
        } message: { offer in
            Text(BoxWords.question(offer))
        }
    }

    /// Back from an app pushed in Apps, to the list.
    private func leaveApp() {
        if !router.apps.isEmpty { router.apps.removeLast() }
    }

    private func closeGoneOrgPage() {
        let gone = { (page: OrgPageRequest) in
            !model.stadeum.live.contains(where: { $0.id == page.peer }) && !model.boxes.shows(page)
        }
        if let page = router.orgPage, gone(page) { router.orgPage = nil }
        // One pushed in Apps leaves the stack the same way.
        if router.apps.contains(where: { if case .org(let page) = $0 { gone(page) } else { false } }) {
            router.apps.removeAll { if case .org(let page) = $0 { gone(page) } else { false } }
        }
    }
}

/// Your photo at 30 pt as the You tab's icon, larger than a glyph (Tom);
/// your initial on your colour without a photo. Selected, a 2 pt accent
/// ring and a thin gap are drawn inside its edge, not outside it, where
/// they ran into the tab's label. A tab bar draws only images, so it is
/// rendered to one.
private struct YouTabIcon: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    let selected: Bool
    @State private var image: UIImage?

    private static let side: CGFloat = 30
    private static let ring: CGFloat = 2

    /// What the image is drawn from: drawn again only when one changes.
    private struct Key: Hashable {
        let name: String
        let photo: String?
        let hue: PersonHue
        let selected: Bool
        let scale: CGFloat
        let scheme: ColorScheme
    }

    var body: some View {
        let key = Key(name: model.me.avatarName, photo: model.myPhotoURL, hue: model.myHue,
                      selected: selected, scale: displayScale, scheme: colorScheme)
        Image(uiImage: image ?? UIImage())
            .renderingMode(.original)
            .accessibilityHidden(true)
            .task(id: key) {
                // Initials (or the cached photo) at once, as the fallback.
                image = Self.render(key)
                // `Avatar` draws a photo only once it is in the cache, and a
                // fetch at launch can fail: try again, a few times, slower.
                guard let photo = key.photo?.httpsOnly.flatMap(URL.init),
                      ImageCache.photos.cached(photo: photo) == nil else { return }
                var delay: UInt64 = 1
                for _ in 0..<5 {
                    if Task.isCancelled { return }
                    _ = await ImageCache.photos.image(photo: photo)
                    if ImageCache.photos.cached(photo: photo) != nil { break }
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay *= 2
                }
                if Task.isCancelled { return }
                if ImageCache.photos.cached(photo: photo) != nil { image = Self.render(key) }
            }
    }

    private static func render(_ key: Key) -> UIImage? {
        let icon = Avatar(name: key.name, url: key.photo, size: side, hue: key.hue)
            .overlay {
                if key.selected {
                    // Inside the photo's edge, so the icon stays 30 pt and
                    // clear of the label: the ring, then a gap in the page's colour.
                    Circle().strokeBorder(Theme.accent, lineWidth: ring)
                    Circle().inset(by: ring).strokeBorder(Theme.background, lineWidth: 1.5)
                }
            }
        let renderer = ImageRenderer(content: icon.environment(\.colorScheme, key.scheme))
        renderer.scale = key.scale
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }
}
