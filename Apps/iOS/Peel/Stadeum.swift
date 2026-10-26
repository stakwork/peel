import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// The person's Stadeum workspaces on this iPhone (strut's specs/DESKTOP.md,
/// "A device with no strut of its own"): paired by Hive's device flow as a
/// device of its own, its credential and each org's token kept in the
/// Keychain (`Profile.hive`) and renewed daily. With them a deliverable from
/// the agent's DM opens on its org's own strut (`OrgPage`) in a sheet
/// (`OrgPageSheet`). The Mac's twin is `HiveState`, which puts the orgs on
/// its strut instead.
@MainActor @Observable
final class PhoneStadeum {
    enum Status: Equatable {
        case off
        /// A code waiting for the person's yes in Stadeum.
        case pairing(HiveClient.Pairing)
        case connected
        /// Stadeum no longer knows this iPhone (revoked there): connect again.
        case needsPairing
    }

    private(set) var status = Status.off
    /// The workspaces, and those Stadeum gave no record for.
    private(set) var link: HiveLink?
    /// The last thing that went wrong, in words; nil once something works.
    private(set) var problem: String?
    /// The page the sheet shows.
    var shown: OrgPageSheet.Page?
    @ObservationIgnored private var pairing: Task<Void, Never>?
    @ObservationIgnored private var renewing: Task<Void, Never>?

    /// Reads what `profile` kept (the account just opened, or Peel came back
    /// to the front) and renews it when due; nothing without an account.
    func refresh(_ profile: Profile?) {
        guard let profile else {
            reset()
            return
        }
        do {
            link = try HiveLink.read(from: profile.hive)
        } catch {
            problem = PeelError.noted(error, couldNot: "read your Stadeum connection")
        }
        if case .pairing = status {} else if let link {
            status = .connected
            if link.due() { renew(link, in: profile) }
        } else if status == .connected {
            status = .off
        }
    }

    /// Connect Stadeum: a code to approve in Stadeum, polled until the person
    /// answers there or it runs out.
    func connect(_ profile: Profile?) {
        guard let profile else { return }
        pairing?.cancel()
        problem = nil
        let client = HiveClient()
        let name = UIDevice.current.name
        pairing = Task {
            do {
                let pairing = try await client.start(name: name)
                // Cancelled while Stadeum answered: its code is never shown.
                try Task.checkCancellation()
                status = .pairing(pairing)
                switch try await client.answer(to: pairing, name: name) {
                case .pending:
                    return
                case .denied:
                    settle("It was turned down in Stadeum.")
                case .expired:
                    settle("The code ran out before it was approved. Try again.")
                case .paired(let link):
                    guard !Task.isCancelled else { return }
                    try link.write(to: profile.hive)
                    self.link = link
                    status = .connected
                }
            } catch is CancellationError {
            } catch {
                settle(PeelError.noted(error, couldNot: "connect Stadeum"))
            }
        }
        /// Ends this pairing with `problem`, unless it was cancelled: a newer one may be under way.
        func settle(_ problem: String) {
            guard !Task.isCancelled else { return }
            status = link == nil ? .off : .needsPairing
            self.problem = problem
        }
    }

    func cancelPairing() {
        pairing?.cancel()
        pairing = nil
        status = link == nil ? .off : .needsPairing
    }

    /// Disconnect: the credential and the tokens gone from this iPhone.
    /// Stadeum keeps the device until it is revoked there, and its tokens
    /// age out in a week.
    func disconnect(_ profile: Profile?) {
        reset()
        do {
            try profile?.hive.delete()
        } catch {
            problem = PeelError.noted(error, couldNot: "forget the Stadeum connection")
        }
    }

    /// How a deliverable opens here: on its org's own strut, or why not.
    func opening(_ handle: AgentArtifact.Handle) -> Opening {
        guard let org = handle.onOrg else { return .onMac }
        guard let peer = link?.peers.first(where: { $0.id == org.peer }) else {
            return link == nil ? .connectFirst : .notPaired(org.peer)
        }
        guard let base = URL(string: peer.baseUrl), let url = org.url(on: base) else { return .notPaired(org.peer) }
        return .page(OrgPageSheet.Page(url: url, token: peer.token, workspace: peer.name))
    }

