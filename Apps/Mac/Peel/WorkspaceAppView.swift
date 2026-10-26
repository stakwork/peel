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
            DetailHeader(title: app.title, subtitle: app.caption(showsWorkspace: model.showsAppWorkspaces)) {
                WorkspaceApp.headerIcon(app.iconSymbol)
            } trailing: {
                AppStatus(app: app)
                AppPinButton(app: app)
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
    /// Apps' icon, and an app's whose manifest names none Peel knows.
    static let symbol = "square.grid.2x2"

    /// A header's icon: Apps' and an app's.
    static func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: Theme.AvatarSize.lg, height: Theme.AvatarSize.lg)
    }

    /// Its icon: the manifest's lucide name as the SF Symbol closest to it,
    /// or Apps' grid for one not here or this macOS lacks.
    var iconSymbol: String {
        guard let icon, let symbol = Self.symbols[icon], Self.available.contains(symbol) else { return Self.symbol }
        return symbol
    }

    /// The table's symbols this macOS has, found once.
    private static let available = Set(symbols.values.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    })

    /// Under its title and at its card's foot: `@workspace · v14`, the
    /// workspace when asked (`AppModel.showsAppWorkspaces`).
    func caption(showsWorkspace: Bool) -> String? {
        let parts = [showsWorkspace ? "@\(peer)" : nil, version].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The lucide names an app's manifest most often gives, as SF Symbols.
    /// `layout-dashboard`, the starter template's, stays the grid.
    private static let symbols: [String: String] = [
        "activity": "waveform.path.ecg", "alarm-clock": "alarm", "bar-chart": "chart.bar",
        "bar-chart-3": "chart.bar", "bell": "bell", "book": "book", "book-open": "book",
        "brain": "brain", "briefcase": "briefcase", "building": "building.2", "building-2": "building.2",
        "calendar": "calendar", "camera": "camera", "chart-bar": "chart.bar", "chart-column": "chart.bar",
        "chart-line": "chart.line.uptrend.xyaxis", "chart-pie": "chart.pie", "check-square": "checkmark.square",
        "circle-dollar-sign": "dollarsign.circle", "clock": "clock", "code": "chevron.left.forwardslash.chevron.right",
        "cpu": "cpu", "credit-card": "creditcard", "database": "cylinder.split.1x2", "dollar-sign": "dollarsign.circle",
        "eye": "eye", "file": "doc", "file-text": "doc.text", "flag": "flag", "flask-conical": "flask",
        "flask-round": "flask", "folder": "folder", "gauge": "gauge.with.dots.needle.33percent",
        "git-branch": "arrow.triangle.branch", "globe": "globe", "graduation-cap": "graduationcap",
        "heart": "heart", "home": "house", "house": "house", "image": "photo", "inbox": "tray",
        "kanban": "rectangle.split.3x1", "layers": "square.stack.3d.up", "lightbulb": "lightbulb",
        "line-chart": "chart.line.uptrend.xyaxis", "list": "list.bullet", "list-checks": "checklist",
        "list-todo": "checklist", "lock": "lock", "mail": "envelope", "map": "map", "map-pin": "mappin",
        "message-circle": "bubble.left", "message-square": "bubble.left", "music": "music.note",
        "network": "point.3.connected.trianglepath.dotted", "newspaper": "newspaper", "package": "shippingbox",
        "palette": "paintpalette", "pen": "pencil", "pencil": "pencil", "pie-chart": "chart.pie",
        "puzzle": "puzzlepiece", "receipt": "receipt", "scale": "scalemass", "search": "magnifyingglass",
        "server": "server.rack", "settings": "gearshape", "shield": "shield", "shield-check": "checkmark.shield",
        "shopping-cart": "cart", "sparkles": "sparkles", "square-check": "checkmark.square", "star": "star",
        "table": "tablecells", "tag": "tag", "target": "target", "terminal": "terminal",
        "test-tube": "testtube.2", "trending-up": "chart.line.uptrend.xyaxis", "trophy": "trophy",
        "truck": "truck.box", "user": "person", "users": "person.2", "utensils": "fork.knife",
        "wallet": "wallet.pass", "workflow": "point.3.connected.trianglepath.dotted", "zap": "bolt",
    ]

    /// `apps` A–Z by title, as the sidebar and Apps list them.
    static func byTitle(_ apps: [WorkspaceApp]) -> [WorkspaceApp] {
        apps.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Whether a search for `query` finds it: in its title, what it is for,
    /// or `@workspace`.
    func matches(_ query: String) -> Bool {
        [title, about ?? "", "@\(peer)"].contains { ChatSections.matches($0, query: query) }
    }
}

/// What an app's page needs looked at, else the release its workspace holds
/// it at: one of them, on its card and in its header.
struct AppStatus: View {
    let app: WorkspaceApp

    var body: some View {
        if app.problems > 0 {
            HStack(spacing: 5) {
                OnlineDot(color: Theme.attention)
                Text(Formatting.count(app.problems, "problem"))
            }
            .font(Theme.font(12))
            .foregroundStyle(Theme.attention)
            .help("Strut's monitor flagged how its page uses the workspace")
        } else if let release = app.release {
            Chip("Release \(release)")
                .fixedSize()
                .help("Its workspace holds it at release \(release) while newer versions wait")
        }
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
