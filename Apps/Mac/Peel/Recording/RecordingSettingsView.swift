import AppKit
import SwiftUI
import PeelUI

/// Account › Recording: record your screen, the camera switch, and the
/// recordings made, each dragged into a chat to send it (docs/recording.md).
struct RecordingSettingsSection: View {
    private var recording: RecordingController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection {
                Fact("Record") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateText)
                        Text("Saved to Downloads, with captions. Recorded and transcribed privately, on this Mac.").muted()
                        if let problem = recording.problem { Text(problem).muted() }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Button(recording.phase == .idle ? "New recording" : "Recording…", action: recording.start)
                        .buttonStyle(.peel(.primary))
                        .disabled(recording.phase != .idle)
                }
                Fact("Camera") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show your camera")
                        Text("A round bubble you can drag anywhere.").muted()
                    }
                } trailing: {
                    PeelSwitch(isOn: Binding(get: { recording.cameraOn }, set: { recording.cameraOn = $0 }))
                        .accessibilityLabel("Camera")
                }
            }
            SettingsSection("Recordings") {
                if recording.recordings.isEmpty {
                    Text("No recordings yet. Ones you make appear here: drag one into a chat to send it.").muted()
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recording.recordings) { RecordingRow(recording: $0) }
                }
            }
        }
        .onAppear { recording.refresh() }
    }

    private var stateText: String {
        switch recording.phase {
        case .idle: "Record your screen"
        case .starting: "Choose a screen to record"
        case .ready: "Press Record on the bar at the bottom of the screen"
        case .recording: "Recording: stop it from the bar at the bottom of the screen"
        case .stopping: "Saving…"
        }
    }
}

/// One recording: its name, size and captions, dragged into a chat as the
/// file itself.
private struct RecordingRow: View {
    let recording: RecordingController.Recording
    private var controller: RecordingController { .shared }

    var body: some View {
        ListRow(size: .md) {
            Image(systemName: "play.rectangle")
                .foregroundStyle(Theme.secondaryText)
        } title: {
            Text(recording.name).lineLimit(1)
        } detail: {
            Text(detail).muted().lineLimit(1)
        } trailing: {
            IconButton("folder", help: "Show in Finder", size: .sm) { controller.showInFinder(recording) }
        }
        .onDrag { NSItemProvider(contentsOf: recording.url) ?? NSItemProvider() }
        .help("Drag into a chat to send it")
    }

    private var detail: String {
        let size = AttachmentFormat.size(Int64(recording.bytes))
        let captions = controller.captions[recording.url]
        return [Formatting.dateAndTime(recording.created), size, captions].compactMap { $0 }.joined(separator: " · ")
    }
}
