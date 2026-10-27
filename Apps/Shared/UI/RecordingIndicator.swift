import SwiftUI
import PeelUI

/// "This call is being recorded": a pulsing red dot and "Recording". Only
/// shown while the call server records; Peel has no way to start or stop it.
/// The dot holds still when Reduce Motion is on.
///
/// ```swift
/// if call.isRecording { RecordingIndicator() }
/// ```
struct RecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faded = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle()
                .fill(Theme.destructive)
                .frame(width: 8, height: 8)
                .opacity(faded && !reduceMotion ? 0.3 : 1)
            Text("Recording")
                .font(Theme.font(12, .medium))
                .foregroundStyle(Theme.destructive)
                .lineLimit(1)
        }
        .fixedSize()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { faded = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This call is being recorded")
    }
}

/// The notice over a call when its recording starts or stops: red for
/// "recording", gone after 5 seconds.
///
/// ```swift
/// content.recordingToast($toast)
/// ```
struct RecordingToast: View {
    let text: String
    let recording: Bool

    var body: some View {
        Text(text)
            .font(Theme.font(13, .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(recording ? Theme.buttonText : Theme.text)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .background(recording ? Theme.destructive : Theme.menu,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows `text` at the top for 5 seconds, then clears it. Setting new
    /// text restarts the time.
    func recordingToast(_ text: Binding<String?>) -> some View {
        overlay(alignment: .top) {
            if let words = text.wrappedValue {
                RecordingToast(text: words, recording: words == RecordingNotice.started)
                    .padding(.top, 48)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: words) {
                        try? await Task.sleep(for: .seconds(5))
                        if !Task.isCancelled { text.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: text.wrappedValue)
    }
}