    enum Opening {
        case page(OrgPageSheet.Page)
        /// No Stadeum on this iPhone yet.
        case connectFirst
        /// An org this iPhone holds no token for.
        case notPaired(String)
        /// On the brain's own strut, which only the Mac reaches.
        case onMac
    }

    private func renew(_ link: HiveLink, in profile: Profile) {
        guard renewing == nil else { return }
        renewing = Task {
            defer { renewing = nil }
            do {
                let renewed = try await HiveClient(hive: link.hive).renew(link)
                // Disconnected meanwhile: nothing of it is kept.
                guard self.link?.credential == link.credential else { return }
                guard let renewed else {
                    // Revoked in Stadeum: its tokens may still work until they expire, so they stop being used now.
                    try? profile.hive.delete()
                    self.link = nil
                    shown = nil
                    status = .needsPairing
                    problem = "Stadeum no longer knows this iPhone. Connect it again to open your workspaces' work here."
                    return
                }
                try renewed.write(to: profile.hive)
                self.link = renewed
                problem = nil
            } catch is CancellationError {
            } catch {
                // Tried again when Peel next comes to the front; the tokens last a week.
                problem = PeelError.noted(error, couldNot: "renew your Stadeum workspaces")
            }
        }
    }

    private func reset() {
        pairing?.cancel()
        renewing?.cancel()
        pairing = nil
        renewing = nil
        status = .off
        link = nil
        problem = nil
        shown = nil
    }
}

/// You › Stadeum: Connect Stadeum (a code to approve there), each workspace
/// paired, Connect again once Stadeum no longer knows this iPhone, and
/// Disconnect. What it is for: opening what the workspaces' assistants make,
/// here.
struct StadeumSection: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneStadeum.self) private var stadeum
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch stadeum.status {
            case .off, .needsPairing:
                Text(stadeum.status == .off
                     ? "Open what your workspaces' assistants make for you, here on this iPhone."
                     : "Stadeum no longer knows this iPhone. Connect it again to open your workspaces' work here.")
                    .foregroundStyle(stadeum.status == .off ? Theme.quietText(on: .raised) : Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                Button(stadeum.status == .off ? "Connect Stadeum" : "Connect again") { stadeum.connect(model.profile) }
                    .buttonStyle(.peel(.outline, size: .touch))
            case .pairing(let pairing):
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Approve this iPhone in Stadeum. Check the code matches:")
                        .foregroundStyle(Theme.quietText(on: .raised))
                    Text(pairing.userCode)
                        .phoneFont(.title)
                        .monospaced()
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(pairing.userCode)")
                }
                .padding(.vertical, Theme.Space.xs)
                Button("Open Stadeum") { openURL(pairing.verificationUriComplete) }
                    .buttonStyle(.peel(.primary, size: .touch))
                Button("Cancel") { stadeum.cancelPairing() }
                    .buttonStyle(.peel(.ghost, size: .touch))
            case .connected:
                ForEach(stadeum.link?.peers ?? [], id: \.id) { peer in
                    LabeledContent(peer.name, value: "@" + peer.id)
                        .accessibilityElement(children: .combine)
                }
                ForEach(stadeum.link?.errors ?? [], id: \.org) { error in
                    LabeledContent(error.name, value: error.reason)
                        .foregroundStyle(Theme.quietText(on: .raised))
                }
                Button("Disconnect") { stadeum.disconnect(model.profile) }
                    .buttonStyle(.peel(.ghost, size: .touch))
            }
            if let problem = stadeum.problem {
                Text(problem)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            PhoneSectionHeader("Stadeum")
        }
        .phoneRows(.grouped)
        .environment(\.surface, .raised)
    }
}
