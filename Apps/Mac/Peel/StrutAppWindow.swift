import AppKit
import PeelAgent
import PeelCore
import SwiftUI
import WebKit

/// A Strut app in a window of its own, at the screen's size, so the person
/// need not go back and forth between the app and the conversation. Same rules as `AppPage`: a store that keeps nothing, `WebPane.limit`. Opening the same app again brings its window forward. Never described with its address, which holds strut's key.
@MainActor
final class StrutAppWindows {
    static let shared = StrutAppWindows()

    private var open: [String: Entry] = [:]

    private struct Entry {
        let window: NSWindow
        let coordinator: AppPage.Coordinator
        let view: InputWebView
        let closing: NSObjectProtocol
    }

    func show(_ page: StrutPage, link: OpenURLAction, openApp: @escaping (StrutAppLink) -> Void) {
        let key = page.shownApp.map { "\($0.peer ?? "")/\($0.app?.name ?? page.name)" } ?? page.name
        if let existing = open[key] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        WebPane.limit(configuration)
        let coordinator = AppPage.Coordinator(page: page, open: link, moved: { _ in }, openApp: openApp)
        let view = InputWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsLinkPreview = false
        coordinator.watch(view)
        view.load(URLRequest(url: page.url))

        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = page.name
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = view
        window.setFrame(frame, display: true)
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(key) }
        }
        open[key] = Entry(window: window, coordinator: coordinator, view: view, closing: closing)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    private func closed(_ key: String) {
        guard let entry = open.removeValue(forKey: key) else { return }
        NotificationCenter.default.removeObserver(entry.closing)
        entry.view.stopLoading()
        entry.view.navigationDelegate = nil
        entry.view.uiDelegate = nil
    }
}
