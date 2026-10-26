import AgentKit
import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Account › Connections › Stadeum workspaces (`AppModel+Hive`): Connect
/// Stadeum (a code to approve there, and its QR); each workspace paired, and
/// whether a request to it asks first; Pair again once Stadeum no longer
/// knows this Mac; Unpair.
struct StadeumSection: View {
    @Environment(AppModel.self) private var model
    @State private var unpairing = false

    var body: some View {
        let hive = model.stadeum
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection("Stadeum workspaces") {
                switch hive.status {
                case .off:
                    Fact("Stadeum") {
                        Text(model.brain == .thisMac
                             ? "Let your assistant ask your team's workspaces and run their workflows."
                             : "For the assistant on this Mac only: your home server's assistant is paired from there.")
                            .muted()
                            .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        if model.brain == .thisMac {
                            Button("Connect Stadeum") { model.connectHive() }
                                .buttonStyle(.peel(.outline))
                        }
                    }
                case .pairing(let pairing):
                    Fact("Pair this Mac") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Approve this Mac in Stadeum. Check the code matches:").muted()
                            Text(pairing.userCode)
                                .font(Theme.font(20, .semibold))
                                .monospaced()
                                .textSelection(.enabled)
                            QRCodeTile(text: pairing.verificationUriComplete.absoluteString, label: "QR code of Stadeum's pairing page")
                            Link("Open in Stadeum", destination: pairing.verificationUriComplete)
                                .font(Theme.font(12))
                        }
                    } trailing: {
                        Button("Cancel") { model.cancelHivePairing() }
                            .buttonStyle(.peel(.ghost))
                    }
                case .connected, .needsPairing:
                    if hive.status == .needsPairing {
                        Fact("Stadeum") {
                            Text("Stadeum no longer knows this Mac, so your assistant has stopped asking these workspaces. Pair again to use them.")
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
                    Fact("This Mac") {
                        Text(hive.status == .needsPairing ? "Unpair to forget these workspaces."
                             : hive.link?.peers.isEmpty == true ? "Paired, but Stadeum gave no workspaces for this account."
                             : "Your assistant knows these workspaces from its next new conversation.")
                            .muted()
                            .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        InlineConfirm(trigger: "Unpair", prompt: "Unpair this Mac?",
                                      explanation: "Your assistant can no longer ask your workspaces. Revoke this Mac in Stadeum's settings too.",
                                      confirm: "Unpair", alignment: .trailing, confirming: $unpairing) {
                            model.disconnectHive()
                        }
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
                Text("@\(peer.id) · \(renewing ? "Paired, renews daily" : "Paired")").muted()
                Text(rule == nil ? "Asks you before each request" : "Sends without asking").muted()
            }
        } trailing: {
            if let rule {
                Button("Ask first") {
                    do {
                        try model.agent?.revoke(rule)
                    } catch {
                        model.stadeum.problem = PeelError.problem(error, couldNot: "change how \(peer.name) is asked")
                    }
                }
                    .buttonStyle(.peel(.outline))
            }
        }
    }
}
