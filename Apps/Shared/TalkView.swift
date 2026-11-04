import PeelCore
import PeelUI
import SwiftUI
#if os(iOS)
import SafariServices
#endif

// The Talk call screen (docs/talk.md), the phone's full-screen cover and
// the Mac's Talk window alike: the org on top, what Jamie is doing, the
// live text, then Jamie's voice, Mute and Hang up. Calling, a refusal in the
// home's own words, and a call that ended show here too.

struct TalkView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    /// What a tapped card opens in, over the call: a sheet of this screen's own.
    @State private var opener = TalkOpener()
    #endif

    var body: some View {
        let talk = model.talk
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(talk.home?.name ?? "")
                    .talkFont(16, .semibold, .headline)
                    .lineLimit(1)
                Text("Talking to Jamie")
                    .talkFont(13, .regular, .footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, Theme.Space.lg)
            .padding(.horizontal, Theme.Space.lg)
            switch talk.state {
            case .starting:
                TalkPhaseView(words: "Calling Jamie…", mode: .breathing)
                Spacer()
                TalkControls(session: nil)
            case .failed(let problem):
                TalkEnded(words: problem)
            case .on(let media):
                if let session = media as? TalkSession {
                    if session.phase.isOver {
                        TalkEnded(words: session.phase.words)
                    } else {
                        TalkLive(session: session)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.callBackground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        #if os(iOS)
        // This screen is a full-screen cover, over which the root's sheet
        // (`router.orgPage`) does not show: a card opens in a sheet from here,
        // and the call stays up behind it.
        .environment(opener)
        .sheet(item: $opener.opened) { opened in
            switch opened {
            case .page(let page): OrgPageSheet(page: page)
            case .link(let url): TalkSafariView(url: url).ignoresSafeArea()
            }
        }
        // Its workspace no longer in use: the page and its token go.
        .onChange(of: model.stadeum.live) { _, live in
            if case .page(let page)? = opener.opened, !live.contains(where: { $0.id == page.peer }) { opener.opened = nil }
        }
        #endif
    }
}

#if os(iOS)
/// What a card opened on the call screen shows in a sheet.
enum TalkOpened: Identifiable {
    case page(OrgPageRequest)
    case link(URL)

    var id: String {
        switch self {
        case .page(let page): "page/\(page.id)"
        case .link(let url): "link/\(url.absoluteString)"
        }
    }
}

/// The call screen's sheet for a tapped card (`AgentArtifactLine`).
@MainActor @Observable
final class TalkOpener {
    var opened: TalkOpened?
}

/// An https link in the system's in-app browser, so the call stays up behind it.
private struct TalkSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

/// One of Jamie's artifacts as a tappable row: the app's own line for it
/// (`AgentArtifactLine`), which says where it lives, opens it, or says why
/// it cannot be opened here.
private struct TalkArtifactRow: View {
    let artifact: AgentArtifact

    var body: some View {
        line
            .talkFont(14, .regular, .subheadline)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
            #if os(iOS)
            .accessibilityLabel("\(artifact.title), \(artifact.label ?? "Artifact")")
            #endif
    }

    @ViewBuilder private var line: some View {
        #if os(iOS)
        AgentArtifactLine(artifact: artifact, inTribe: false)
        #else
        AgentArtifactLine(artifact: artifact)
        #endif
    }
}

/// What Jamie is doing, large: a waveform in a circle (`TalkWaveView`),
/// tinted while Jamie speaks, and the words under it, which VoiceOver reads.
private struct TalkPhaseView: View {
    let words: String
    let mode: TalkWave.Mode
    var session: TalkSession?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle()
                    .fill(mode == .agent ? Theme.accent.opacity(0.16) : Theme.hover)
                    .animation(.easeInOut(duration: 0.35), value: mode)
                TalkWaveView(mode: mode, session: session)
                    .frame(width: 62, height: 54)
            }
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
            Text(words)
                .talkFont(16, .regular, .body)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.top, 40)
        .padding(.bottom, Theme.Space.lg)
    }
}

