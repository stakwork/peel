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
                AppPage(url: page, server: server)
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
/// (`WebPane.limit`), and nowhere else. A link out of the page opens beside
/// it as a message's link does (`WebPane.follow`), only right after the
/// person clicked or typed in it: the page's scripts are the workspace's.
/// No download, camera or microphone.
private struct AppPage: NSViewRepresentable {
    let url: URL
    let server: MemoryServer
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(page: url, server: server, open: openURL)
    }

    func makeNSView(context: Context) -> AppWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        WebPane.limit(configuration)
        let view = AppWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        // A force click's preview would load a link outside these rules.
        view.allowsLinkPreview = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: AppWebView, context: Context) {}

    static func dismantleNSView(_ view: AppWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// The page's address with the key: loaded again, never shown.
        private let page: URL
        private let server: MemoryServer
        private let open: OpenURLAction
        private var crashes = CrashReload()

        init(page: URL, server: MemoryServer, open: OpenURLAction) {
            self.page = page
            self.server = server
            self.open = open
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
            let mainFrame = action.targetFrame?.isMainFrame ?? true
            if action.shouldPerformDownload { return .cancel }
            if server.serves(url) { return .allow }
            switch scheme {
            case "about":
                // The page's own frame (`srcdoc`).
                return .allow
            case "data", "blob":
                return mainFrame ? .cancel : .allow
            case "http", "https":
                // Anywhere else: a link the person clicked opens beside the app.
                if action.navigationType == .linkActivated { follow(url, from: webView) }
                return .cancel
            default:
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .cancel
        }

        /// `target=_blank` and `window.open`: strut's UI opens a page's link
        /// to anywhere but strut this way; it opens beside the app.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url, !server.serves(url) { follow(url, from: webView) }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // With the key: strut's UI took it out of the address it shows.
            if crashes.again() { webView.load(URLRequest(url: page)) }
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

        /// Only on the person's own click or key: a script's `click()` is
        /// `linkActivated` too, and could keep opening pages in the pane.
        private func follow(_ url: URL, from webView: WKWebView) {
            guard (webView as? AppWebView)?.personActed == true else { return }
            WebPane.follow(url, with: open)
        }
    }
}

/// The app's web view, which knows when the person last clicked or typed in
/// it: events AppKit delivers, which no script on the page can make.
final class AppWebView: WKWebView {
    private var lastInput: ContinuousClock.Instant?

    /// The person clicked or typed here within the last second.
    var personActed: Bool { lastInput.map { .now - $0 < .seconds(1) } ?? false }

    override func mouseDown(with event: NSEvent) {
        lastInput = .now
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastInput = .now
        super.keyDown(with: event)
    }
}
