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
                WorkspaceApp.headerIcon(app.iconSymbol)
            } trailing: {
                // The chip says what the status would, but problems.
                if versions == nil || app.problems > 0 { AppStatus(app: app) }
                if let versions {
                    AppVersionsControl(title: app.title, versions: versions, previewing: $previewing, busy: changing,
                                       change: change)
                }
                AppPinButton(app: app)
                IconButton("arrow.clockwise", help: "Reload") { loads += 1 }
            }
            if let previewing, let versions {
                AppPreviewBar(shown: previewing, live: versions.active) { self.previewing = nil }
            }
            if let server = model.memoryServer, let page = server.page(of: app, version: previewing) {
                AppPage(page: StrutPage(url: page, server: server, name: app.title))
                    // Another app, a preview, strut started again (a new port and key), Reload, or
                    // a change of what is live made here: a new page; not a publish or the workspace
                    // renaming it, which would lose what the page holds.
                    .id(PageID(app: app.id, previewing: previewing, server: server, loads: loads))
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

    private struct PageID: Hashable {
        let app: String
        let previewing: String?
        let server: MemoryServer
        let loads: Int
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

/// The web view under an app: strut's UI from Peel's own strut, on a store
/// that keeps nothing (the key it is handed lives in the tab's session
/// storage, and goes with the view), limited as the web pane is
/// (`WebPane.limit`), and kept to `StrutPage`'s rules: a link out of the page
/// opens beside it as a message's link does, only right after the person
/// clicked or typed in it, since the page's scripts are the workspace's. No
/// download, camera or microphone.
private struct AppPage: NSViewRepresentable {
    let page: StrutPage
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, open: openURL)
    }

    func makeNSView(context: Context) -> InputWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        WebPane.limit(configuration)
        let view = InputWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        // A force click's preview would load a link outside these rules.
        view.allowsLinkPreview = false
        view.load(URLRequest(url: page.url))
        return view
    }

    func updateNSView(_ view: InputWebView, context: Context) {}

    static func dismantleNSView(_ view: InputWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let page: StrutPage
        private let open: OpenURLAction
        private var crashes = CrashReload()

        init(page: StrutPage, open: OpenURLAction) {
            self.page = page
            self.open = open
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
            page.newWindow(for: action, from: webView, open: open, download: nil)
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // With the key: strut's UI took it out of the address it shows.
            if crashes.again() { webView.load(URLRequest(url: page.url)) }
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
