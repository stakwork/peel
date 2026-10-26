import PeelCore
import PeelUI
import SwiftUI
import UIKit
import WebKit

/// A deliverable from the agent's DM on its org's own strut: that strut's
/// UI showing the file or the app alone (`OrgPage`), with the person's token
/// for the org handed over twice and never in an address (strut's
/// specs/DESKTOP.md, "A device with no strut of its own"): as the first
/// request's bearer, which a swarm's gate wants for the page itself, and in
/// the page's own storage before its script runs, where strut's UI keeps the
/// key it sends on every call. The web view keeps nothing and goes nowhere
/// but that strut's UI (its folder on the host: a swarm's `/lab/`, which
/// shares its host with other services). The Mac's twin is `StrutPage`, on
/// its own strut.
struct OrgPageSheet: View {
    let page: Page
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OrgWebView(page: page)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(page.workspace)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }

    /// What the sheet opens. Never described with its token.
    struct Page: Identifiable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let id = UUID()
        /// The org's UI showing it alone; no credential in it.
        let url: URL
        /// The person's token for the org: never shown, logged or kept.
        let token: String
        /// The org as the person reads it.
        let workspace: String

        var description: String { "org page on \(workspace)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["workspace": workspace]) }

        /// `url`'s origin as a page reads it (`location.origin`): the
        /// scheme, the host in lower case, and a port only when not the
        /// scheme's own.
        var origin: String { Self.origin(of: url) ?? "" }

        static func origin(of url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
            return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
        }

        /// The folder strut's UI is served from (`/`, or a swarm's `/lab/`):
        /// `url`'s path, which `StrutUI.page` ends with its `/`.
        var folder: String { url.path(percentEncoded: true) }

        /// Whether `other` is strut's: on `url`'s origin, in its UI's folder.
        func serves(_ other: URL) -> Bool {
            Self.origin(of: other) == origin && other.path(percentEncoded: true).hasPrefix(folder)
        }

        /// The request that loads it: the token as its bearer.
        var request: URLRequest {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        /// The script that hands the token to strut's UI (its `strut/apiKey`
        /// in `sessionStorage`), run before the page's own and only in its
        /// folder on the org's origin. The strings as JSON literals.
        var handOver: String {
            let literals = (try? JSONEncoder.literals.encode([origin, folder, token])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            return """
            (() => { const [origin, folder, key] = \(literals);
              if (location.origin === origin && location.pathname.startsWith(folder)) {
                try { sessionStorage.setItem("strut/apiKey", key); } catch (e) {} } })();
            """
        }
    }
}

private extension JSONEncoder {
    /// Strings as a script reads them: no `/` escaped, so a `</script>` could never close anything (there is no tag).
    static var literals: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

/// The web view of an `OrgPageSheet`: a store that keeps nothing, the
/// token's hand-over script, and a navigation policy that keeps it on the
/// org's strut (`Coordinator`).
private struct OrgWebView: UIViewRepresentable {
    let page: OrgPageSheet.Page

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeUIView(context: Context) -> TouchWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: page.handOver, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = TouchWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        // Back from a file strut's viewer opened in place (`createWebViewWith`).
        webView.allowsBackForwardNavigationGestures = true
        webView.load(page.request)
        return webView
    }

    func updateUIView(_ webView: TouchWebView, context: Context) {}

    static func dismantleUIView(_ webView: TouchWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
    }

    /// Where the page may go: anywhere in the org's strut's UI; its own
    /// frames (`srcdoc`, and a data or blob frame, never as the whole page);
    /// a link elsewhere out to the system, only from strut's own page (never
    /// from a frame in it, which is the org's or an agent's) and only on the
    /// person's own tap; nothing downloaded, and no other scheme.
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let page: OrgPageSheet.Page

        init(page: OrgPageSheet.Page) {
            self.page = page
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            (policy(for: action, in: webView), preferences)
        }

        private func policy(for action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
            guard !action.shouldPerformDownload, let url = action.request.url, let scheme = url.scheme?.lowercased() else {
                return .cancel
            }
            let mainFrame = action.targetFrame?.isMainFrame ?? true
            if page.serves(url) { return .allow }
            switch scheme {
            case "about":
                // The page's own frame (`srcdoc`).
                return .allow
            case "data", "blob":
                return mainFrame ? .cancel : .allow
            case "http", "https":
                if action.navigationType == .linkActivated { follow(url, from: action, in: webView) }
                return .cancel
            default:
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .cancel
        }

        /// `target=_blank` and `window.open`: never a window. One on the org's
        /// strut (its viewer's "open in a new tab", for a file it has no view
        /// of) opens here, Back returning; a link elsewhere goes out as a
        /// link does.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            if page.serves(url) {
                if action.sourceFrame.isMainFrame { webView.load(URLRequest(url: url)) }
            } else {
                follow(url, from: action, in: webView)
            }
            return nil
        }

        /// The page's process ended (memory, a crash): loaded again, with its token.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(page.request)
        }

        /// Only from strut's own page and on the person's own tap: a script's
        /// `click()` is `linkActivated` too, and a frame holds what the org
        /// or an agent wrote.
        private func follow(_ url: URL, from action: WKNavigationAction, in webView: WKWebView) {
            guard action.sourceFrame.isMainFrame, (webView as? TouchWebView)?.personActed == true,
                  url.scheme == "https" || url.scheme == "http" else { return }
            UIApplication.shared.open(url)
        }
    }
}

/// A web view that knows when the person last touched it: touches UIKit
/// delivers, which no script on the page can make.
private final class TouchWebView: WKWebView {
    private var lastTouch: ContinuousClock.Instant?

    /// The person touched it within the last second.
    var personActed: Bool { lastTouch.map { .now - $0 < .seconds(1) } ?? false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches { lastTouch = .now }
        return super.hitTest(point, with: event)
    }
}