/// The circle's bars (`TalkWave`): they move with Jamie's voice while it
/// speaks and the member's while it listens, sampled from the room about 30
/// times a second; a travelling wave while Jamie thinks, a slow breath while
/// calling, low and flat while muted. With Reduce Motion they hold their
/// shape and only their size follows, slowly.
private struct TalkWaveView: View {
    let mode: TalkWave.Mode
    let session: TalkSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames = TalkWaveFrames()

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 15 : 1.0 / 30)) { timeline in
            Canvas { context, size in draw(&context, size, at: timeline.date) }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, at now: Date) {
        // Both drained each frame, so a voice switched to starts fresh.
        let agent = session?.level(of: .agent) ?? 0, you = session?.level(of: .you) ?? 0
        let bars = frames.step(mode, heard: mode == .agent ? agent : you, at: now, reduceMotion: reduceMotion)
        let tint = frames.tint(toward: Self.color(mode).resolve(in: context.environment))
        let count = CGFloat(bars.count)
        let width = size.width / (count + (count - 1) * 0.7)
        let gap = width * 0.7
        for (i, share) in bars.enumerated() {
            let height = max(width, size.height * share)
            let bar = CGRect(x: CGFloat(i) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
            context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(Color(tint)))
        }
    }

    /// Jamie's voice in the accent, the member's a lighter neutral.
    private static func color(_ mode: TalkWave.Mode) -> Color {
        switch mode {
        case .agent: Theme.accent
        case .thinking: Theme.accent.opacity(0.7)
        case .member: Theme.secondaryText
        case .breathing: Theme.secondaryText.opacity(0.7)
        case .muted: Theme.secondaryText.opacity(0.35)
        case .still: Theme.secondaryText.opacity(0.45)
        }
    }
}

/// The waveform's state from frame to frame. Not observed: a frame never
/// asks for another draw.
@MainActor
private final class TalkWaveFrames {
    private var animator = TalkWave.Animator()
    private var start: Date?
    private var last: Date?
    private var shown: Color.Resolved?
    private var dt = 0.0

    func step(_ mode: TalkWave.Mode, heard: Double, at now: Date, reduceMotion: Bool) -> [Double] {
        let start = start ?? now
        self.start = start
        // A long gap (the view hidden) is one frame, not a jump.
        dt = last.map { min(0.1, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        return animator.step(mode, heard: heard, time: now.timeIntervalSince(start), dt: dt, reduceMotion: reduceMotion)
    }

    /// The bars' colour, eased toward `target` in about a third of a second.
    func tint(toward target: Color.Resolved) -> Color.Resolved {
        guard var color = shown, dt > 0 else {
            if shown == nil { shown = target }
            return shown ?? target
        }
        let ease = Float(1 - exp(-dt / 0.12))
        color.red += (target.red - color.red) * ease
        color.green += (target.green - color.green) * ease
        color.blue += (target.blue - color.blue) * ease
        color.opacity += (target.opacity - color.opacity) * ease
        shown = color
        return color
    }
}

/// The call in its room: the phase, the live text and the controls.
private struct TalkLive: View {
    let session: TalkSession

    var body: some View {
        let phase = session.phase
        let muted = session.micReady && !session.micOn
        TalkPhaseView(words: phase.words, mode: TalkWave.Mode(phase: phase, muted: muted), session: session)
        TalkLines(lines: session.transcript.lines, cards: session.cards)
        TalkControls(session: session)
    }
}

/// The live text, newest at the bottom and kept in view as it grows.
private struct TalkLines: View {
    let lines: [TalkLine]
    /// Jamie's artifacts, each after the lines there were when it came.
    let cards: [TalkCard]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    ForEach(cards.filter { $0.after == index }) { TalkArtifactRow(artifact: $0.artifact) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.speaker == .you ? "You" : "Jamie")
                            .talkFont(13, .semibold, .footnote)
                            .foregroundStyle(Theme.secondaryText)
                        Text(line.text)
                            .talkFont(15, .regular, .body)
                            .foregroundStyle(line.isFinal || line.speaker == .agent ? Theme.text : Theme.secondaryText)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                ForEach(cards.filter { $0.after >= lines.count }) { TalkArtifactRow(artifact: $0.artifact) }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxHeight: .infinity)
    }
}

