import AppKit
import SwiftUI
import WebKit
import PeelCore

/// The web pane: a link from a message, or a tribe's app or second brain,
/// opens beside the chat rather than in the browser, like the browser pane
/// in the Claude desktop app (design README, "Web pane"). One page at a
/// time; the next link replaces it. It stays open across chats until closed,
/// and closing it ends the page.
///
/// A page is only a page: no `sphinx` bridge, no message handlers and no
/// injected scripts. Website data lives in one store per profile
/// (`WebPage.storeIdentifier`), never the shared default one.
@MainActor @Observable
final class WebPane: NSObject {
    /// Open, with a page or (from the header's Browser) only its address field.
    private(set) var isOpen = false
    /// Nil until the first page loads; made again after a close, with the
    /// same store, so sign-ins survive.
    private(set) var webView: PaneWebView?
    /// What the toolbar shows, read off the web view as it changes.
    private(set) var page = Page()
    /// Why the last page did not load, until the next one does.
    private(set) var problem: Problem?
    /// The last download, until dismissed.
    var download: Download?

    struct Page: Equatable {
        var url: URL?
        var title = ""
        var canGoBack = false
        var canGoForward = false
        var isLoading = false
        var progress = 0.0
        var hasOnlySecureContent = false

        /// https with nothing on the page fetched over plain http.
        var isSecure: Bool { url?.scheme?.lowercased() == "https" && hasOnlySecureContent }
    }

    struct Problem: Equatable {
        /// The address that failed, which the pane is no longer showing; nil
        /// for an address Peel would not open, which has nothing to try again.
        let url: URL?
        let message: String
    }

    enum Download: Equatable {
        case saving(String)
        case saved(URL)
        case failed(String, reason: String)
    }

    /// Every link SwiftUI opens in the main window (`opensLinksInWebPane`):
    /// an http or https page comes here, or goes to the default browser with
    /// ⌘ held; any other scheme keeps the system's handling. Made once, so
    /// the views that read it are not invalidated by a new closure.
    @ObservationIgnored private(set) lazy var linkAction = OpenURLAction { [weak self] url in
        guard let self, let page = WebPage.address(url), !NSEvent.modifierFlags.contains(.command) else {
            return .systemAction
        }
        withAnimation(.easeOut(duration: 0.2)) { open(page) }
        return .handled
    }

    @ObservationIgnored private let profile: Profile?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Downloads in flight: where WebKit writes each, and the name the server gave.
    @ObservationIgnored private var downloads: [ObjectIdentifier: (file: URL, name: String)] = [:]
    /// When the page's web content process last ended under it.
    @ObservationIgnored private var lastTermination: ContinuousClock.Instant?

    init(profile: Profile?) {
        self.profile = profile
    }

    // MARK: Opening and closing

    /// Opens `url` in the pane, replacing what it showed. Only what
    /// `WebPage.address` accepts; the caller sends anything else elsewhere.
    func open(_ url: URL) {
        guard let url = WebPage.address(url) else { return }
        let view = webView ?? makeWebView()
        isOpen = true
        problem = nil
        view.load(URLRequest(url: url))
    }

    /// The header's Browser: the page as it is, or the pane with only its
    /// address field, which then has the keyboard.
    func show() {
        isOpen = true
    }

