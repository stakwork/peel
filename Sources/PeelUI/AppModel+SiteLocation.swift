import Foundation
import PeelCore

/// Sites' location decisions in the model (iPhone's page sheet,
/// `PageLocation`): read for the page sheet's hook and You › Site location.
extension AppModel {
    func observeSiteLocations(_ storage: Storage) async {
        do {
            for try await grants in storage.siteLocationGrantUpdates() {
                siteLocations = grants
            }
        } catch {}
    }

    /// What the person decided for `origin`; nil if never asked.
    public func siteLocation(for origin: String) -> SiteLocationGrant? {
        try? engine?.storage.siteLocationGrant(origin: origin)
    }

    /// Keeps the decision for `origin`, allowed or not.
    public func decideSiteLocation(origin: String, allowed: Bool, precise: Bool) {
        save(SiteLocationGrant(origin: origin, allowed: allowed, precise: precise && allowed, decidedAt: Int64(Date().timeIntervalSince1970)))
    }

    /// Changes a kept decision in place (Allow, Block, Precise).
    public func updateSiteLocation(_ grant: SiteLocationGrant, allowed: Bool? = nil, precise: Bool? = nil) {
        var next = grant
        if let allowed { next.allowed = allowed }
        if let precise { next.precise = precise }
        if !next.allowed { next.precise = false }
        next.decidedAt = Int64(Date().timeIntervalSince1970)
        save(next)
    }

    public func removeSiteLocation(_ origin: String) {
        do { try engine?.storage.removeSiteLocationGrant(origin: origin) } catch {
            notice = PeelError.noted(error, couldNot: "forget the site")
        }
    }

    public func forgetAllSiteLocations() {
        do { try engine?.storage.clearSiteLocationGrants() } catch {
            notice = PeelError.noted(error, couldNot: "forget the sites")
        }
    }

    private func save(_ grant: SiteLocationGrant) {
        do { try engine?.storage.putSiteLocationGrant(grant) } catch {
            notice = PeelError.noted(error, couldNot: "keep the choice")
        }
    }
}
