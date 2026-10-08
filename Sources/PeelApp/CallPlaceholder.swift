import SwiftUI
import LiveKit
import PeelCore

/// The call this Mac is on, until PR 5's call window replaces it: joins the
/// room with the microphone and camera off and counts who is there. The
/// ticket's token goes to LiveKit and is not kept.
@MainActor @Observable
final class CallPlaceholder {
    enum State { case connecting, connected, failed }

    let link: CallLink
    let chat: String
    /// "#tribe" or the contact, as the call began.
    let title: String
    /// This side's identity on the call (the token's), to tell you apart
    /// in the presence feed.
    let identity: String
    private(set) var state = State.connecting
    /// Everyone in the room, you included.
    private(set) var people = 1

    @ObservationIgnored private let room = Room()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(ticket: CallTicket, link: CallLink, chat: String, title: String) {
        self.link = link
        self.chat = chat
        self.title = title
        identity = ticket.identity
        let url = ticket.serverURL.absoluteString, token = ticket.token
        task = Task { [weak self] in await self?.run(url: url, token: token) }
    }

    /// Whether you are on the call, or on your way.
    var isOn: Bool { state != .failed }

    private func run(url: String, token: String) async {
        do {
            // Nothing is published: PR 5's window turns the microphone on.
            try await room.connect(url: url, token: token)
        } catch {
            if !Task.isCancelled { state = .failed }
            return
        }
        state = .connected
        // The room's own counts change on LiveKit's queues; a poll is the
        // simplest complete view, as in the test room.
        while !Task.isCancelled {
            let count = room.remoteParticipants.count + 1
            if count != people { people = count }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Leaves once a join still in flight has finished, so it cannot
    /// outlive the call.
    func leave() {
        let task = task, room = room
        task?.cancel()
        Task {
            await task?.value
            await room.disconnect()
        }
    }
}

/// The placeholder window: the chat, the connection and how many are on
/// the call, and Leave. Closing it leaves too.
struct CallWindow: View {
    static let id = "call"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 14) {
            if let call = model.call {
                Text(call.title)
                    .font(Theme.font(16, .bold))
                    .lineLimit(1)
                Text(status(call))
                    .font(Theme.font(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                Button {
                    model.leaveCall()
                    dismissWindow(id: Self.id)
                } label: {
                    Text("Leave")
                }
                .buttonStyle(GhostButtonStyle(prominent: true, fill: Theme.destructive))
                .keyboardShortcut(.cancelAction)
            } else {
                Text("Not on a call")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 170)
        .background(Theme.background)
        .navigationTitle(model.call?.title ?? "Call")
        .onDisappear { model.leaveCall() }
    }

    private func status(_ call: CallPlaceholder) -> String {
        switch call.state {
        case .connecting: "Connecting…"
        case .connected: "Connected · \(call.people == 1 ? "1 person" : "\(call.people) people")"
        case .failed: "Could not connect to the call"
        }
    }
}
