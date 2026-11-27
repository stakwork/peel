import AppKit
import AVFoundation
import SwiftUI
import PeelCore
import PeelUI

/// Segments (docs/recording.md), as a column beside the rail (Tom,
/// 2026-11-27; the board's "Automations and Segments"), as Payments' history
/// is: Record, then the recordings made, newest first. Beside it Record (a
/// new segment, the camera, how long one runs) or the recording picked, to
/// play and drag into a chat. ⌃⌘S puts the column away.
struct SegmentsView: View {
    /// MainView's: where the page's header starts when it starts at the rail.
    @Environment(\.headerLeadingInset) private var pageInset
    /// The chat list's width, so the column's edge holds still going between them.
    @AppStorage("sidebarWidth") private var columnWidth: Double = 260
    /// The column put away (⌃⌘S, `ColumnToggle`): the page full width.
    @AppStorage("segmentsListHidden") private var listHidden = false
    /// The recording picked; nil for Record.
    @State private var picked: URL?
    private var recording: RecordingController { .shared }

    var body: some View {
        HStack(spacing: 0) {
            if !listHidden {
                VStack(spacing: 0) {
                    ColumnHeader(title: String(localized: "Segments")) { EmptyView() }
                    column
                }
                .frame(width: columnWidth)
                .background(Theme.sidebar)
                PaneDivider(width: $columnWidth, range: 220...420, standard: 260, growsTo: .trailing)
            }
            Group {
                if let shown = recording.recordings.first(where: { $0.url == picked }) {
                    SegmentPage(recording: shown).id(shown.url)
                } else {
                    RecordPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.headerLeadingInset, listHidden ? pageInset : 0)
        }
        .font(Theme.font(13))
        .onAppear { recording.refresh() }
        .onExitCommand { picked = nil }
    }

    private var column: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ListRow(selected: picked == nil, minHeight: 32, action: { picked = nil }) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 20)
                } title: {
                    Text("Record")
                } detail: {
                    EmptyView()
                } trailing: {
                    if recording.phase != .idle {
                        Text("Recording…")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                SectionHeader(String(localized: "Recordings"))
                    .padding(.horizontal, 8)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, 4)
                if recording.recordings.isEmpty {
                    Text("No segments yet. Each one you record shows here, to drag into a chat.")
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    ForEach(recording.recordings) { item in
                        RecordingRow(recording: item, selected: picked == item.url) {
                            picked = picked == item.url ? nil : item.url
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.Space.sm)
        }
    }
}

/// Beside the column with no recording picked: a new segment, and the two
/// things that shape it, the camera bubble and how long it may run.
private struct RecordPage: View {
    private var recording: RecordingController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "Record"))
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Theme.destructive)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("Record your screen")
                            .font(Theme.font(20, .bold))
                        if let stateText {
                            Text(stateText)
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Text("Saved to Downloads. Recorded and captioned on this Mac, never uploaded.").muted()
                        if let problem = recording.problem {
                            Text(problem)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.attention)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    Button(recording.phase == .idle ? String(localized: "New segment") : String(localized: "Recording…"),
                           action: recording.start)
                        .buttonStyle(.peel(.primary))
                        .disabled(recording.phase != .idle)
                    SettingsSection {
                        Fact(String(localized: "Camera")) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show your camera")
                                Text("A round bubble you can drag anywhere.").muted()
                            }
                        } trailing: {
                            PeelSwitch(isOn: Binding(get: { recording.cameraOn }, set: { recording.cameraOn = $0 }))
                                .accessibilityLabel("Camera")
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
                    }
                    .frame(maxWidth: 520)
                    .padding(.top, Theme.Space.sm)
                }
                .padding(.top, 56)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Where a recording under way stands; nothing before one starts.
    private var stateText: String? {
        switch recording.phase {
        case .idle: nil
        case .starting: String(localized: "Choose a screen to record")
        case .ready: String(localized: "Press Record on the bar at the bottom of the screen")
        case .recording: String(localized: "Recording: stop it from the bar at the bottom of the screen")
        case .paused: String(localized: "Paused: resume or stop it from the bar at the bottom of the screen")
        case .stopping: String(localized: "Saving…")
        }
    }
}

