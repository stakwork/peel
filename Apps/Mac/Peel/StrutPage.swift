import AppKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI
import WebKit

/// A page of Peel's own strut's UI shown alone, with strut's key handed over
/// in its address (strut's UI keeps it for the tab and takes it out of the
/// address): a workspace's app in the detail column (`WorkspaceAppView`,
/// `MemoryServer.page(of:)`), or a deliverable from the agent's DM in the web
/// pane beside the chat (`WebPane.open(_:)`, `MemoryServer.page(showing:)`).
/// What is framed in it, an org's app or file, is the org's; the rules here
/// are what both keep to. Never described with its address, which holds
/// the key.
struct StrutPage: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The address with the key: loaded, and loaded again after a crash;
    /// never shown, logged or kept.
    let url: URL
    let server: MemoryServer
    /// What the person reads in the address's place.
    let name: String

    /// A deliverable's `name`: its title, and `@<id>` for an org's.
    static func name(_ title: String, on peer: String?) -> String {
        peer.map { "\(title) · @\($0)" } ?? title
    }

    var description: String { "strut page \(name)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["name": name]) }

    /// Where a navigation in the page may go: anywhere on this strut; the
    /// page's own frames (`srcdoc`, and a data or blob frame, never as the
    /// whole page); a link elsewhere only out to `open`, as a message's link
    /// opens, and only on the person's own click (`follow`); no other
    /// scheme. A download only where the host keeps them (`downloads`: the
    /// web pane, into Downloads), and only from strut's own page, never from
    /// a frame in it, which is the org's.
    @MainActor func policy(
        for action: WKNavigationAction, in webView: WKWebView, open: OpenURLAction, downloads: Bool
    ) -> WKNavigationActionPolicy {
        Self.policy(for: action, in: webView, serves: server.serves, open: open, downloads: downloads)
    }

    /// The same rules for any strut's UI, by what `serves` takes as that
    /// strut's: Peel's own (`policy(for:in:open:downloads:)`) or a linked
    /// box's (`WebPane.open(box:)`, `OrgPageRequest.serves`).
    @MainActor static func policy(
        for action: WKNavigationAction, in webView: WKWebView, serves: (URL) -> Bool, open: OpenURLAction, downloads: Bool
    ) -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return downloads && action.sourceFrame.isMainFrame ? .download : .cancel }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if serves(url) { return .allow }
        switch scheme {
        case "about":
            // The page's own frame (`srcdoc`).
            return .allow
        case "data", "blob":
            return mainFrame ? .cancel : .allow
        case "http", "https":
            if action.navigationType == .linkActivated { follow(url, from: webView, open: open) }
            return .cancel
        default:
            return .cancel
        }
    }

    /// A response the page cannot show: a download of strut's own page's
    /// where the host keeps them, else nothing.
    @MainActor static func policy(for response: WKNavigationResponse, downloads: Bool) -> WKNavigationResponsePolicy {
        if response.canShowMIMEType { return .allow }
        return downloads && response.isForMainFrame ? .download : .cancel
    }

    /// `target=_blank` and `window.open`, never a window: a link to anywhere
    /// but strut goes out to `open`; one from an app's page to another app
    /// (strut's page alone follows a link to its own app in place, and
    /// hands any other to its host this way) goes to `openApp`, as the app
    /// it names where this page lives (`StrutAppLink`) — never from a file,
    /// whose links an org or a model wrote and which is no app's; one to a
    /// file strut serves (its viewer's "open in a new tab", for a file it
    /// has no view of) is saved with `download` where the host keeps
    /// downloads; anything else of strut's UI (a run, a job: Peel has no
    /// view of them) nowhere. All only on the person's own click: WebKit
    /// lets the page's script open one only then, and the page is an org's
    /// or a model's.
    @MainActor func newWindow(
        for action: WKNavigationAction, from webView: WKWebView, open: OpenURLAction, download: ((URLRequest) -> Void)?,
        openApp: (StrutAppLink) -> Void
    ) {
        guard let url = action.request.url else { return }
        if !server.serves(url) {
            Self.follow(url, from: webView, open: open)
        } else if server.servesPage(url) {
            if Self.personActed(in: webView), let shown = shownApp, let link = server.appLink(url, from: shown.peer) { openApp(link) }
        } else if let download, Self.personActed(in: webView) {
            download(action.request)
        }
    }

    /// `target=_blank` and `window.open` on a linked box's page
    /// (`OrgPageRequest`), never a window, and only on the person's own
    /// click: a link to another of the box's apps, from strut's own page,
    /// opens in `webView` as its member; one anywhere else goes out to
    /// `open`; anything else of the box's strut nowhere.
    @MainActor static func newWindow(
        for action: WKNavigationAction, from webView: WKWebView, box: OrgPageRequest, open: OpenURLAction
    ) {
        guard let url = action.request.url, personActed(in: webView) else { return }
        if !box.serves(url) {
            WebPane.follow(url, with: open)
        } else if action.sourceFrame.isMainFrame, let link = box.appLink(url, from: webView.url), let there = box.request(for: link) {
            webView.load(there)
        }
    }

    /// The app this page shows, as its address names it; nil for a file.
    var shownApp: AgentArtifact.Handle? { server.appLink(url, from: nil)?.app }

    /// The address to load this page again at, after its web content
    /// process ended: where `current` (the web view's address) says the app
    /// had moved to, strut keeping the view the page opened in its address
    /// (`?input=`); with the key, which strut's UI took out of it.
    func url(at current: URL?) -> URL {
        guard let current, let shown = shownApp, let there = server.appLink(current, from: nil), there.app == shown else { return url }
        return StrutUI.page(url, input: there.input)
    }

    /// Only on the person's own click or key: a script's `click()` is
    /// `linkActivated` too, and could keep opening pages.
    @MainActor private static func follow(_ url: URL, from webView: WKWebView, open: OpenURLAction) {
        guard Self.personActed(in: webView) else { return }
        WebPane.follow(url, with: open)
    }

    @MainActor private static func personActed(in webView: WKWebView) -> Bool {
        (webView as? InputWebView)?.personActed == true
    }
}

