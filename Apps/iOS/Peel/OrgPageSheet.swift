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
    let page: OrgPageRequest
    @Environment(\.dismiss) private var dismiss
    @State private var controller = OrgPageController()

    var body: some View {
        NavigationStack {
            OrgWebView(page: page, controller: controller)
                .overlay(alignment: .top) {
                    if controller.isLoading {
                        ProgressView(value: controller.progress)
                            .progressViewStyle(.linear)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if let problem = controller.problem {
                        ContentUnavailableView {
                            Label("Couldn't open it", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(problem)
                        } actions: {
                            Button("Try again") { controller.retry(page.request) }
                        }
                        .background(Theme.background)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.workspace)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if controller.canGoBack {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back", systemImage: "chevron.backward") { controller.goBack() }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reload", systemImage: "arrow.clockwise") { controller.reload(page.request) }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .sheet(item: $controller.shared) { file in
            ShareSheet(url: file.url).ignoresSafeArea()
        }
        .alert("Couldn't save it", isPresented: Binding(
            get: { controller.notice != nil }, set: { if !$0 { controller.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.notice ?? "")
        }
    }
}

/// A file a page's own download saved, to hand to the share sheet.
private struct OrgPageSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The iOS share sheet for one file.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// What the sheet shows of its web view: whether it can go back, is loading
/// (and how far), why a page did not open, and a download to share. Holds the
/// web view weakly and sees it by KVO; owns the temporary folders downloads
/// are saved in and removes them with the sheet.
@MainActor @Observable
private final class OrgPageController {
    var canGoBack = false
    var isLoading = false
    var progress = 0.0
    /// Why the page did not open, in the person's words; nil when it did.
    var problem: String?
    /// A download that finished, for the share sheet.
    var shared: OrgPageSharedFile?
    /// A download that failed.
    var notice: String?

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var folders: [URL] = []

    /// Where downloads wait, each in a folder of its own.
    static let downloadsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Peel Org Downloads", isDirectory: true)

    func attach(_ webView: WKWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.sync() }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.sync() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.sync() }
            },
        ]
    }

    private func sync() {
        guard let webView else { return }
        canGoBack = webView.canGoBack
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
    }

    func goBack() { webView?.goBack() }

    /// Loads it again: the page's own request (with its bearer) while on its
    /// first address or none, else where the person went.
    func reload(_ request: URLRequest) {
        guard let webView else { return }
        problem = nil
        if let url = webView.url, url != request.url { webView.reload() } else { webView.load(request) }
    }

    func retry(_ request: URLRequest) {
        problem = nil
        webView?.load(request)
    }

    /// A folder for one download, readable only by this user.
    func newFolder() -> URL? {
        guard let folder = try? IncomingFiles.newFolder(in: Self.downloadsRoot) else { return nil }
        folders.append(folder)
        return folder
    }

    func remove(_ folder: URL) {
        folders.removeAll { $0 == folder }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The sheet is gone: nothing is kept.
    func cleanUp() {
        observations = []
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }
}

/// The web view of an `OrgPageSheet`: a store that keeps nothing, the
/// token's hand-over script, and a navigation policy that keeps it on the
/// org's strut (`Coordinator`).
private struct OrgWebView: UIViewRepresentable {
    let page: OrgPageRequest
    let controller: OrgPageController

    func makeCoordinator() -> Coordinator { Coordinator(page: page, controller: controller) }

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
        controller.attach(webView)
        webView.load(page.request)
        return webView
    }

    func updateUIView(_ webView: TouchWebView, context: Context) {}

    static func dismantleUIView(_ webView: TouchWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
        coordinator.finish()
    }

    /// Where the page may go: anywhere in the org's strut's UI; its own
    /// frames (`srcdoc`, and a data or blob frame, never as the whole page);
    /// a link elsewhere out to the system, only from strut's own page (never
    /// from a frame in it, which is the org's or an agent's) and only on the
    /// person's own tap; a download only of strut's own page, never of a
    /// frame in it (`OrgPageRules.mayDownload`), saved in a folder of its own
    /// and handed to the share sheet; and no other scheme.
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let page: OrgPageRequest
        private let controller: OrgPageController
        /// Downloads under way and the folder each saves in.
        private var downloads: [ObjectIdentifier: (download: WKDownload, folder: URL, file: URL?)] = [:]

        init(page: OrgPageRequest, controller: OrgPageController) {
            self.page = page
            self.controller = controller
        }

        /// The sheet is going: downloads stop and their folders go.
        func finish() {
            for entry in downloads.values { entry.download.cancel(nil) }
            downloads = [:]
            controller.cleanUp()
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            (policy(for: action, in: webView), preferences)
        }

        private func policy(for action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
            guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
            if action.shouldPerformDownload {
                return OrgPageRules.mayDownload(
                    isMainFrame: action.targetFrame?.isMainFrame ?? false,
                    sourceIsMainFrame: action.sourceFrame.isMainFrame,
                    served: page.serves(url)) ? .download : .cancel
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
            let http = response.response as? HTTPURLResponse
            if response.isForMainFrame, let problem = http.flatMap({ OrgPageRules.failure(status: $0.statusCode) }) {
                controller.problem = problem
                return .cancel
            }
            let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?
                .trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
            if attachment || !response.canShowMIMEType {
                // The response carries no source frame: a main-frame response
                // is strut's own page's, whose navigation was allowed above.
                let served = response.response.url.map(page.serves) ?? false
                return OrgPageRules.mayDownload(
                    isMainFrame: response.isForMainFrame, sourceIsMainFrame: response.isForMainFrame, served: served)
                    ? .download : .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.problem = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            let error = error as NSError
            // A load we cancelled, or turned into a download or a refusal.
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
            controller.problem = error.localizedDescription
        }

        // MARK: Downloads

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            guard let folder = controller.newFolder() else {
                controller.notice = "There was no room to keep it."
                return nil
            }
            let file = folder.appendingPathComponent(OrgPageRules.filename(suggestedFilename), isDirectory: false)
            downloads[ObjectIdentifier(download)] = (download, folder, file)
            return file
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)), let file = entry.file else { return }
            controller.shared = OrgPageSharedFile(url: file)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) { controller.remove(entry.folder) }
            if (error as NSError).code == NSURLErrorCancelled { return }
            controller.notice = "The download did not finish."
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
