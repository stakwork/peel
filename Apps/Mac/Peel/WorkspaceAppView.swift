import AppKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI
import WebKit

/// An app in the detail column, a Stadeum workspace's or the person's own
/// (strut's plans/apps.md §7.4): Peel's own strut's UI showing the app's
/// page and nothing else (`MemoryServer.page(of:)`). strut frames the page in
/// a sandboxed frame and, for a workspace's, relays its calls to the
/// workspace with the person's token, which Peel never holds. strut's UI is the strut Peel ships; the page in its frame is
/// the workspace's.
struct WorkspaceAppView: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    /// Bumped by Reload: a new web view loads the page again.
    @State private var loads = 0
    /// The person's own app's versions (`AppVersionsControl`); a
    /// workspace's are its own to change, so none.
    @State private var versions: AppVersions?
    /// The version shown in this window instead of the live one.
    @State private var previewing: String?
    /// A change of what is live is under way: none other until strut answers.
    @State private var changing = false

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: app.title, subtitle: subtitle) {
                WorkspaceApp.headerIcon(app.icon)
            } trailing: {
                // The chip says what the status would, but problems.
                if versions == nil || app.problems > 0 { AppStatus(app: app) }
                if let versions {
                    AppVersionsControl(title: app.title, versions: versions, previewing: $previewing, busy: changing,
                                       change: change)
                }
                AppShareButton(app: app)
                AppPinButton(app: app)
                IconButton("arrow.clockwise", help: "Reload") { loads += 1 }
            }
            if let previewing, let versions {
                AppPreviewBar(shown: previewing, live: versions.active) { self.previewing = nil }
            }
            let place = model.appPlaces[app.id] ?? AppPlace()
            if let server = model.memoryServer, let page = server.page(of: app, version: previewing, input: place.input) {
                let id = AppPageID(app: app.id, previewing: previewing, server: server, loads: loads, opened: place.opened)
                AppPage(page: StrutPage(url: page, server: server, name: app.title), id: id, pages: model.appPages,
                        moved: { [model, app] input in
                            if model.appPlaces[app.id]?.input != input { model.appPlaces[app.id, default: AppPlace()].input = input }
                        },
                        openApp: { [model] in model.open($0) })
                    // Another app, a preview, strut started again (a new port and key), Reload,
                    // a change of what is live made here, or a link opening it at a view: a new
                    // page, at the view the last one had reached; not a publish or the workspace
                    // renaming it, which would lose what the page holds.
                    .id(id)
            } else {
                EmptyState("Apps open on Peel's own strut, which is not running.")
            }
        }
        // Read again when the listing says something moved (a new version, a new live one or
        // release), and on Reload: what the live release locked moves on without the listing.
        .task(id: VersionsID(app: app.id, live: app.version, newest: app.newest, release: app.release,
                             server: model.memoryServer, loads: loads)) {
            await readVersions()
        }
    }

    /// The source when several are listed; the version is the chip's to show.
    private var subtitle: String? {
        versions == nil ? app.caption(showsSource: model.showsAppSources) : model.showsAppSources ? app.source : nil
    }

    private func readVersions() async {
        guard app.peer == nil, let server = model.memoryServer else {
            versions = nil
            return
        }
        // A read that fails keeps what was read: the chip stays as it was.
        guard let read = try? await AutomationsClient(server: server).versions(of: app.name), !Task.isCancelled else { return }
        versions = read
        // The version shown here went live elsewhere: it is everyone's page now.
        if previewing == read.active { previewing = nil }
    }

    /// Asks strut to change what everyone opens; once it has, the live page
    /// and its versions, read here rather than waiting for the listing.
    private func change(_ target: AppLiveTarget, done: String) {
        guard !changing else { return }
        changing = true
        Task {
            if await model.makeLive(app, target, done: done) {
                previewing = nil
                loads += 1
            }
            changing = false
        }
    }

    private struct VersionsID: Hashable {
        let app: String
        let live: String?
        let newest: String?
        let release: String?
        let server: MemoryServer?
        let loads: Int
    }
}

/// Pins an app under the sidebar's Apps row, or takes it off: in its header
/// and on its card in Apps.
struct AppPinButton: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp

    var body: some View {
        let pinned = model.isPinned(app)
        IconButton(help: pinned ? "Unpin from the sidebar" : "Pin to the sidebar") {
            model.setPinned(app, !pinned)
        } label: {
            // As the call window's keep-on-top pin.
            if pinned {
                Image(systemName: "pin.fill").foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "pin")
            }
        }
        .accessibilityValue(pinned ? "On" : "Off")
    }
}