/// A web view that knows when the person last clicked or typed in it:
/// events AppKit delivers, which no script on the page can make.
class InputWebView: WKWebView {
    private var lastInput: ContinuousClock.Instant?

    /// The person clicked or typed here within the last second.
    var personActed: Bool { acted(within: .seconds(1)) }

    /// The person clicked or typed here within `window`: the app wallet's
    /// sheets open only then (`StrutWalletBridge`, "the last few seconds").
    func acted(within window: Duration) -> Bool { lastInput.map { .now - $0 < window } ?? false }

    override func mouseDown(with event: NSEvent) {
        lastInput = .now
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastInput = .now
        super.keyDown(with: event)
    }
}

/// A linked box's page in place, as its member (`OrgPageRequest`): Jamie's
/// screen in a call (`Boxes.screen`). A box's page in the web pane keeps
/// to the same rules (`WebPane.open(box:)`): a store that keeps nothing,
/// the token handed over as the first request's bearer and, before the
/// page's script runs, in its storage; nowhere but that strut's UI, a link
/// out or to another of its apps only on the person's own click; no
/// download, camera or microphone. A page that does not load is told to
/// `failed`, and the call shows the video again; whether it has the
/// keyboard, to `keys` (Escape is the page's then).
struct BoxPageView: NSViewRepresentable {
    let page: OrgPageRequest
    let failed: () -> Void
    let keys: (Bool) -> Void
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, open: openURL, failed: failed)
    }

    func makeNSView(context: Context) -> KeyedWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: page.handOver, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        WebPane.limit(configuration)
        let view = KeyedWebView(frame: .zero, configuration: configuration)
        view.keys = keys
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        // A force click's preview would load a link outside these rules.
        view.allowsLinkPreview = false
        view.load(page.request)
        return view
    }

    func updateNSView(_ view: KeyedWebView, context: Context) {}

    static func dismantleNSView(_ view: KeyedWebView, coordinator: Coordinator) {
        view.keys = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let page: OrgPageRequest
        private let open: OpenURLAction
        private let failed: () -> Void
        private var crashes = CrashReload()

        init(page: OrgPageRequest, open: OpenURLAction, failed: @escaping () -> Void) {
            self.page = page
            self.open = open
            self.failed = failed
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            StrutPage.policy(for: action, in: webView, serves: page.serves, open: open, downloads: false)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if response.isForMainFrame, let status = (response.response as? HTTPURLResponse)?.statusCode,
               OrgPageRules.failure(status: status) != nil {
                failed()
                return .cancel
            }
            return StrutPage.policy(for: response, downloads: false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            let error = error as NSError
            // A load cancelled here, or refused above.
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
            failed()
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            StrutPage.newWindow(for: action, from: webView, box: page, open: open)
            return nil
        }

        /// Loaded again once, with its token, at the view it was on; a page
        /// that ends again within a minute leaves the video.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if crashes.again() { webView.load(page.request(at: webView.url) ?? page.request) } else { failed() }
        }

        func webView(
            _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
            initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
        ) async -> WKPermissionDecision {
            .deny
        }
    }
}

/// A box's page in place (`BoxPageView`) that says when it has the keyboard.
final class KeyedWebView: InputWebView {
    var keys: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { keys?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keys?(false) }
        return resigned
    }
}
