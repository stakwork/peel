import PeelCore
import PeelUI
import SwiftUI

// The Talk call screen (docs/talk.md), the phone's full-screen cover and
// the Mac's Talk window alike: the org on top, what Jamie is doing, the
// live text, then Mute and Hang up. Calling, a refusal in the home's own
// words, and a call that ended show here too.

struct TalkView: View {
    @Environment(AppModel.self) private var model

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
                TalkPhaseView(words: "Calling Jamie…", systemImage: nil, lit: false)
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
    }
}

/// What Jamie is doing, large: a glyph in a circle, lit while it speaks,
/// and the words under it.
private struct TalkPhaseView: View {
    let words: String
    let systemImage: String?
    let lit: Bool

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle()
                    .fill(lit ? Theme.accent : Theme.hover)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(lit ? Theme.buttonText : Theme.text)
                } else {
                    ProgressView()
                }
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

/// The call in its room: the phase, the live text and the controls.
private struct TalkLive: View {
    let session: TalkSession

    var body: some View {
        let phase = session.phase
        TalkPhaseView(words: phase.words, systemImage: Self.image(phase), lit: phase == .speaking)
        TalkLines(lines: session.transcript.lines)
        TalkControls(session: session)
    }

    private static func image(_ phase: TalkPhase) -> String? {
        switch phase {
        case .listening: "ear"
        case .thinking: "ellipsis"
        case .speaking: "waveform"
        case .waiting(left: true): "person.slash"
        default: nil
        }
    }
}

/// The live text, newest at the bottom and kept in view as it grows.
private struct TalkLines: View {
    let lines: [TalkLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(lines) { line in
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
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxHeight: .infinity)
    }
}

/// Mute and Hang up, and under them what stops the agent hearing you.
/// Without a session (still calling) only Hang up.
private struct TalkControls: View {
    @Environment(AppModel.self) private var model
    let session: TalkSession?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: Theme.Space.md) {
                if let session {
                    Button(action: session.toggleMicrophone) {
                        Image(systemName: session.micOn ? "mic" : "mic.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(session.micOn ? Theme.text : Theme.secondaryText)
                            .frame(width: 52, height: 52)
                            .background(Theme.hover, in: Circle())
                    }
                    .buttonStyle(.plain)
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
        if session.micRefused { return "Peel can't use the microphone, so Jamie can't hear you. Allow it in Settings, then unmute." }
        if let notice = session.notice { return notice }
        return session.micOn ? nil : "Muted: Jamie can't hear you."
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
