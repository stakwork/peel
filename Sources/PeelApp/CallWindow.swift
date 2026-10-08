import SwiftUI
import LiveKit
import PeelCore

/// The call window (board C3): the chat and the running time on top, one
/// tile per person, and the control bar. Closing it (⌘W) leaves the call;
/// it closes itself when the call goes from anywhere else.
struct CallWindow: View {
    static let id = "call"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let call = model.call {
                CallRoomView(call: call)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Theme.callBackground)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(edges: .top)
        .navigationTitle(model.call?.title ?? "Call")
        .peelMenuHost()
        .onAppear { if model.call == nil { dismissWindow(id: Self.id) } }
        .onChange(of: model.call == nil) { _, gone in if gone { dismissWindow(id: Self.id) } }
        .onDisappear { model.leaveCall() }
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

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            CallGrid(call: call)
            CallControls(call: call)
        }
    }

    /// The chat and the running time, centred in the title bar.
    private var titleBar: some View {
        HStack(spacing: 8) {
            ChatTitle(title: call.title)
                .font(Theme.font(13, .semibold))
                .lineLimit(1)
            CallStatusText(call: call, size: 13)
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Theme.callDivider.frame(height: 1) }
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

    private static let gap: CGFloat = 10
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
                        CallTileView(tile: tile, avatarSize: min(96, height * 0.4))
                            .frame(width: tileWidth, height: height)
                    }
                }
                .frame(minWidth: size.width, minHeight: size.height)
            }
            .scrollIndicators(.automatic)
        }
        .padding(16)
    }
}

private struct CallTileView: View {
    @Environment(AppModel.self) private var model
    let tile: CallSession.Tile
    let avatarSize: CGFloat

    var body: some View {
        let shown = model.avatar(of: tile.person)
        let name = tile.isYou ? "You" : shown.name
        ZStack(alignment: .bottomLeading) {
            Theme.quote
            if let video = tile.video {
                SwiftUIVideoView(video, layoutMode: .fill)
            } else {
                Avatar(name: shown.name, url: shown.photoURL, size: avatarSize, hue: shown.hue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if tile.muted {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("Muted")
                }
                Text(name)
                    .font(Theme.font(12.5, .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.callTag, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            // The accent edge while they speak.
            if tile.speaking {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.speaking ? "\(name), speaking" : name)
    }
}

// MARK: - The control bar

private struct CallControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    let call: CallSession

    /// Each chevron's frame, by its shortcut key, to open the menu beside.
    @State private var chevrons: [String: CGRect] = [:]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                segment(
                    systemImage: call.micOn ? "mic" : "mic.slash", on: call.micOn,
                    label: call.micOn ? "Mute" : "Unmute", key: "A",
                    refused: call.micAccess == .refused, action: call.toggleMicrophone
                )
                segment(
                    systemImage: call.cameraOn ? "video" : "video.slash", on: call.cameraOn,
                    label: call.cameraOn ? "Turn camera off" : "Turn camera on", key: "V",
                    refused: call.cameraAccess == .refused, action: call.toggleCamera
                )
                Button {
                    model.leaveCall()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.down.fill").font(.system(size: 14))
                        Text("Leave").font(Theme.font(13.5, .bold))
                    }
                    .foregroundStyle(Theme.buttonText)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.destructive, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Leave the call (⌘W)")
            }
            notes
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    /// A control and its chevron, which opens the device menu.
    private func segment(
        systemImage: String, on: Bool, label: String, key: String, refused: Bool, action: @escaping () -> Void
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
            Button { showDevices(at: chevrons[key] ?? .zero) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Microphone, speaker and camera")
            .accessibilityLabel("Choose devices")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chevrons[key] = $0 }
        }
        .frame(height: 44)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        .opacity(refused ? 0.45 : 1)
    }

    /// Quiet lines under the bar: access macOS refused, a device that went,
    /// a connection that was lost.
    @ViewBuilder private var notes: some View {
        let refused = [call.micAccess == .refused ? "the microphone" : nil, call.cameraAccess == .refused ? "the camera" : nil]
            .compactMap { $0 }
        if !refused.isEmpty {
            note("Peel can't use \(refused.joined(separator: " or "))", action: "Open System Settings") {
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
            note(model.callFailures[call.link.room]
                    ?? (call.connectedAt == nil ? "Could not connect to the call" : "Lost the connection to the call"),
                 action: model.joiningRoom == call.link.room ? nil : "Rejoin") { model.rejoinCall() }
        }
    }

    private func note(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 4) {
            Text(text).foregroundStyle(Theme.secondaryText)
            if let action {
                Text("·").foregroundStyle(Theme.secondaryText)
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
            }
        }
        .font(Theme.font(12))
    }

    private func showDevices(at anchor: CGRect) {
        func section(_ title: String, _ devices: [CallSession.Device], chosen: String?, choose: @escaping (String) -> Void) -> [MenuEntry] {
            [.header(title)] + (devices.isEmpty
                ? [.view(AnyView(Text("None found").font(Theme.font(13)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 33).padding(.vertical, 4)))]
                : devices.map { device in .button(device.name, checked: device.id == chosen) { choose(device.id) } })
        }
        let entries = [MenuEntry].sections(
            section("Microphone", call.microphones, chosen: call.microphone, choose: call.chooseMicrophone),
            section("Speaker", call.speakers, chosen: call.speaker, choose: call.chooseSpeaker),
            section("Camera", call.cameras, chosen: call.camera, choose: call.chooseCamera)
        )
        presenter?.show(entries, at: anchor, source: "call-devices", minWidth: 268)
    }
}