    /// What was typed into the address field and Return pressed: a web
    /// address or a search (`WebPage.typed`); anything else is refused in
    /// the page's place. The page then has the keyboard.
    func go(to typed: String) {
        guard let url = WebPage.typed(typed) else {
            problem = Problem(url: nil, message: "Peel opens web addresses here: http and https only.")
            return
        }
        open(url)
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    /// Closes the pane and ends its page, media and all.
    func close() {
        isOpen = false
        problem = nil
        download = nil
        page = Page()
        guard let view = webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        observations = []
        webView = nil
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reloadOrStop() {
        guard let webView else { return }
        if page.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    /// Loads the address that failed again.
    func retry() {
        guard let failed = problem?.url else { return reloadOrStop() }
        open(failed)
    }

    // MARK: Website data

    /// Signs out of every site opened in the pane on this profile and
    /// clears their cookies, storage and cache. An open page is loaded again.
    func clearWebsiteData() async {
        guard let store = webView?.configuration.websiteDataStore ?? storeID(create: false).map(WKWebsiteDataStore.init)
        else { return }
        await Self.removeAllData(from: store)
        webView?.reload()
    }

    /// Before the profile itself is removed: closes the pane, clears the
    /// store's data, then removes the store. WebKit refuses the removal
    /// while a web content process still holds the store; its emptied
    /// folder is then left behind, with nothing in it to sign anyone in.
    func forgetWebsiteData() async {
        close()
        guard let id = storeID(create: false) else { return }
        await Self.removeAllData(from: WKWebsiteDataStore(forIdentifier: id))
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    /// This profile's store identifier; with `create`, made on first use.
    private func storeID(create: Bool) -> UUID? {
        profile.flatMap { try? WebPage.storeIdentifier(in: $0.directory, create: create) }
    }

    private static func removeAllData(from store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func makeWebView() -> PaneWebView {
        let configuration = WKWebViewConfiguration()
        // Without a profile folder, a store that keeps nothing: never the
        // default store other apps' pages and other profiles would share.
        configuration.websiteDataStore = storeID(create: true).map(WKWebsiteDataStore.init) ?? .nonPersistent()
        // No message handlers, no user scripts: the controller stays empty.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // As in Safari: video plays, but nothing starts making sound until clicked.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        let view = PaneWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.close = { [weak self] in self?.close() }
        func watch<Value>(_ keyPath: KeyPath<PaneWebView, Value>) -> NSKeyValueObservation {
            view.observe(keyPath) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } }
        }
        observations = [
            watch(\.url), watch(\.title), watch(\.canGoBack), watch(\.canGoForward),
            watch(\.isLoading), watch(\.estimatedProgress), watch(\.hasOnlySecureContent),
        ]
        webView = view
        return view
    }

    /// Reads the page's state off the web view; writes only a change.
    /// While a load is under way `webView.url` already names where it is
    /// going, though the old page is still on screen and in use: a page
    /// could start a load that never arrives and wear another site's host.
    /// So the address changes only once the new page commits (`committed`),
    /// or while nothing is loading (a page's own history changes); the
    /// first load, which Peel started, shows where it goes.
    private func sync(committed: Bool = false) {
        guard let webView else { return }
        let url = committed || !webView.isLoading || page.url == nil ? webView.url ?? page.url : page.url
        let new = Page(
            url: url, title: webView.title ?? "",
            canGoBack: webView.canGoBack, canGoForward: webView.canGoForward,
            isLoading: webView.isLoading, progress: webView.estimatedProgress,
            hasOnlySecureContent: webView.hasOnlySecureContent
        )
        if new != page { page = new }
    }

    /// Where downloads wait until they are finished and put in Downloads.
    private static let downloadsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Peel Web Downloads", isDirectory: true)
}

// MARK: - What a page may do

extension WebPane: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch scheme {
        case "http", "https":
            // ⌘-click goes to the browser, as from a message.
            if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
                if WebPage.address(url) != nil { NSWorkspace.shared.open(url) }
                return .cancel
            }
            // The page the pane shows names its host plainly: no `user@host`.
            return !mainFrame || WebPage.address(url) != nil ? .allow : .cancel
        case "about":
            return .allow
        case "data", "blob":
            // A whole page from one of these has no host of its own to show.
            return mainFrame ? .cancel : .allow
        default:
            // file:, sphinx.chat:, mailto: and every app's scheme: not from a page.
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let attachment = disposition?.lowercased().hasPrefix("attachment") == true
        return response.isForMainFrame && (attachment || !response.canShowMIMEType) ? .download : .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        problem = nil
        sync(committed: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    /// A load that was stopped, or that the policies above refused or made
    /// a download, is not a failure.
    private func failed(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == WebKitErrorDomain, error.code == WebKitErrorFrameLoadInterruptedByPolicyChange { return }
        problem = Problem(url: error.userInfo[NSURLErrorFailingURLErrorKey] as? URL, message: error.localizedDescription)
    }

    /// Loads the page again, once: a page that brings its process down
    /// again within a minute is left on its problem rather than reloaded
    /// for as long as the pane is open.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = ContinuousClock.now
        defer { lastTermination = now }
        if let last = lastTermination, now - last < .seconds(60) {
            problem = Problem(url: webView.url ?? page.url, message: "The page stopped working.")
            return
        }
        webView.reload()
    }

    /// `target=_blank` and `window.open`: the pane is the one window.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, WebPage.address(url) != nil {
            webView.load(action.request)
        }
        return nil
    }

