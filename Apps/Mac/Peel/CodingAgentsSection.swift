import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Account › Connections › Coding agents (`AppModel+Coding`): the coding
/// agents found on this Mac and the folders they may work in. Ask the
/// assistant "fix this bug in peel" and a job runs one of them in a branch
/// of its own in that folder.
struct CodingAgentsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coding = model.coding
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection("Coding agents") {
                Fact("Agents") {
                    if coding.finding {
                        Text("Looking on this Mac…").muted()
                    } else if coding.setup.agents.isEmpty {
                        Text("None found. Install Claude Code, Codex or goose and sign in once in Terminal, then look again.")
                            .muted()
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(coding.setup.agents.map(CodingAgents.title).joined(separator: ", "))
                    }
                } trailing: {
                    Button("Look again") { Task { await model.findCodingAgents() } }
                        .buttonStyle(.peel(.outline))
                        .disabled(coding.finding)
                }
                ForEach(coding.setup.folders.keys.sorted(), id: \.self) { name in
                    Fact(name) {
                        Text(coding.setup.folders[name] ?? "").muted().lineLimit(1).truncationMode(.middle)
                    } trailing: {
                        Button("Remove") { model.removeCodingFolder(name) }
                            .buttonStyle(.peel(.outline))
                    }
                }
                Fact("Add a folder") {
                    Text("Your assistant can ask a coding agent to work here, on a branch of its own: the copy you have open is never changed.")
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Button("Add folder") { model.addCodingFolder() }
                        .buttonStyle(.peel(.outline))
                }
            }
            if let problem = coding.problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .task(id: model.memoryServer?.base) { await model.loadCoding() }
    }
}
