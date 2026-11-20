import AppKit
import SwiftUI
import PeelCore
import PeelUI

/// Segments (the sidebar's row): record your screen, the camera switch, and the
/// recordings made, each dragged into a chat to send it (docs/recording.md).
struct RecordingSettingsSection: View {
    private var recording: RecordingController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection {
                Fact(String(localized: "New segment")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateText)
                        Text("Saved to Downloads. Recorded and captioned on this Mac, never uploaded.").muted()
                        if let problem = recording.problem { Text(problem).muted() }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Button(recording.phase == .idle ? String(localized: "New segment") : String(localized: "Recording…"), action: recording.start)
                        .buttonStyle(.peel(.primary))
                        .disabled(recording.phase != .idle)
                }
                Fact(String(localized: "Segment limit")) {
                    Text("Stops on its own after this long")
                } trailing: {
                    SegmentedChoice(
                        selection: Binding(get: { recording.longest }, set: { recording.longest = $0 }),
                        options: RecordingController.lengths.map { ($0, "\($0) min") }
                    )
                    .disabled(recording.phase != .idle)
                }
                Fact(String(localized: "Camera")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show your camera")
                        Text("A round bubble you can drag anywhere.").muted()
                    }
                } trailing: {
                    PeelSwitch(isOn: Binding(get: { recording.cameraOn }, set: { recording.cameraOn = $0 }))
                        .accessibilityLabel("Camera")
                }
            }
            SettingsSection(String(localized: "Your segments")) {
                if recording.recordings.isEmpty {
                    Text("No segments yet. Drag one into a chat to send it.").muted()
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
        case .idle: String(localized: "Record your screen, with captions")
        case .starting: String(localized: "Choose a screen to record")
        case .ready: String(localized: "Press Record on the bar at the bottom of the screen")
        case .recording: String(localized: "Recording: stop it from the bar at the bottom of the screen")
        case .paused: String(localized: "Paused: resume or stop it from the bar at the bottom of the screen")
        case .stopping: String(localized: "Saving…")
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
            IconButton("folder", help: String(localized: "Show in Finder"), size: .sm) { controller.showInFinder(recording) }
        }
        .onDrag { NSItemProvider(contentsOf: recording.url) ?? NSItemProvider() }
        .help(sendable ? String(localized: "Drag into a chat to send it") : String(localized: "Too large to send in Peel: drag it to Drive or Dropbox, or share it from Finder"))
    }

    private var sendable: Bool { recording.bytes <= Engine.sendLimit }

    private var detail: String {
        let size = AttachmentFormat.size(Int64(recording.bytes))
        let captions = controller.captions[recording.url]
        let fits = sendable ? nil : String(localized: "Too large to send in Peel")
        return [Formatting.dateAndTime(recording.created), size, captions, fits].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The sidebar's Segments row: screen recording and your segments, in the detail column.
struct SegmentsView: View {
    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "Segments"))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RecordingSettingsSection()
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
                .endsEditingOnClick()
            }
        }
        .font(Theme.font(13))
    }
}
