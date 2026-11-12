import AppKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI
import WebKit

/// The app wallet's handler on a web view showing an app of Peel's own
/// strut (`StrutWallet`, docs/app-wallet.md): the one message handler a page
/// of Peel's has. It answers only the main frame at Peel's strut's origin,
/// and names the app from the web view's own address (what Peel opened,
/// `MemoryServer.appLink`), never from the message, which must agree; for
/// a stranger's public app the strut UI hosts (`MemoryServer.remoteApp`),
/// the seller and the app that address names, which a sign-in's challenge
/// must be for. A sheet opens over the web view's window, only right after
/// the person clicked or typed in it (`InputWebView.acted(within:)`).
/// Notifications for that app are pushed back into its main frame.
@MainActor
final class StrutWalletBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let server: MemoryServer
    private weak var model: AppModel?
    private weak var webView: InputWebView?
    private var listening: UUID?
    private let sheets = WalletSheetPresenter()

    private init(server: MemoryServer, model: AppModel) {
        self.server = server
        self.model = model
    }

    /// Adds the handler to a page's configuration, for a page that shows an
    /// app, its own strut's or a stranger's; nil (and no handler) for one
    /// that shows a file.
    static func install(in configuration: WKWebViewConfiguration, for page: StrutPage, model: AppModel?) -> StrutWalletBridge? {
        guard let model, page.shownApp?.app != nil || page.server.remoteApp(page.url) != nil else { return nil }
        let bridge = StrutWalletBridge(server: page.server, model: model)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: StrutWallet.handlerName)
        return bridge
    }

    /// The web view it serves, once made: its sheets go over its window,
    /// and its app's notifications to it.
    func attach(_ view: InputWebView) {
        webView = view
        sheets.webView = view
        // A yes given once Peel locked is a no: the account may not be the person's to spend now.
        sheets.stillOpen = { [weak model] in model?.phase == .ready }
        listening = model?.listenToWallet { [weak self] push in self?.push(push) }
    }

    /// The page is going: the handler and its sheet with it.
    func detach() {
        if let listening { model?.stopListening(listening) }
        listening = nil
        sheets.dismiss()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: StrutWallet.handlerName, contentWorld: .page
        )
        webView = nil
    }

    /// The app the web view shows, as Peel opened it, and where it lives
    /// as the person reads it.
    private var shown: (scope: WalletScope, place: String)? {
        guard let url = webView?.url else { return nil }
        if let remote = server.remoteApp(url) {
            let place = (Seller.host(of: remote.seller) ?? "") + remote.seller.path(percentEncoded: false)
            return (.remote(seller: remote.seller, name: remote.name), place)
        }
        guard let app = server.appLink(url, from: nil)?.app, let name = app.app?.name else { return nil }
        return (.app(peer: app.peer, name: name), app.peer.map { "@\($0)" } ?? WorkspaceApp.yours)
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard StrutWallet.mayAnswer(message.frameInfo, origin: server.base), let webView, message.webView === webView,
              let model, let shown, let body = StrutWallet.json(message.body) else {
            return (nil, StrutWallet.notAnswered)
        }
        let caller = WalletCaller(
            scope: shown.scope, place: shown.place, personActed: webView.acted(within: StrutWallet.gestureWindow),
            person: MacWalletPerson(sheets: sheets) { [weak model] words in
                (model?.mainPresenter as? MenuPresenter)?.showToast(words)
            }
        )
        let reply = await model.walletReply(to: body, from: caller)
        return (StrutWallet.foundation(reply), nil)
    }

    private func push(_ push: WalletPush) {
        guard let webView, let shown, push.connection == shown.scope.key else { return }
        StrutWallet.push(push.envelope, into: webView, origin: server.base)
    }
}

/// The person, on the Mac: the sheets over the app's window, and a toast
/// for what a connection did without one.
struct MacWalletPerson: WalletPerson {
    let sheets: WalletSheetPresenter
    let toast: @MainActor @Sendable (String) -> Void

    func connect(_ sheet: WalletConnectSheet) async -> WalletConnectAnswer? {
        await sheets.ask { done in WalletConnectSheetView(sheet: sheet, done: done) } ?? nil
    }

    func pay(_ sheet: WalletPaymentSheet) async -> Bool {
        await sheets.ask { done in WalletPaymentSheetView(sheet: sheet, done: done) } ?? false
    }

    func signedIn(to host: String, as key: SignInKey) async {
        await toast(WalletWords.signedIn(to: host, as: key))
    }
}

/// One sheet at a time over a web view's window, answered once: by the
/// person, or as a no when Peel stops waiting (the task cancelled, the page
/// gone), which takes it down.
@MainActor
final class WalletSheetPresenter {
    weak var webView: WKWebView?
    /// Whether an answer still counts when it is given (Peel unlocked).
    var stillOpen: () -> Bool = { true }
    private var open: (window: NSWindow, cancel: () -> Void)?

    /// The person's answer; nil when there is no window to ask in, or the
    /// sheet was taken down unanswered.
    func ask<T: Sendable, Content: View>(_ make: (@escaping @MainActor (T) -> Void) -> Content) async -> T? {
        guard open == nil, let parent = webView?.window, !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let once = Once(continuation)
                let host = NSHostingController(rootView: make { [weak self] answer in
                    let counts = self?.stillOpen() ?? false
                    self?.close()
                    once.resume(counts ? answer : nil)
                })
                let sheet = NSWindow(contentViewController: host)
                sheet.styleMask.remove(.resizable)
                // At the content's own size: left to the hosting view, the
                // sheet opens at the smallest height the content allows,
                // each fact squeezed to its least and its lines over the
                // next one's.
                sheet.setContentSize(host.sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                                  height: .greatestFiniteMagnitude)))
                open = (sheet, { once.resume(nil) })
                parent.beginSheet(sheet)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    /// Takes the sheet down unanswered.
    func dismiss() {
        let cancel = open?.cancel
        close()
        cancel?()
    }

    private func close() {
        guard let (window, _) = open else { return }
        open = nil
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }

    /// A continuation resumed once, whoever comes first.
    private final class Once<T: Sendable> {
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
