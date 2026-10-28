import LiveKit
import PeelCore
import PeelUI
import SwiftUI
import UIKit

// The phone's call UI, from the Mac's `CallViews` and `CallWindow`: the call
// screen (a full-screen cover, in place of the Mac's window), its tiles and
// control bar, the bar over the chats while you are on a call, and the
// leave-and-join question. Not here, as on the Mac: screen sharing (it needs
// a broadcast extension), device menus and keep on top.

extension CallStore {
    /// The call you are on, with its media.
    var phoneSession: IOSCallSession? { call as? IOSCallSession }
}

// MARK: - Starting and joining

/// A join or a start that may first ask to leave the call you are on.
enum PendingCall {
    case join(CallLink, chat: String)
    case start(chat: String, audioOnly: Bool)

    /// The room joined, for `CallStore.otherCall`; nil for a new one.
    var room: String? {
        if case .join(let link, _) = self { link.room } else { nil }
    }

    var isJoin: Bool {
        if case .join = self { true } else { false }
    }

    /// Runs it at once, and brings the call screen up if there is a call to show.
    @MainActor func run(_ model: AppModel, _ router: PhoneRouter) {
        model.calls.openingWindow({ router.callShown = true }) {
            switch self {
            case .join(let link, let chat): await model.calls.join(link, in: chat, failureInChat: true)
            case .start(let chat, let audioOnly):
                await model.calls.start(in: chat, audioOnly: audioOnly, jamie: model.callJamie(in: chat))
            }
        }
    }

    /// Runs it, or sets `pending` to ask first when another call is on.
    @MainActor func ask(_ model: AppModel, _ router: PhoneRouter, pending: Binding<PendingCall?>) {
        if model.calls.otherCall(than: room) != nil { pending.wrappedValue = self } else { run(model, router) }
    }
}

extension View {
    /// "Leave the call in #design and join?", the Mac's `CallSwitchConfirm`.
    func callSwitchConfirmation(_ pending: Binding<PendingCall?>, model: AppModel, router: PhoneRouter) -> some View {
        let action = pending.wrappedValue
        let other = model.calls.otherCall(than: action?.room) ?? "the call"
        let joining = action?.isJoin ?? true
        return confirmationDialog(
            "Leave the call in \(other) and \(joining ? "join" : "start a new one")?",
            isPresented: Binding(get: { action != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            Button(joining ? "Leave and join" : "Leave and start") {
                pending.wrappedValue = nil
                action?.run(model, router)
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        }
    }
}

// MARK: - Status

/// The running time, ticking only while connected; otherwise what the
/// connection is doing.
struct IOSCallStatusText: View {
    let call: IOSCallSession

    var body: some View {
        Group {
            if call.state == .connected {
                TimelineView(.periodic(from: .now, by: 1)) { Text(call.status(at: $0.date)) }
            } else {
                Text(call.status(at: .now))
            }
        }
        .phoneFont(.secondary)
        .monospacedDigit()
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
    }
}

/// "#design" with its "#" quiet, or a contact's name.
private struct CallTitle: View {
    let title: String

    var body: some View {
        if title.hasPrefix("#") {
            Text("#").foregroundStyle(Theme.secondaryText).fontWeight(.medium) + Text(title.dropFirst())
        } else {
            Text(title)
        }
    }
}

// MARK: - On a call

extension View {
    /// The on-call banner, at the top of this screen's content, just under the
    /// navigation bar, while on a call with the call screen down. Applied once
    /// per screen (each tab's root, and a conversation); a pushed screen
    /// covers the one beneath it, so only one shows. At the top it never
    /// meets the composer or the tab bar.
    func onCallBannerInset() -> some View {
        modifier(OnCallBannerInset())
    }
}

private struct OnCallBannerInset: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let call = model.calls.phoneSession, !router.callShown {
                IOSOnCallBar(call: call)
            }
        }
    }
}

