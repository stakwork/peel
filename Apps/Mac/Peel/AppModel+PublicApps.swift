import PeelAgent
import PeelCore
import PeelUI

/// A stranger's public app on the Mac (strut's plans/app-payments.md §5.3,
/// R7; docs/app-wallet.md, "Signing in"): a box Peel is not paired with,
/// opened by a `peel://open?url=<address>` link (`PublicAppLink`). Peel's
/// own strut's UI hosts it in the web pane (strut's remote mode,
/// `MemoryServer.page(public:from:)`), so the main frame is Peel's own and
/// only the app's sandboxed frame is the stranger's. The app wallet's
/// handler answers that page as the seller and app its address names, and
/// signs the person in only to that seller (`WalletScope.remote`).
extension AppModel {
    func openPublicApp(_ link: PublicAppLink) {
        guard phase == .ready else {
            notice = "Unlock Peel, then open the link again."
            return
        }
        guard memoryServer != nil || strut != nil else {
            notice = "Peel opens \(link.host)'s app through its own strut, which isn't running on this Mac."
            return
        }
        Task { [weak self] in
            do {
                let name = try await link.appName()
                // A link that launched Peel comes while its strut is still starting.
                guard let server = await self?.runningStrut() else {
                    self?.notice = "Peel opens \(link.host)'s app with its own strut, which did not start. Try again in a moment."
                    return
                }
                guard let self, let url = server.page(public: name, from: link.seller) else { return }
                self.web.open(StrutPage(url: url, server: server, name: "\(name) · \(link.host)"), model: self) { [weak self] in
                    self?.open($0)
                }
            } catch {
                self?.notice = PeelError.noted(error, couldNot: "open \(link.host)'s app")
            }
        }
    }

    /// Peel's own strut once it answers, waiting up to half a minute while
    /// it starts; nil when there is none.
    private func runningStrut() async -> MemoryServer? {
        for _ in 0..<60 {
            if let memoryServer { return memoryServer }
            guard strut != nil, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return nil }
        }
        return memoryServer
    }
}
