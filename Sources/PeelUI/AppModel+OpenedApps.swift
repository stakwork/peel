import Foundation
import PeelCore

/// The public apps opened here stay in Apps (docs/phases/13-worker-invite-iphone.md):
/// a worker's Tasks, opened from an invite, is found again under "Apps you
/// opened" with no Stadeum workspace, until Disconnect in You › Connected apps
/// forgets it with its connection.
extension AppModel {
    /// Follows the stored list for the account's life (started with the wallet).
    func openedAppsTask(_ storage: Storage) -> Task<Void, Never> {
        let engine = engine
        return Task { [weak self] in
            do {
                for try await apps in storage.openedPublicAppUpdates() {
                    guard let self, self.engine === engine else { return }
                    // An address today's rules refuse is left out.
                    self.openedApps = apps.filter { $0.link != nil }
                }
            } catch {}
        }
    }

    /// A public app is about to come on screen, whichever way it was reached:
    /// kept for Apps, and, when a worker's invite link named it (`invited`),
    /// its sign-in granted as you before it loads
    /// (`WalletHost.grantInvitePage`), so its sign-in asks nothing. Only that
    /// link is granted: never a `peel://open` link or an open from Apps.
    public func openingPublicApp(_ link: PublicAppLink, invited: Bool) {
        guard let storage = engine?.storage else { return }
        do {
            try storage.rememberPublicApp(link, at: Int64(Date().timeIntervalSince1970))
            if invited { try WalletHost.grantInvitePage(link, storage: storage, now: Int64(Date().timeIntervalSince1970)) }
        } catch {
            notice = PeelError.noted(error, couldNot: String(localized: "keep the app", table: "Shared"))
        }
    }

    /// Takes one app off Apps' list; its connection stays.
    public func forgetOpenedApp(_ app: OpenedPublicApp) {
        do {
            try engine?.storage.forgetPublicApp(seller: app.seller, app: app.app)
        } catch {
            notice = PeelError.noted(error, couldNot: String(localized: "remove the app", table: "Shared"))
        }
    }
}
