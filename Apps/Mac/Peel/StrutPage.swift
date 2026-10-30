import AppKit
import PeelAgent
import PeelCore
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
        if action.shouldPerformDownload { return downloads && action.sourceFrame.isMainFrame ? .download : .cancel }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if server.serves(url) { return .allow }
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
    @MainActor func policy(for response: WKNavigationResponse, downloads: Bool) -> WKNavigationResponsePolicy {
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
            follow(url, from: webView, open: open)
        } else if server.servesPage(url) {
            if Self.personActed(in: webView), let shown = shownApp, let link = server.appLink(url, from: shown.peer) { openApp(link) }
        } else if let download, Self.personActed(in: webView) {
            download(action.request)
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
    @MainActor private func follow(_ url: URL, from webView: WKWebView, open: OpenURLAction) {
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
