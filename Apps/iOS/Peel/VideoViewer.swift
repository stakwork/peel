import AVKit
import PeelCore
import PeelUI
import SwiftUI

// The full-screen video player on the phone, over the whole screen from a
// tapped video tile (`VideoTile`), as `ImageViewer` is for pictures: black,
// the system's player controls (and Picture in Picture), a glass close
// button, a drag down to close. It plays as it opens and stops on closing.

struct VideoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let file: URL

    @State private var player: AVPlayer?
    @State private var pull: CGFloat = 0

    /// How far down a drag closes the viewer.
    private static let closeDistance: CGFloat = 120

    var body: some View {
        let fade = 1 - min(abs(pull) / 400, 0.7)
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(fade).ignoresSafeArea()
            if let player {
                PlayerController(player: player)
                    .ignoresSafeArea()
                    .offset(y: pull)
                    .accessibilityLabel("Video")
            }
            Button { dismiss() } label: {
                GlassSymbol(systemImage: "xmark", label: "Close", tint: nil)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                    .contentShape(Circle())
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close")
            .padding(Theme.Space.md)
            .opacity(pull == 0 ? 1 : 0)
        }
        .preferredColorScheme(.dark)
        .simultaneousGesture(dismissDrag)
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        guard player == nil else { return }
        // Sound with the silent switch on, as for a voice message.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: MediaInfo.asset(file)))
        self.player = player
        player.play()
    }

    private func stop() {
        player?.pause()
        player = nil
        VideoPlayback.shared.stop()
    }

    /// Down pulls the player away, the black fades, and letting go far
    /// enough (or fast enough) closes.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                if pull == 0, abs(drag.translation.height) <= abs(drag.translation.width) { return }
                pull = max(drag.translation.height, 0)
            }
            .onEnded { drag in
                guard pull > 0 else { return }
                if pull > Self.closeDistance || drag.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { pull = 0 }
                }
            }
    }
}

/// The system's player with its native controls.
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
