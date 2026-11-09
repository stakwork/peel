import PeelUI
import SwiftUI

/// The button in the agent chat's composer that turns voice mode on and off.
struct VoiceModeButton: View {
    let voice: VoiceModeController
    var size: CGFloat = 44

    var body: some View {
        Button { voice.toggle() } label: {
            Image(systemName: voice.phase.isActive ? "waveform.circle.fill" : "waveform")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.phase.isActive ? "End voice mode" : "Talk to Peel")
        .accessibilityHint(voice.phase.isActive ? "" : "Speak to the agent and hear its answers")
        .help(voice.phase.isActive ? "End voice mode" : "Talk to Peel")
    }
}

/// The "?" beside voice mode's button and in its panel: a popover with the
/// phrases to say, from `VoiceCommandPhrases.english` so it never drifts.
struct VoiceHelpButton: View {
    var size: CGFloat = 44
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 17, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Voice mode phrases")
        .help("Voice mode phrases")
        .popover(isPresented: $shown) {
            VoicePhrases()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// What to say in voice mode: the first phrase of each command.
private struct VoicePhrases: View {
    private static let lines: [(VoiceCommand, String)] = [
        (.send, "Send what you said"),
        (.discard, "Throw it away"),
        (.stopSpeaking, "Stop reading"),
        (.repeatReply, "Read the last reply again"),
        (.readAll, "Read a summarised reply in full"),
        (.stopAgent, "Stop the agent's answer"),
        (.mute, "Stop listening (Peel unmute to resume)"),
        (.deactivate, "Turn voice mode off"),
    ]

    var body: some View {
        let table = VoiceCommandPhrases.english
        VStack(alignment: .leading, spacing: 8) {
            Text("Say Peel, then a command")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Self.lines, id: \.0) { command, meaning in
                    if let phrase = table.phrases[command]?.first {
                        GridRow {
                            Text("Peel \(phrase)").fontWeight(.semibold)
                            Text(meaning).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.callout)
            if let wake = VoiceCommandPhrases.english.phrases[.activate]?.first {
                Text("\"\(wake.capitalized)\" starts voice mode when listening for it is on in settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// The compact panel that takes the composer's place while voice mode is
/// on: what it is doing, the draft as it is heard, a level meter, and the
/// big buttons.
struct VoicePanel: View {
    let voice: VoiceModeController

    var body: some View {
        let phase = voice.phase
        let muted = voice.isMuted
        let status = muted ? "Muted — say Peel unmute" : phase.label
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: muted ? "mic.slash.fill" : icon(phase))
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.headline)
                    Spacer(minLength: 0)
                    LevelMeter(level: phase == .speaking || muted ? 0 : voice.level)
                        .opacity(muted ? 0.35 : 1)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(muted ? "Muted. Say Peel unmute to listen again." : phase.label)
                VoiceHelpButton(size: 28)
            }
            if !voice.draft.isEmpty {
                Text(voice.draft)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("What you said: \(voice.draft)")
            } else if phase == .listening, !muted {
                Text("Say Peel send when you are done.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            HStack(spacing: 10) {
                Button(role: .destructive) { voice.stop() } label: {
                    Label("End voice mode", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("End voice mode")
                if phase == .speaking {
                    Button { voice.stopSpeaking() } label: {
                        Label("Stop speaking", systemImage: "speaker.slash.fill")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop speaking")
                }
                Button { voice.toggleMute() } label: {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "mic.fill" : "mic.slash.fill")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(muted ? "Unmute the microphone" : "Mute the microphone")
                if phase == .hearing, !muted {
                    Button { voice.sendNow() } label: {
                        Label("Send", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func icon(_ phase: VoicePhase) -> String {
        switch phase {
        case .speaking: "speaker.wave.2.fill"
        case .waiting, .sending: "ellipsis.bubble.fill"
        default: "mic.fill"
        }
    }
}

/// A bar that grows with the loudness of the microphone.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        Capsule()
            .fill(.tint.opacity(0.25))
            .frame(width: 56, height: 8)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.tint)
                    .frame(width: 56 * CGFloat(max(0.04, min(1, level))), height: 8)
            }
            .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// The fields of the Voice mode setting, for the phone's You tab and the
/// Mac's agent settings to put in their own section. Device-local, so
/// `@AppStorage`, not the synced `Preferences` (docs/voice-mode.md).
struct VoiceModeSettingsFields: View {
    @AppStorage(VoiceDefaults.spokenRepliesKey) private var spokenReplies = VoiceDefaults.spokenReplies
    @AppStorage(VoiceDefaults.autoSendKey) private var autoSend = VoiceDefaults.autoSend
    @AppStorage(VoiceDefaults.autoSendSecondsKey) private var seconds = VoiceDefaults.autoSendSeconds
    @AppStorage(VoiceDefaults.wakeListenKey) private var wakeListen = VoiceDefaults.wakeListen
    @AppStorage(VoiceDefaults.pauseOtherAudioKey) private var pauseOtherAudio = VoiceDefaults.pauseOtherAudio
    @AppStorage(VoiceDefaults.speechRateKey) private var rate = VoiceDefaults.speechRate

    var body: some View {
        Toggle("Spoken replies", isOn: $spokenReplies)
        Toggle("Send after a pause", isOn: $autoSend)
        if autoSend {
            Stepper(value: $seconds, in: VoiceDefaults.autoSendRange, step: 1) {
                Text("Pause: \(seconds.formatted(.number.precision(.fractionLength(0)))) s")
            }
        }
        Toggle("Listen for \"Hey Peel\" while this chat is open", isOn: $wakeListen)
        #if os(iOS)
        // The Mac has no app audio session to pause other apps with.
        Toggle("Pause music while voice mode is on", isOn: $pauseOtherAudio)
        #endif
        Stepper(value: $rate, in: VoiceDefaults.speechRateRange, step: 0.1) {
            Text("Speaking speed: \(rate.formatted(.number.precision(.fractionLength(1))))×")
        }
        let quality = VoiceSpeaker.installedQuality()
        VStack(alignment: .leading, spacing: 2) {
            Text(quality.label)
            if quality < .enhanced {
                Text(VoiceQuality.downloadHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