/// Jamie's voice, Mute and Hang up, and under them what stops the agent
/// hearing you. Without a session (still calling) no Mute.
private struct TalkControls: View {
    @Environment(AppModel.self) private var model
    let session: TalkSession?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: Theme.Space.md) {
                TalkVoiceToggle()
                if let session {
                    Button(action: session.toggleMicrophone) {
                        Image(systemName: session.micOn || !session.micReady ? "mic" : "mic.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(session.micOn ? Theme.text : Theme.secondaryText)
                            .frame(width: 52, height: 52)
                            .background(Theme.hover, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.micReady)
                    .accessibilityLabel(session.micOn ? "Mute" : "Unmute")
                }
                Button { model.talk.hangUp() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.buttonText)
                        .frame(width: 64, height: 52)
                        .background(Theme.destructive, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Hang up")
            }
            if let note = session.flatMap(Self.note) {
                Text(note)
                    .talkFont(13, .regular, .footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.lg)
    }

    private static func note(_ session: TalkSession) -> String? {
        if let failed = session.encryptionNotice { return failed }
        if session.micRefused { return "Peel can't use the microphone, so Jamie can't hear you. Allow it in Settings, then unmute." }
        if let notice = session.notice { return notice }
        return session.micOn || !session.micReady ? nil : "Muted: Jamie can't hear you."
    }
}

/// Jamie's voice, ♀ or ♂: a tap switches it, for this call (from Jamie's
/// next sentence) and the next (`TalkStore.toggleVoice`).
private struct TalkVoiceToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let voice = model.talk.voice
        Button { model.talk.toggleVoice() } label: {
            Text(verbatim: voice.glyph)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 52, height: 52)
                .background(Theme.hover, in: Circle())
        }
        .buttonStyle(.plain)
        .help(voice.accessibilityLabel)
        .accessibilityLabel(voice.accessibilityLabel)
        .accessibilityHint("Switches Jamie's voice")
    }
}

/// The call is over, or never started: why, then Try again and Close.
private struct TalkEnded: View {
    @Environment(AppModel.self) private var model
    let words: String

    var body: some View {
        Spacer()
        Text(words)
            .talkFont(15, .regular, .body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.xl)
            .textSelection(.enabled)
        HStack(spacing: Theme.Space.md) {
            Button("Close") { model.talk.hangUp() }
                .buttonStyle(.peel(.ghost, size: Self.size))
                .keyboardShortcut(.cancelAction)
            Button("Try again") { model.talk.tryAgain() }
                .buttonStyle(.peel(.primary, size: Self.size))
        }
        .padding(.top, Theme.Space.lg)
        Spacer()
    }

    #if os(iOS)
    private static let size = PeelButton.Size.touch
    #else
    private static let size = PeelButton.Size.md
    #endif
}

private extension View {
    /// A Mac size, which the phone scales with Dynamic Type as `style`.
    @ViewBuilder
    func talkFont(_ size: CGFloat, _ weight: Font.Weight, _ style: Font.TextStyle) -> some View {
        #if os(iOS)
        phoneFont(PhoneFont(size: size, weight: weight, style: style))
        #else
        font(Theme.font(size, weight))
        #endif
    }
}

#if os(macOS)
/// The Mac's Talk window: closing it (⌘W) hangs up, and it closes itself
/// when the call goes from anywhere else.
struct TalkWindow: View {
    static let id = "talk"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TalkView()
            .frame(minWidth: 360, minHeight: 480)
            .navigationTitle("Talk to Jamie")
            .onAppear { if model.talk.home == nil { dismissWindow(id: Self.id) } }
            .onChange(of: model.talk.home == nil) { _, gone in if gone { dismissWindow(id: Self.id) } }
            .onDisappear { model.talk.hangUp() }
    }
}
#endif
