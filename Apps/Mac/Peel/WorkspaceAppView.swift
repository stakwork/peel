import AppKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI
import WebKit

/// A Stadeum workspace's app in the detail column (strut's plans/apps.md
/// §7.4): Peel's own strut's UI showing the app's page and nothing else
/// (`MemoryServer.page(of:)`). strut frames the page in a sandboxed frame and
/// relays its calls to the workspace with the person's token, which Peel
/// never holds. strut's UI is the strut Peel ships; the page in its frame is
/// the workspace's.
struct WorkspaceAppView: View {
    @Environment(AppModel.self) private var model
    let app: WorkspaceApp
    /// Bumped by Reload: a new web view loads the page again.
    @State private var loads = 0

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: app.title, subtitle: "@\(app.peer)") {
                Image(systemName: WorkspaceApp.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: Theme.AvatarSize.lg, height: Theme.AvatarSize.lg)
            } trailing: {
                IconButton("arrow.clockwise", help: "Reload") { loads += 1 }
            }
            if let server = model.memoryServer, let page = server.page(of: app) {
                AppPage(page: StrutPage(url: page, server: server, name: app.title))
                    // Another app, strut started again (a new port and key), or Reload: a new
                    // page; not the workspace renaming it, which would lose what the page holds.
                    .id(PageID(app: app.id, server: server, loads: loads))
            } else {
                EmptyState("Apps open on Peel's own strut, which is not running.")
            }
        }
    }

    private struct PageID: Hashable {
        let app: String
        let server: MemoryServer
        let loads: Int
    }
}

extension WorkspaceApp {
    /// The sidebar row's icon and the header's.
    static let symbol = "square.grid.2x2"
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