/// Copies the link that shares an app (`WorkspaceApp.shareLink`): to the
/// clipboard only, nothing is sent. Not shown for one of the person's own.
struct AppShareButton: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp

    var body: some View {
        if let link = app.shareLink() {
            IconButton("link", help: "Copy link to share") {
                guard Clipboard.copy(link.absoluteString) else { return }
                (model.mainPresenter as? MenuPresenter)?.showToast("Link copied")
            }
        }
    }
}

/// Which page of an app a web view shows: another of any of these is another page.
struct AppPageID: Hashable {
    let app: String
    let previewing: String?
    let server: MemoryServer
    let loads: Int
    /// `AppPlace.opened`.
    let opened: Int
}

/// Where an app's page is (`AppModel.appPlaces`): the view it shows, as
/// strut keeps it in the page's address (`?input=`, strut's plans/apps.md
/// §7.1), which a page made again (Reload, a closed one shown again, a
/// preview) opens at; and how many times a link has opened the app at a
/// view, each a new page there.
struct AppPlace: Hashable {
    var input: String?
    var opened = 0

    mutating func open(at input: String?) {
        self.input = input
        opened += 1
    }
}

/// The web views of the apps shown lately, kept while the person is in
/// another destination so the page keeps what it holds (`AppModel.appPages`).
/// A view's coordinator is its delegate, which a web view holds weakly, so
/// it is kept with it.
typealias AppPages = KeepAlive<AppPageID, (view: InputWebView, coordinator: AppPage.Coordinator)>

extension AppPages {
    /// Three apps at most: the one shown longest ago is closed.
    static func make() -> AppPages {
        KeepAlive(limit: 3) { kept in
            kept.view.stopLoading()
            kept.view.navigationDelegate = nil
            kept.view.uiDelegate = nil
        }
    }
}

/// The web view under an app: strut's UI from Peel's own strut, on a store
/// that keeps nothing (the key it is handed lives in the tab's session
/// storage, and goes with the view), limited as the web pane is
/// (`WebPane.limit`), and kept to `StrutPage`'s rules: a link out of the page
/// opens beside it as a message's link does, and one to another app goes to
/// `openApp`, only right after the person clicked or typed in it, since the
/// page's scripts are the workspace's. Where the page moves to in place is
/// told to `moved`. No download, camera or microphone.
struct AppPage: NSViewRepresentable {
    let page: StrutPage
    let id: AppPageID
    let pages: AppPages
    /// The view the page moved to (its `?input=`; nil for its first).
    let moved: (String?) -> Void
    let openApp: (StrutAppLink) -> Void
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, open: openURL, moved: moved, openApp: openApp)
    }

    func makeNSView(context: Context) -> InputWebView {
        let kept = pages.value(for: id, owner: id.app) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            WebPane.limit(configuration)
            let view = InputWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = context.coordinator
            view.uiDelegate = context.coordinator
            // A force click's preview would load a link outside these rules.
            view.allowsLinkPreview = false
            context.coordinator.watch(view)
            view.load(URLRequest(url: page.url))
            return (view, context.coordinator)
        }
        // Kept from a time it was shown before: it is put in the new place.
        kept.view.removeFromSuperview()
        return kept.view
    }

    func updateNSView(_ view: InputWebView, context: Context) {}

    /// The view stays in `pages`, which closes it when it is no longer wanted.
    static func dismantleNSView(_ view: InputWebView, coordinator: Coordinator) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let page: StrutPage
        private let open: OpenURLAction
        private let moved: (String?) -> Void
        private let openApp: (StrutAppLink) -> Void
        private var crashes = CrashReload()
        private var moves: NSKeyValueObservation?

        init(page: StrutPage, open: OpenURLAction, moved: @escaping (String?) -> Void,
             openApp: @escaping (StrutAppLink) -> Void) {
            self.page = page
            self.open = open
            self.moved = moved
            self.openApp = openApp
        }

        /// strut's page moves within the app in place, the view in its
        /// address (`?input=`): each one is where the app is now.
        func watch(_ view: WKWebView) {
            moves = view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageMoved(to: view.url) }
            }
        }

        private func pageMoved(to url: URL?) {
            guard let url, let shown = page.shownApp, let here = page.server.appLink(url, from: nil), here.app == shown else { return }
            moved(here.input)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            page.policy(for: action, in: webView, open: open, downloads: false)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            page.policy(for: response, downloads: false)
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            page.newWindow(for: action, from: webView, open: open, download: nil, openApp: openApp)
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // With the key, which strut's UI took out of the address it shows, at the view it was on.
            if crashes.again() { webView.load(URLRequest(url: page.url(at: webView.url))) }
        }

        func webView(
            _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
            initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
        ) async -> WKPermissionDecision {
            .deny
        }

        /// `<input type=file>`: the person picks, as for an attachment.
        func webView(
            _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo
        ) async -> [URL]? {
            FilePanels().open(multiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories)
        }
    }
}
