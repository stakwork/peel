import SwiftUI
import LiveKit
import PeelCore

/// Development only: joins a room on a local `livekit-server --dev` and
/// publishes the microphone, to prove the LiveKit build, signing and
/// permissions before any call UI exists (docs/phases/06-calls.md, PR 3).
///
/// Present only with a development profile and a token:
/// `-profile <dev> -callTestToken <jwt> [-callTestURL ws://127.0.0.1:7880]`.
/// The window then opens at launch and joins; Window > Join Test Room opens it
/// again. Only a loopback server is accepted, so this never reaches a real one.
enum CallTest {
    static let windowID = "call-test"

    /// The server and token to join with, or nil when the test is off.
    @MainActor static func config(for model: AppModel) -> (url: String, token: String)? {
        model.profile?.kind == .development ? arguments : nil
    }

    private static let arguments: (url: String, token: String)? = {
        let defaults = UserDefaults.standard
        guard let token = defaults.string(forKey: "callTestToken"), !token.isEmpty else { return nil }
        let string = defaults.string(forKey: "callTestURL") ?? "ws://127.0.0.1:7880"
        guard let url = URL(string: string), url.scheme == "ws",
              let host = url.host?.lowercased(), ServerAddress.isLoopback(host: host)
        else {
            print("call-test: -callTestURL must be ws:// on 127.0.0.1, localhost or [::1]")
            return nil
        }
        return (string, token)
    }()
}

struct CallTestMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Join Test Room") { openWindow(id: CallTest.windowID) }
    }
}

struct CallTestView: View {
    let url: String
    let token: String
    @StateObject private var room = Room()
    @State private var failure: String?
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test room").font(.headline)
            ForEach(lines.indices, id: \.self) { Text(lines[$0]).font(.system(.body, design: .monospaced)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.lg)
        .frame(minWidth: 420, minHeight: 220)
        // Track state changes on participants and publications as well as the
        // room, so a once-a-second poll is the simplest complete view of it.
        // Closing the window cancels this; leave only once the join has
        // finished, so a join still in flight cannot outlive the window.
        .task {
            async let joined: Void = join()
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
            await joined
            await room.disconnect()
        }
    }

    private func join() async {
        do {
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            failure = "Could not join: \(error.localizedDescription)"
            refresh()
        }
    }

    /// The connection, this side's microphone and every remote audio track.
    private var report: [String] {
        let me = room.localParticipant
        var lines = [
            "room \(room.name ?? "-"): \(room.connectionState)",
            "me \(me.identity?.stringValue ?? "-"): \(describe(me.audioTracks))",
        ]
        let others = room.remoteParticipants.values.map { ($0.identity?.stringValue ?? "-", $0) }
        for (name, participant) in others.sorted(by: { $0.0 < $1.0 }) {
            lines.append("\(name): \(describe(participant.audioTracks))")
        }
        return lines
    }

    private func describe(_ tracks: [TrackPublication]) -> String {
        guard !tracks.isEmpty else { return "no audio" }
        return tracks.map { "\($0.source) \($0.isMuted ? "muted" : "live")\($0.isSubscribed ? ", subscribed" : "")" }
            .joined(separator: "; ")
    }

    /// Shows the report, and prints it when it changes for headless checks
    /// (`open --stdout`); never the URL or token.
    private func refresh() {
        let now = report + [failure].compactMap { $0 }
        guard now != lines else { return }
        lines = now
        print("call-test:", now.joined(separator: " | "))
        fflush(stdout)
    }
}