    /// No camera or microphone in v1.
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - Downloads

/// WebKit writes a download into a private folder of Peel's; once finished
/// it goes into Downloads like a saved attachment (`UserFiles.save`:
/// a clean name, quarantined) and the folder is removed.
extension WebPane: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let folder = try? IncomingFiles.newFolder(in: Self.downloadsRoot) else {
            self.download = .failed(suggestedFilename, reason: "Peel could not make a folder for it")
            return nil
        }
        let file = folder.appendingPathComponent("download", isDirectory: false)
        downloads[ObjectIdentifier(download)] = (file, suggestedFilename)
        self.download = .saving(suggestedFilename)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        take(download) { file, name in
            do {
                self.download = .saved(try await UserFiles.saveToDownloads(file, named: name))
            } catch {
                self.download = .failed(name, reason: PeelError.readable(error))
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        take(download) { _, name in self.download = .failed(name, reason: error.localizedDescription) }
    }

    /// The download's entry, removed; its private copy goes once `body` is
    /// done (the copy into Downloads runs off the main thread).
    private func take(_ download: WKDownload, _ body: @escaping (_ file: URL, _ name: String) async -> Void) {
        guard let (file, name) = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Task {
            await body(file, name)
            IncomingFiles.discard(file, root: Self.downloadsRoot)
        }
    }
}

/// The pane's web view: ⌘W closes the pane, not the window, while the page
/// has the keyboard.
final class PaneWebView: WKWebView {
    var close: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "w",
           let focused = window?.firstResponder as? NSView, focused.isDescendant(of: self) {
            close?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Routing links

extension View {
    /// Every link SwiftUI opens below this view goes through the pane's
    /// router (`WebPane.linkAction`).
    func opensLinksInWebPane(_ pane: WebPane) -> some View {
        environment(\.openURL, pane.linkAction)
    }
}

/// The first items of a chat header's More menu: Browser, which shows the
/// pane (its page, or an empty address field), then a tribe's second brain
/// and web app, each only when the tribe has one (stored only when
/// `WebPage.address` took it). `open` is the window's link router, as for a
/// message link, so they open in the pane.
@MainActor
enum WebMenuEntries {
    static func entries(for tribe: Tribe?, pane: WebPane, open: OpenURLAction) -> [MenuEntry] {
        let browser = MenuEntry.button("Browser", systemImage: "globe") {
            withAnimation(.easeOut(duration: 0.2)) { pane.show() }
        }
        let pages: [(String, String, String?)] = [
            ("Second brain", "brain", tribe?.secondBrainURL), ("Tribe app", "square.grid.2x2", tribe?.appURL),
        ]
        return [browser] + pages.compactMap { title, image, address in
            guard let url = address.flatMap(URL.init(string:)) else { return nil }
            return .item(MenuItem(title: title, systemImage: image, detailSystemImage: "arrow.up.right") {
                open(url)
                return true
            })
        }
    }
}

// MARK: - Layout

extension View {
    /// This view (the detail column) with the web pane beside it while open.
    func webPaneBeside(_ pane: WebPane) -> some View {
        modifier(WebSplit(pane: pane))
    }
}

/// The detail column with the web pane beside it, resizable on its
/// divider. On a window too narrow for both, the pane takes the column's
/// place rather than covering it. The pane lives as long as the main
/// window shows the account: closing the window or locking Peel (which
/// replaces this view) ends the page.
private struct WebSplit: ViewModifier {
    @Environment(AppModel.self) private var model
    let pane: WebPane
    /// Dragged on its divider; remembered on this Mac (a convenience).
    @AppStorage("webPaneWidth") private var paneWidth: Double = WebPaneView.width

    private static var paneRange: ClosedRange<Double> { 360...1100 }

    /// The narrowest the detail column gets beside the pane: a chat, or
    /// Payments with its own pane open beside its list.
    private var minimumDetail: CGFloat { model.destination == .payments ? 760 : 400 }

    func body(content detail: Content) -> some View {
        SidePanelSplit(isOpen: pane.isOpen, width: $paneWidth, range: Self.paneRange,
                       standard: WebPaneView.width, minimumMain: minimumDetail) {
            detail
        } panel: { _ in
            WebPaneView(pane: pane)
        }
        .onDisappear { pane.close() }
    }
}

// MARK: - The pane

struct WebPaneView: View {
    static let width = 560.0
    let pane: WebPane

    var body: some View {
        VStack(spacing: 0) {
            WebToolbar(pane: pane)
            ZStack {
                Theme.background
                if let webView = pane.webView {
                    WebViewHost(webView: webView)
                }
                if let problem = pane.problem {
                    LoadProblem(host: problem.url?.host, problem: problem.message,
                                retry: problem.url == nil ? nil : { pane.retry() })
                }
            }
            if let download = pane.download {
                DownloadBar(download: download) { pane.download = nil }
            }
        }
        .background(Theme.background)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: PaneWebView

    func makeNSView(context: Context) -> PaneWebView { webView }
    func updateNSView(_ view: PaneWebView, context: Context) {}
}

/// Back, forward, reload; the address field; then Open in default browser,
/// More (⋮) and close.
private struct WebToolbar: View {
    let pane: WebPane

    var body: some View {
        let page = pane.page
        HStack(spacing: 2) {
            ToolbarIcon(systemImage: "arrow.left", help: "Back", enabled: page.canGoBack) { pane.goBack() }
            ToolbarIcon(systemImage: "arrow.right", help: "Forward", enabled: page.canGoForward) { pane.goForward() }
            ToolbarIcon(
                systemImage: page.isLoading ? "xmark" : "arrow.clockwise",
                help: page.isLoading ? "Stop" : "Reload", enabled: pane.webView != nil
            ) { pane.reloadOrStop() }
            AddressField(pane: pane)
                .padding(.horizontal, 6)
            ToolbarIcon(systemImage: "arrow.up.right.square", help: "Open in default browser", enabled: page.url != nil) {
                if let url = page.url { NSWorkspace.shared.open(url) }
            }
            MoreMenu(pane: pane, url: page.url)
            ToolbarIcon(systemImage: "xmark", help: "Close (⌘W)") {
                withAnimation(.easeIn(duration: 0.15)) { pane.close() }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Theme.divider.frame(height: 1)
                if page.isLoading {
                    GeometryReader { geometry in
                        Theme.accent
                            .frame(width: geometry.size.width * max(0.05, page.progress), height: 2)
                    }
                    .frame(height: 2)
                    .animation(.linear(duration: 0.2), value: page.progress)
                }
            }
        }
    }
}

/// The full address of the page on screen: the lock, or "Not secure", then
/// the address with its host (in its `xn--` form) in full colour. The
/// address changes when the next page arrives, not when it is asked for
/// (`WebPane.sync`). A click edits it; Return loads what was typed, Escape
/// puts the address back, ⌘W closes the pane; with no page the field has
/// the keyboard.
private struct AddressField: View {
    let pane: WebPane

    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var hovering = false

    var body: some View {
        let page = pane.page
        HStack(spacing: 6) {
            if !focused, page.url != nil {
                SecurityMark(isSecure: page.isSecure)
            }
            ZStack(alignment: .leading) {
                TextField("", text: $draft, prompt: page.url == nil ? Text("Type a URL").foregroundStyle(Theme.tertiaryText) : nil)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .focused($focused)
                    .accessibilityLabel("Address")
                    .onSubmit {
                        pane.go(to: draft)
                        if pane.problem == nil { focused = false }
                    }
                    .onExitCommand { draft = page.url?.absoluteString ?? "" }
                if !focused, let url = page.url {
                    AddressText(url: url)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .modifier(FieldChrome(focused: focused, hovering: hovering))
        .onHover { hovering = $0 }
        .help(page.url?.absoluteString ?? "")
        // ⌘W in the field closes the pane, as from the page.
        .hiddenShortcut(KeyboardShortcut("w", modifiers: .command), enabled: focused) { pane.close() }
        .onChange(of: focused) { _, now in
            guard now else { return draft = "" }
            draft = pane.page.url?.absoluteString ?? ""
            // As in a browser, the whole address is selected to type over.
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        .task {
            // Opened from Browser with no page: straight to typing.
            if pane.webView == nil { focused = true }
        }
    }
}

/// A small lock for https with nothing insecure on the page; "Not secure"
/// in amber otherwise (attention, not red: nothing is broken).
private struct SecurityMark: View {
    let isSecure: Bool

    var body: some View {
        if isSecure {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Secure")
        } else {
            HStack(spacing: 6) {
                Text("Not secure")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.attention)
                    .fixedSize()
                Theme.divider.frame(width: 1, height: 14)
            }
        }
    }
}

/// The address with its host in full colour and the rest quieter, so the
/// site is the part that reads first. The path gives way first; a host too
/// long for the field loses its start, never its end, so
/// `google.com.sign-in.evil.example` cannot hide `evil.example`.
private struct AddressText: View {
    let url: URL

    var body: some View {
        let parts = Self.parts(of: url.absoluteString)
        HStack(spacing: 0) {
            Text(parts.lead)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            Text(parts.host)
                .truncationMode(.head)
                .layoutPriority(1)
            Text(parts.rest)
                .foregroundStyle(Theme.secondaryText)
                .truncationMode(.tail)
        }
        .font(Theme.font(13))
        .lineLimit(1)
    }

    /// `https://`, `host:port`, then the path, query and fragment; an
    /// address without `://` (`about:blank`) is all `rest`.
    static func parts(of address: String) -> (lead: Substring, host: Substring, rest: Substring) {
        guard let scheme = address.range(of: "://") else { return ("", "", address[...]) }
        let after = address[scheme.upperBound...]
        let end = after.firstIndex { "/?#".contains($0) } ?? after.endIndex
        return (address[..<scheme.upperBound], after[..<end], after[end...])
    }
}

/// ⋮: Copy link and Open in default browser for the page, and Clear
/// website data (asked once more in place).
private struct MoreMenu: View {
    let pane: WebPane
    let url: URL?

    var body: some View {
        MenuButton(help: "More", source: "web-more", entries: entries) {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90))
        }
    }

    private func entries() -> [MenuEntry] {
        let page: [MenuEntry] = url.map { url in
            [.copy("Copy link", text: url.absoluteString, systemImage: "link"),
             .button("Open in default browser", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }]
        } ?? []
        let pane = pane
        return .sections(
            page,
            [.destructive("Clear website data", systemImage: "trash", confirm: "Sign out of every site?") {
                Task {
                    await pane.clearWebsiteData()
                    CopyFeedback.announce("Website data cleared")
                }
            }]
        )
    }
}

private struct ToolbarIcon: View {
    let systemImage: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        HoverIconButton(systemImage: systemImage, help: help, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}

private struct LoadProblem: View {
    let host: String?
    let problem: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text("Couldn't open \(host ?? "that address")")
                .font(Theme.font(15, .semibold))
            Text(problem)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// A download under way or saved; a failure is the usual `NoticeBar`.
private struct DownloadBar: View {
    @Environment(AppModel.self) private var model
    let download: WebPane.Download
    let dismiss: () -> Void

    var body: some View {
        switch download {
        case .saving(let name):
            bar {
                ProgressView().controlSize(.small)
                Text("Downloading \(name)…")
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        case .saved(let file):
            bar {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.confirmed)
                Text("Saved \(file.lastPathComponent) to Downloads")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Show in Finder") { model.showInFinder(file) }
                    .buttonStyle(GhostButtonStyle())
            }
        case .failed(let name, let reason):
            NoticeBar(text: "Could not download \(name): \(reason)", dismiss: dismiss)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.panel)
                .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 8)
            HoverIconButton(systemImage: "xmark", help: "Dismiss", action: dismiss)
        }
        .font(Theme.font(12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }
}
