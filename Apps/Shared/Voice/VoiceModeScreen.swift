import PeelCore
import PeelUI
import SwiftUI

/// Voice Mode, the alternative default interface (docs/voice-mode.md, "Voice
/// Mode screen"): a mic in the middle of a linen canvas, a small text box at
/// the bottom, and a grid icon at the top right for the standard view. What
/// is said or typed goes to the agent's DM, through the controller's own
/// send path and `AppModel.sendDictated`.
struct VoiceModeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shows the standard interface for the rest of this launch.
    let showStandard: () -> Void

    @State private var voice = VoiceModeController()
    @State private var typing = false
    @State private var text = ""
    @State private var sendFailed = false
    @FocusState private var focused: Bool

    private var chat: String? { model.agentChat }
    private var listening: Bool { voice.phase.isActive }

    var body: some View {
        ZStack {
            LinenBackground()
            VStack(spacing: Theme.Space.lg) {
                mic
                status
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: typing ? -80 : 0)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: showStandard) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Standard view", tableName: "Shared"))
            .padding(Theme.Space.sm)
        }
        .overlay(alignment: .bottom) { textBox.padding(Theme.Space.md) }
        .onAppear { attach() }
        .onDisappear { voice.stop() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && text.isEmpty { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { typing = false } }
        }
    }

    private func attach() {
        voice.attach(model, hooks: .init(
            isAnswering: { model.agentUnanswered != nil },
            isWaitingApproval: { model.agentChat.map { model.waitingCards[$0] != nil } == true },
            stopAgentTurn: nil,
            blocked: { nil }
        ))
    }

    // MARK: Mic

    private var mic: some View {
        Button {
            guard chat != nil else { return }
            focused = false
            voice.toggle()
        } label: {
            ZStack {
                if listening && !reduceMotion { PulsingRings() }
                Circle()
                    .fill(.background.opacity(0.55))
                    .frame(width: 132, height: 132)
                    .shadow(color: Color.accentColor.opacity(listening ? 0.55 : 0.3), radius: listening ? 36 : 24)
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 132, height: 132)
                Image(systemName: listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 260, height: 260)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? Text("Stop listening", tableName: "Shared") : Text("Talk to Peel", tableName: "Shared"))
    }

    private var status: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.xl)
            .frame(minHeight: 44, alignment: .top)
    }

    /// The notice the controller posts when speech is refused or cannot run
    /// (words that suggest typing), else where the voice stands.
    private var message: String {
        guard let chat else { return String(localized: "Peel's chat isn't set up yet. Set it up from the standard view.", table: "Shared") }
        if sendFailed { return String(localized: "Could not send that. Try again.", table: "Shared") }
        if let notice = model.conversationNotices[chat] {
            return notice + " " + String(localized: "You can type a message instead.", table: "Shared")
        }
        switch voice.phase {
        case .idle: return String(localized: "Tap the mic and talk to Peel", table: "Shared")
        case .hearing: return voice.draft
        default: return voice.phase.label
        }
    }

    // MARK: Text box

    @ViewBuilder private var textBox: some View {
        if typing {
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                TextField(text: $text, axis: .vertical) { Text("Type a message…", tableName: "Shared") }
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel(Text("Send", tableName: "Shared"))
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: 520)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Button {
                withAnimation(.spring(duration: 0.45, bounce: 0.3)) { typing = true }
                focused = true
            } label: {
                Text("Type a message…", tableName: "Shared")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.sm)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }

    private var canSend: Bool { chat != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard let chat, canSend else { return }
        let sent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await model.sendDictated(sent, to: chat) {
                text = ""
                sendFailed = false
                focused = false
            } else {
                sendFailed = true
            }
        }
    }
}

/// Rings that grow and fade while the mic listens.
private struct PulsingRings: View {
    @State private var out = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.accentColor.opacity(out ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 132, height: 132)
                    .scaleEffect(out ? 1.95 : 1)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(index) * 0.8), value: out)
            }
        }
        .onAppear { out = true }
        .accessibilityHidden(true)
    }
}
