import SwiftUI
import LiveKit
import PeelCore
import PeelUI

/// The call window (board C3): the chat and the running time on top, one
/// tile per person, and the control bar. Closing it (⌘W) leaves the call;
/// it closes itself when the call goes from anywhere else.
struct CallWindow: View {
    static let id = "call"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let call = model.calls.session {
                CallRoomView(call: call)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Theme.callBackground)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(edges: .top)
        .navigationTitle(model.calls.call?.title ?? "Call")
        .peelMenuHost()
        .onAppear { if model.calls.call == nil { dismissWindow(id: Self.id) } }
        .onChange(of: model.calls.call == nil) { _, gone in if gone { dismissWindow(id: Self.id) } }
        .onDisappear { model.calls.leave() }
    }

}

/// The running time, ticking only while connected; otherwise what the
/// connection is doing. In the window's title and the sidebar's bar.
struct CallStatusText: View {
    let call: CallSession
    let size: CGFloat

    var body: some View {
        Group {
            if call.state == .connected {
                TimelineView(.periodic(from: .now, by: 1)) { Text(call.status(at: $0.date)) }
            } else {
                Text(call.status(at: .now))
            }
        }
        .font(Theme.font(size))
        .monospacedDigit()
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
    }
}

private struct CallRoomView: View {
    let call: CallSession
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            CallStage(call: call)
            CallControls(call: call)
        }
        .background(WindowReader { window = $0 })
        .onChange(of: window) {
            window?.collectionBehavior.insert(.fullScreenPrimary)
            keepOnTopChanged()
        }
        .onChange(of: call.keepOnTop) { keepOnTopChanged() }
        // Escape goes back to the grid. A button rather than `onExitCommand`,
        // which needs a focused view the call window usually lacks.
        .hiddenShortcut(.cancelAction, enabled: call.focus != nil, action: call.showGrid)
    }

    private func keepOnTopChanged() {
        window?.level = call.keepOnTop ? .floating : .normal
    }

    /// The chat and the running time, centred in the title bar; Keep on top
    /// at its right.
    private var titleBar: some View {
        HStack(spacing: Theme.Space.sm) {
            ChatTitle(title: call.title)
                .font(Theme.font(13, .semibold))
                .lineLimit(1)
            CallStatusText(call: call, size: 13)
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .overlay(alignment: .trailing) { keepOnTop.padding(.trailing, 10) }
        .overlay(alignment: .bottom) { Theme.callDivider.frame(height: 1) }
    }

    private var keepOnTop: some View {
        let on = call.keepOnTop
        return IconButton(help: on ? "Stop keeping the call above other windows" : "Keep the call above other windows") {
            call.keepOnTop.toggle()
        } label: {
            if on {
                Image(systemName: "pin.fill").foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "pin")
            }
        }
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// The grid, or the focused tile large with everyone else in a strip
/// beside it (board C3's screen-share layout).
private struct CallStage: View {
    let call: CallSession

    var body: some View {
        if let focus = call.focus, let main = call.tiles.first(where: { $0.id == focus }) {
            let others = call.tiles.filter { $0.id != focus }
            HStack(spacing: CallGrid.gap) {
                CallTileView(tile: main, avatarSize: 96, focused: true) { call.toggleFocus(main.id) }
                if !others.isEmpty { strip(others) }
            }
            .padding(Theme.Space.lg)
        } else {
            CallGrid(call: call)
        }
    }

    /// Everyone else, 200 pt wide, scrolling when they do not fit.
    private func strip(_ tiles: [CallSession.Tile]) -> some View {
        GeometryReader { geometry in
            let fill = (geometry.size.height - CallGrid.gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
            let height = min(150, max(112, fill))
            ScrollView {
                LazyVStack(spacing: CallGrid.gap) {
                    ForEach(tiles) { tile in
                        CallTileView(tile: tile, avatarSize: 52, focused: false) { call.toggleFocus(tile.id) }
                            .frame(height: height)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 200)
    }
}

/// "#design" with its "#" quiet, or a contact's name.
struct ChatTitle: View {
    let title: String

    var body: some View {
        if title.hasPrefix("#") {
            Text("#").foregroundStyle(Theme.secondaryText).fontWeight(.medium) + Text(title.dropFirst())
        } else {
            Text(title)
        }
    }
}

// MARK: - The grid

/// One tile per person: two side by side, then two by two, then three or
/// four across, scrolling when there are more than fit.
private struct CallGrid: View {
    let call: CallSession

    static let gap: CGFloat = 10
    private static let minTile: CGFloat = 140

    var body: some View {
        let tiles = call.tiles
        GeometryReader { geometry in
            let size = geometry.size
            let columns = tiles.count <= 1 ? 1 : tiles.count <= 4 ? 2 : tiles.count <= 9 ? 3 : 4
            let rows = (tiles.count + columns - 1) / columns
            let width = (size.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
            // One or two people keep a 16:11 frame; more fill the height,
            // down to a minimum, then scroll.
            let height = tiles.count <= 2
                ? min(width * 11 / 16, size.height)
                : max(Self.minTile, (size.height - Self.gap * CGFloat(rows - 1)) / CGFloat(rows))
            let tileWidth = tiles.count <= 2 ? height * 16 / 11 : width
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: Self.gap), count: columns),
                    spacing: Self.gap
                ) {
                    ForEach(tiles) { tile in
                        CallTileView(tile: tile, avatarSize: min(96, height * 0.4), focused: false) { call.toggleFocus(tile.id) }
                            .frame(width: tileWidth, height: height)
                    }
                }
                .frame(minWidth: size.width, minHeight: size.height)
            }
            .scrollIndicators(.automatic)
        }
        .padding(Theme.Space.lg)
    }
}

/// A person or a shared screen. A click focuses it, or, on the focused
/// tile, goes back to the grid.
private struct CallTileView: View {
    @Environment(AppModel.self) private var model
    let tile: CallSession.Tile
    let avatarSize: CGFloat
    let focused: Bool
    let click: () -> Void

    var body: some View {
        let shown = model.avatar(of: tile.person)
        let name = tile.isScreen
            ? (tile.isYou ? "Your screen" : "\(shown.name)’s screen")
            : (tile.isYou ? "You" : shown.name)
        ZStack(alignment: .bottomLeading) {
            tile.isScreen ? Theme.callBackground : Theme.quote
            if let video = tile.video {
                // A screen is never cropped.
                // Clicks go to the tile, not to LiveKit's view.
                SwiftUIVideoView(video, layoutMode: tile.isScreen ? .fit : .fill)
                    .allowsHitTesting(false)
            } else {
                Avatar(name: shown.avatarName, url: shown.photoURL, size: avatarSize, hue: shown.hue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if tile.isScreen {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                if tile.muted {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("Muted")
                }
                Text(name)
                    .font(Theme.font(12, .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(Theme.callTag, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay {
            // The accent edge while they speak; a screen's own edge.
            if tile.speaking {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
            } else if tile.isScreen {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .onTapGesture(perform: click)
        .help(focused ? "\(name) · Click or press Escape to see everyone" : "\(name) · Click to focus")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.speaking ? "\(name), speaking" : name)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(focused ? "Shows everyone" : "Shows this large")
    }
}

// MARK: - The control bar

private struct CallControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let call: CallSession

    /// Each chevron's frame, to open the device menu beside.
    @State private var micChevron = MenuAnchor()
    @State private var cameraChevron = MenuAnchor()
    @State private var shareChevron = MenuAnchor()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                segment(
                    systemImage: call.micOn ? "mic" : "mic.slash", on: call.micOn,
                    label: call.micOn ? "Mute" : "Unmute", key: "A", chevron: micChevron,
                    refused: call.micAccess == .refused, action: call.toggleMicrophone
                )
                segment(
                    systemImage: call.cameraOn ? "video" : "video.slash", on: call.cameraOn,
                    label: call.cameraOn ? "Turn camera off" : "Turn camera on", key: "V", chevron: cameraChevron,
                    refused: call.cameraAccess == .refused, action: call.toggleCamera
                )
                share
                Button {
                    model.calls.leave()
                } label: {
                    pill("phone.down.fill", "Leave", weight: .bold, text: Theme.buttonText, fill: Theme.destructive)
                        .padding(.horizontal, Theme.Space.xs)
                }
                .buttonStyle(.plain)
                .help("Leave the call (⌘W)")
            }
            notes
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, 18)
    }

    /// Share starts on the entire screen, its chevron offers a window or an
    /// app; while you share it is one filled button that stops it.
    @ViewBuilder private var share: some View {
        if call.sharing != nil {
            Button { call.stopScreenShare() } label: {
                pill("rectangle.inset.filled.and.person.filled", "Stop sharing", weight: .medium,
                     text: Theme.buttonText, fill: Theme.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Stop sharing (⌘⇧S)")
        } else {
            shareSegment
        }
    }

    /// The Share control and its chevron, which opens the share menu.
    private var shareSegment: some View {
        let unavailable = call.state != .connected
        return HStack(spacing: 0) {
            Button { call.startScreenShare(.display) } label: {
                pill("rectangle.inset.filled.and.person.filled", "Share", weight: .medium, text: Theme.text, fill: .clear)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Share your entire screen (⌘⇧S)")
            Theme.callChevronLine.frame(width: 1)
            chevron(shareChevron, help: "Share the screen, a window or an app", label: "Choose what to share") {
                showShareMenu(at: shareChevron)
            }
        }
        .frame(height: 44)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .disabled(unavailable)
        .opacity(unavailable ? 0.45 : 1)
    }

    /// A labelled control in the bar: Share and Leave.
    private func pill(_ systemImage: String, _ title: String, weight: Font.Weight, text: Color, fill: Color) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: systemImage).font(.system(size: 14))
            Text(title).font(Theme.font(13, weight))
        }
        .foregroundStyle(text)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contentShape(Rectangle())
    }

    /// A control and its chevron, which opens the device menu.
    private func segment(
        systemImage: String, on: Bool, label: String, key: String, chevron: MenuAnchor, refused: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(on ? Theme.text : Theme.secondaryText)
                    .frame(minWidth: 48, maxHeight: .infinity)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(refused)
            .keyboardShortcut(KeyEquivalent(Character(key.lowercased())), modifiers: [.command, .shift])
            .help("\(label) (⌘⇧\(key))")
            .accessibilityLabel(label)
            Theme.callChevronLine.frame(width: 1)
            self.chevron(chevron, help: "Microphone, speaker and camera", label: "Choose devices") {
                showDevices(at: chevron)
            }
        }
        .frame(height: 44)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .opacity(refused ? 0.45 : 1)
    }

    /// The chevron half of a segment, which opens a menu beside `anchor`.
    private func chevron(_ anchor: MenuAnchor, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .menuAnchor(anchor)
    }

    /// Quiet lines under the bar: access macOS refused, a device that went,
    /// a connection that was lost.
    @ViewBuilder private var notes: some View {
        if let sharing = call.sharing {
            note(sharing.note, action: "Stop", perform: call.stopScreenShare)
        }
        let refused = [call.micAccess == .refused ? "the microphone" : nil, call.cameraAccess == .refused ? "the camera" : nil]
            .compactMap { $0 }
        if !refused.isEmpty {
            note("Can't use \(refused.joined(separator: " or "))", action: "Open System Settings") {
                let pane = call.micAccess == .refused ? "Privacy_Microphone" : "Privacy_Camera"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        if let notice = call.deviceNotice {
            note(notice)
        }
        if call.state == .lost {
            note(model.calls.failures[call.link.room]
                    ?? (call.connectedAt == nil ? "Could not connect to the call" : "Lost the connection to the call"),
                 action: model.calls.joiningRoom == call.link.room ? nil : "Rejoin") { model.calls.rejoin() }
        }
    }

    private func note(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Text(text).foregroundStyle(Theme.secondaryText)
            if let action {
                Text("·").foregroundStyle(Theme.secondaryText)
                Button(action, action: perform).buttonStyle(.peel(.link, size: .sm))
            }
        }
        .font(Theme.font(12))
    }

    private func showDevices(at anchor: MenuAnchor) {
        func section(_ title: String, _ devices: [CallSession.Device], chosen: String?, choose: @escaping (String) -> Void) -> [MenuEntry] {
            [.header(title)] + (devices.isEmpty
                ? [.view(AnyView(Text("None found").font(Theme.font(13)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 33).padding(.vertical, Theme.Space.xs)))]
                : devices.map { device in .button(device.name, checked: device.id == chosen) { choose(device.id) } })
        }
        let entries = [MenuEntry].sections(
            section("Microphone", call.microphones, chosen: call.microphone, choose: call.chooseMicrophone),
            section("Speaker", call.speakers, chosen: call.speaker, choose: call.chooseSpeaker),
            section("Camera", call.cameras, chosen: call.camera, choose: call.chooseCamera)
        )
        presenter?.show(entries, at: anchor, source: "call-devices", minWidth: 268)
    }

    /// What the picker opens on: the entire screen, a window or an app.
    private func showShareMenu(at anchor: MenuAnchor) {
        let entries: [MenuEntry] = [
            .header("Share"),
            .button("Entire screen", systemImage: "display") { call.startScreenShare(.display) },
            .button("A window", systemImage: "macwindow") { call.startScreenShare(.window) },
            .button("An app", systemImage: "app") { call.startScreenShare(.application) },
        ]
        presenter?.show(entries, at: anchor, source: "call-share", minWidth: 200)
    }
}
