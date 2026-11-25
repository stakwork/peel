import AgentKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Account › Connections › Stadeum workspaces (`AppModel+Hive`): Connect
/// Stadeum (a code to approve there, and its QR); each workspace paired,
/// whether a request to it asks first, and Talk to Jamie there; Pair again
/// once Stadeum no longer knows this Mac; Unpair. A development profile's
/// `-talkHome` is a row of its own (docs/talk.md).
struct StadeumSection: View {
    @Environment(AppModel.self) private var model
    @State private var unpairing = false

    var body: some View {
        let hive = model.stadeum
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection(String(localized: "Hive workspaces")) {
                switch hive.status {
                case .off:
                    Fact("Hive") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.brain?.moved != nil
                                 ? String(localized: "Your assistant runs on your home server. Turn off Always on to connect Hive.")
                                 : String(localized: "Let your assistant ask your team's workspaces and run their workflows."))
                                .muted()
                            if hive.reconnectHint {
                                Text("Your account is back, but not its Hive connection. Connect Hive again.")
                                    .foregroundStyle(Theme.attention)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        if model.brain == .thisMac {
                            Button("Connect Hive") { model.connectHive() }
                                .buttonStyle(.peel(.outline))
                        }
                    }
                case .pairing(let pairing):
                    Fact(String(localized: "Pair this Mac")) {
                        StadeumPairingCode(pairing: pairing)
                    } trailing: {
                        Button("Cancel") { model.cancelHivePairing() }
                            .buttonStyle(.peel(.ghost))
                    }
                case .connected, .needsPairing:
                    if hive.status == .needsPairing {
                        Fact("Hive") {
                            Text("Hive no longer knows this Mac, so your assistant has stopped asking these workspaces. Pair again to use them.")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        } trailing: {
                            if !unpairing {
                                Button("Pair again") { model.connectHive() }
                                    .buttonStyle(.peel(.outline))
                            }
                        }
                    }
                    ForEach(hive.link?.peers ?? [], id: \.id) { peer in
                        WorkspaceRow(peer: peer, renewing: hive.status == .connected)
                    }
                    ForEach(Array((hive.link?.errors ?? []).enumerated()), id: \.offset) { _, failed in
                        Fact(failed.name) {
                            Text(failed.reason).muted().fixedSize(horizontal: false, vertical: true)
                        } trailing: {
                            EmptyView()
                        }
                    }
                    Fact(String(localized: "This Mac")) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hive.status == .needsPairing ? String(localized: "Unpair to forget these workspaces.")
                                 : hive.link?.peers.isEmpty == true ? String(localized: "Paired, but Hive gave no workspaces for this account.")
                                 : String(localized: "Your assistant knows these workspaces from its next new conversation."))
                            if hive.identified, hive.status == .connected {
                                Text(Stadeum.identifiedLine)
                            }
                        }
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        InlineConfirm(trigger: String(localized: "Unpair"), prompt: String(localized: "Unpair this Mac?"),
                                      explanation: String(localized: "Your assistant can no longer ask your workspaces. Revoke this Mac in Hive's settings too."),
                                      confirm: String(localized: "Unpair"), alignment: .trailing, confirming: $unpairing) {
                            model.disconnectHive()
                        }
                    }
                }
                if let home = model.talk.developmentHome {
                    Fact(home.name) {
                        Text("Development home, \(home.url.absoluteString)").muted()
                    } trailing: {
                        TalkButton(home: home)
                    }
                }
            }
            if let problem = hive.problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A Stadeum pairing waiting for the person's yes there: the code to check,
/// its QR and a link to the page. Here and in a tribe's Jamie row.
struct StadeumPairingCode: View {
    let pairing: HiveClient.Pairing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approve this Mac in Hive. Check the code matches:").muted()
            Text(pairing.userCode)
                .font(Theme.font(20, .semibold))
                .monospaced()
                .textSelection(.enabled)
            QRCodeTile(text: pairing.verificationUriComplete.absoluteString, label: String(localized: "QR code of Hive's pairing page"))
            Link("Open in Hive", destination: pairing.verificationUriComplete)
                .font(Theme.font(12))
        }
    }
}

/// One workspace: its handle, that it renews, and whether a request to its
/// assistant asks first. "Always allow" on a card makes it send unasked;
/// Ask first takes that back.
private struct WorkspaceRow: View {
    @Environment(AppModel.self) private var model
    let peer: HivePeer
    let renewing: Bool

    var body: some View {
        let rule = model.agent?.approvalRules.first {
            $0.tool == DeviceActions.peerTool && $0.target?.id == DeviceActions.peerRuleTarget(peer.id)
        }
        Fact(peer.name) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "@\(peer.id) · \(renewing ? String(localized: "Paired, renews daily") : String(localized: "Paired"))").muted()
                Text(rule == nil ? String(localized: "Asks you before each request") : String(localized: "Sends without asking")).muted()
            }
        } trailing: {
            HStack(spacing: Theme.Space.sm) {
                if renewing, let home = TalkHome(peer: peer) {
                    TalkButton(home: home)
                }
                if let rule {
                    Button("Ask first") {
                        do {
                            try model.agent?.revoke(rule)
                        } catch {
                            model.stadeum.problem = PeelError.problem(error, couldNot: String(localized: "change how \(peer.name) is asked"))
                        }
                    }
                        .buttonStyle(.peel(.outline))
                }
            }
        }
    }
}

/// Talk to Jamie on `home` (docs/talk.md): the Talk window opens, calling.
private struct TalkButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let home: TalkHome

    var body: some View {
        Button("Talk to Jamie") {
            model.talk.talk(to: home)
            openWindow(id: TalkWindow.id)
        }
        .buttonStyle(.peel(.outline))
    }
}
