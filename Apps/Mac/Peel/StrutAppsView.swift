import PeelAgent
import PeelUI
import SwiftUI

/// Strut/Apps: the apps the workspaces pinned, as Peel's own strut on this
/// Mac serves them (`model.hive.apps`, the list the sidebar's Apps section
/// reads too). A row opens the app as that section's row does.
struct StrutAppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "Strut/Apps")
            if model.hive.apps.isEmpty {
                EmptyState("Apps your workspaces pin show up here.", title: "No struts or apps available locally")
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.hive.apps) { app in
                            ListRow(action: { model.destination = .app(peer: app.peer, name: app.name) }) {
                                Image(systemName: WorkspaceApp.symbol).font(.system(size: 13))
                            } title: {
                                Text(app.title).lineLimit(1)
                            } detail: {
                                if let about = app.about { Text(about).lineLimit(2) }
                            } trailing: {
                                Text("@\(app.peer)").lineLimit(1)
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                }
            }
        }
    }
}