/// Under the navigation bar while you are on a call and the call screen is
/// down, like the Mac's sidebar bar: the chat, the running time, Mute and Return.
struct IOSOnCallBar: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let call: IOSCallSession

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { router.callShown = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Circle()
                        .fill(call.state == .connected ? Theme.confirmed : Theme.secondaryText)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        CallTitle(title: call.title)
                            .phoneFont(.row)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        IOSCallStatusText(call: call)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to the call in \(call.title)")
            Button(action: call.toggleMicrophone) {
                Image(systemName: call.micOn ? "mic" : "mic.slash")
                    .foregroundStyle(call.micOn ? Theme.text : Theme.secondaryText)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .buttonStyle(.plain)
            .disabled(call.micAccess == .refused)
            .accessibilityLabel(call.micOn ? "Mute" : "Unmute")
            Button { model.calls.leave() } label: {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(Theme.destructive)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave the call")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(maxWidth: .infinity)
        .background(Theme.menu)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - The call screen

/// The call screen: the chat and the running time on top, one tile per
/// person, and the control bar. Putting it away keeps the call; Leave ends it.
struct IOSCallScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router

    var body: some View {
        Group {
            if let call = model.calls.phoneSession {
                VStack(spacing: 0) {
                    header(call)
                    IOSCallStage(call: call)
                    IOSCallControls(call: call)
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.callBackground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        // The call went from anywhere (Leave, another call): the screen goes.
        .onChange(of: model.calls.call == nil) { _, gone in if gone { router.callShown = false } }
        .onAppear { if model.calls.call == nil { router.callShown = false } }
    }

    private func header(_ call: IOSCallSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { router.callShown = false } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                }
                .accessibilityLabel("Back to chats")
                .accessibilityHint("The call goes on")
                Spacer()
            }
            .overlay {
                VStack(spacing: 0) {
                    CallTitle(title: call.title)
                        .phoneFont(.row)
                        .lineLimit(1)
                    IOSCallStatusText(call: call)
                }
                .padding(.horizontal, Theme.touchTarget)
            }
            Theme.callDivider.frame(height: 1)
        }
    }
}

/// The grid, or the focused tile large with everyone else in a strip under it.
private struct IOSCallStage: View {
    let call: IOSCallSession
    private static let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            if let focus = call.focus, let main = call.tiles.first(where: { $0.id == focus }) {
                let others = call.tiles.filter { $0.id != focus }
                VStack(spacing: Self.gap) {
                    IOSCallTile(tile: main, avatarSize: 96) { call.toggleFocus(main.id) }
                    if !others.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: Self.gap) {
                                ForEach(others) { tile in
                                    IOSCallTile(tile: tile, avatarSize: 44) { call.toggleFocus(tile.id) }
                                        .frame(width: 120)
                                }
                            }
                        }
                        .frame(height: 120)
                    }
                }
                .padding(Theme.Space.md)
            } else {
                grid(call.tiles, in: geometry.size)
            }
        }
    }

    /// One column for one or two people, then two, scrolling when they do
    /// not fit.
    private func grid(_ tiles: [IOSCallSession.Tile], in size: CGSize) -> some View {
        let columns = tiles.count <= 2 ? 1 : 2
        let rows = (tiles.count + columns - 1) / columns
        let available = size.height - Theme.Space.md * 2
        let height = max(140, (available - Self.gap * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1)))
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: columns), spacing: Self.gap) {
                ForEach(tiles) { tile in
                    IOSCallTile(tile: tile, avatarSize: min(96, height * 0.4)) { call.toggleFocus(tile.id) }
                        .frame(height: height)
                }
            }
            .padding(Theme.Space.md)
        }
    }
}

/// A person or a shared screen. A tap focuses it, or, on the focused tile,
/// goes back to the grid.
private struct IOSCallTile: View {
    @Environment(AppModel.self) private var model
    let tile: IOSCallSession.Tile
    let avatarSize: CGFloat
    let tap: () -> Void

    var body: some View {
        let shown = model.avatar(of: tile.person)
        let name = tile.isScreen
            ? (tile.isYou ? "Your screen" : "\(shown.name)’s screen")
            : (tile.isYou ? "You" : shown.name)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            tile.isScreen ? Theme.callBackground : Theme.quote
            if let video = tile.video {
                // A screen is never cropped. Taps go to the tile, not to LiveKit's view.
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
                    .phoneFont(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(Theme.callTag, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(10)
        }
        .clipShape(shape)
        .overlay {
            // The accent edge while they speak; a screen's own edge.
            if tile.speaking {
                shape.strokeBorder(Theme.accent, lineWidth: 2)
            } else if tile.isScreen {
                shape.strokeBorder(Theme.divider, lineWidth: 1)
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: tap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.speaking ? "\(name), speaking" : name)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this large, or everyone")
    }
}

// MARK: - The control bar

private struct IOSCallControls: View {
    @Environment(AppModel.self) private var model
    let call: IOSCallSession

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: Theme.Space.md) {
                round(
                    call.micOn ? "mic" : "mic.slash", on: call.micOn,
                    label: call.micOn ? "Mute" : "Unmute", refused: call.micAccess == .refused,
                    action: call.toggleMicrophone
                )
                round(
                    call.cameraOn ? "video" : "video.slash", on: call.cameraOn,
                    label: call.cameraOn ? "Turn camera off" : "Turn camera on", refused: call.cameraAccess == .refused,
                    action: call.toggleCamera
                )
                if call.cameraOn {
                    round("arrow.triangle.2.circlepath.camera", on: true, label: "Flip camera", refused: false, action: call.flipCamera)
                }
                Button { model.calls.leave() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.buttonText)
                        .frame(width: 64, height: 52)
                        .background(Theme.destructive, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Leave the call")
            }
            notes
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    private func round(_ systemImage: String, on: Bool, label: String, refused: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(on ? Theme.text : Theme.secondaryText)
                .frame(width: 52, height: 52)
                .background(Theme.hover, in: Circle())
                .opacity(refused ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(refused)
        .accessibilityLabel(label)
    }

    /// Quiet lines under the bar: access iOS refused, something that went
    /// wrong, a connection that was lost.
    @ViewBuilder private var notes: some View {
        let refused = [call.micAccess == .refused ? "the microphone" : nil, call.cameraAccess == .refused ? "the camera" : nil]
            .compactMap { $0 }
        if !refused.isEmpty {
            note("Can't use \(refused.joined(separator: " or "))", action: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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
                Button(action, action: perform).buttonStyle(.peel(.link, size: .touch))
            }
        }
        .phoneFont(.secondary)
    }
}
