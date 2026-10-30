import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// You › Stadeum (`AppModel.stadeum`, the model the Mac shares): Connect
/// Stadeum (a code to approve there), each workspace paired, Connect again
/// once Stadeum no longer knows this iPhone, and Disconnect. What it is
/// for: opening what the workspaces' assistants make, and their apps, here
/// (strut's specs/DESKTOP.md, "A device with no strut of its own").
struct StadeumSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stadeum = model.stadeum
        Section {
            switch stadeum.status {
            case .off:
                Text("Open what your workspaces' assistants make for you, and their apps, here on this iPhone.")
                    .foregroundStyle(Theme.quietText(on: .raised))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Stadeum") { stadeum.connect(as: UIDevice.current.name) }
                    .buttonStyle(.peel(.outline, size: .touch))
            case .pairing(let pairing):
                StadeumPairingCode(pairing: pairing)
            case .connected, .needsPairing:
                if stadeum.status == .needsPairing {
                    Text("Stadeum no longer knows this iPhone. Connect it again to open your workspaces' work here.")
                        .foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect again") { stadeum.connect(as: UIDevice.current.name) }
                        .buttonStyle(.peel(.outline, size: .touch))
                }
                ForEach(stadeum.link?.peers ?? [], id: \.id) { peer in
                    LabeledContent(peer.name, value: "@" + peer.id)
                        .accessibilityElement(children: .combine)
                }
                ForEach(stadeum.link?.errors ?? [], id: \.org) { error in
                    LabeledContent(error.name, value: error.reason)
                        .foregroundStyle(Theme.quietText(on: .raised))
                }
                Button("Disconnect") { stadeum.disconnect() }
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

/// A Stadeum pairing waiting for the person's yes there: the code to
/// check, Open Stadeum and Cancel, each a row of its own in a list. In You ›
/// Stadeum and a tribe's Jamie row.
struct StadeumPairingCode: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.surface) private var surface
    let pairing: HiveClient.Pairing

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Approve this iPhone in Stadeum. Check the code matches:")
                .foregroundStyle(Theme.quietText(on: surface))
            Text(pairing.userCode)
                .phoneFont(.title)
                .monospaced()
                .textSelection(.enabled)
                .accessibilityLabel("Code \(pairing.userCode)")
        }
        .padding(.vertical, Theme.Space.xs)
        Button("Open Stadeum") { openURL(pairing.verificationUriComplete) }
            .buttonStyle(.peel(.primary, size: .touch))
        Button("Cancel") { model.stadeum.cancelPairing() }
            .buttonStyle(.peel(.ghost, size: .touch))
    }
}

extension Stadeum {
    /// Reads the workspaces' pinned apps, each on its own strut with the
    /// person's token: the iPhone has no strut to read through.
    @discardableResult
    func readWorkspaceApps() -> Task<Void, Never>? {
        readApps(own: nil, pinned: { try await WorkspaceApp.pinned(on: $0) })
    }
}