/// A recording picked in the column, beside it: played in place, what it
/// is, and the way to send it (drag it into a chat).
private struct SegmentPage: View {
    let recording: RecordingController.Recording
    @State private var player: AVPlayer
    @State private var duration: TimeInterval?
    private var controller: RecordingController { .shared }

    init(recording: RecordingController.Recording) {
        self.recording = recording
        _player = State(initialValue: AVPlayer(url: recording.url))
    }

    var body: some View {
        let sendable = recording.bytes <= Engine.sendLimit
        VStack(spacing: 0) {
            DetailHeader(title: Formatting.dateAndTime(recording.created), subtitle: recording.name, leading: { EmptyView() }) {
                Button("Show in Finder") { controller.showInFinder(recording) }
                    .buttonStyle(.peel(.outline, size: .sm))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    PlayerSurface(player: player, style: .inline)
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .frame(maxWidth: 860)
                    Text(RecordingRow.detail(recording, duration: duration, captions: controller.captions[recording.url])).muted()
                    HStack(spacing: Theme.Space.sm) {
                        Label(recording.name, systemImage: "film")
                            .font(Theme.font(12, .medium))
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Space.sm)
                            .frame(height: 26)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.divider))
                            .onDrag { NSItemProvider(contentsOf: recording.url) ?? NSItemProvider() }
                            .help(String(localized: "Drag into a chat to send it"))
                        Text(sendable ? String(localized: "Drag it into a chat to send it.")
                             : String(localized: "Too large to send in Peel: drag it to Drive or Dropbox, or share it from Finder"))
                            .muted()
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onDisappear { player.pause() }
        .task { duration = await RecordingPosters.info(of: recording.url)?.duration }
    }
}

/// One recording in the column: its first picture, when it was made, then
/// how long it runs, its size and captions; a click shows it beside the
/// column, a drag puts it in a chat.
private struct RecordingRow: View {
    let recording: RecordingController.Recording
    let selected: Bool
    let select: () -> Void
    @State private var info: MediaInfo?
    private var controller: RecordingController { .shared }

    var body: some View {
        ListRow(size: .md, selected: selected, action: select) {
            RecordingPoster(image: info?.poster)
        } title: {
            Text(Formatting.dateAndTime(recording.created)).lineLimit(1)
        } detail: {
            Text(Self.detail(recording, duration: info?.duration, captions: controller.captions[recording.url])).muted().lineLimit(1)
        } trailing: {
            EmptyView()
        }
        .onDrag { NSItemProvider(contentsOf: recording.url) ?? NSItemProvider() }
        .help(recording.bytes <= Engine.sendLimit ? String(localized: "Drag into a chat to send it") : String(localized: "Too large to send in Peel: drag it to Drive or Dropbox, or share it from Finder"))
        .task(id: recording.url) { info = await RecordingPosters.info(of: recording.url) }
    }

    /// "2:41 · 38 MB · Captions in", and that it is too large to send.
    static func detail(_ recording: RecordingController.Recording, duration: TimeInterval?, captions: String?) -> String {
        let length = duration.map { MediaInfo.format(duration: $0) }
        let size = AttachmentFormat.size(Int64(recording.bytes))
        let fits = recording.bytes <= Engine.sendLimit ? nil : String(localized: "Too large to send in Peel")
        return [length, size, captions, fits].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A recording's first picture, small, as the board's column shows it; a
/// plain tile with a play mark until it is read.
private struct RecordingPoster: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.divider
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: 48, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.divider))
        .accessibilityHidden(true)
    }
}

/// Each recording's length and first picture, read once while Peel runs:
/// the column's rows come and go as it scrolls and the page changes.
@MainActor
private enum RecordingPosters {
    private static var read: [URL: MediaInfo] = [:]

    static func info(of url: URL) async -> MediaInfo? {
        if let known = read[url] { return known }
        guard let info = await MediaInfo.load(url, posterPixels: 120) else { return nil }
        read[url] = info
        return info
    }
}
