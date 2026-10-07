import SwiftUI
import PeelCore

/// One field takes either an invite link or the twelve words of an existing account.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var code = ""
    @State private var name = ""
    @State private var working = false
    @State private var problem: String?

    private var isInvite: Bool { code.trimmingCharacters(in: .whitespaces).hasPrefix("sphinx.chat://") }
    private var isMnemonic: Bool { code.split(whereSeparator: \.isWhitespace).count == 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Peel")
                    .font(.system(size: 34, weight: .semibold))
                    .kerning(-0.5)
                Text("Paste an invite link to start, or your twelve words to come back.")
                    .foregroundStyle(.secondary)
            }
            TextField("Invite link or twelve words", text: $code, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(isMnemonic ? "Open" : "Join") { Task { await go() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || !(isInvite || isMnemonic))
            }
        }
        .frame(width: 440)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { problem = model.notice }
    }

    private func go() async {
        working = true
        defer { working = false }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            if isInvite {
                try await model.signup(invite: code, name: trimmedName)
            } else {
                try await model.restore(mnemonic: code, name: trimmedName)
            }
        } catch {
            problem = "\(error)"
        }
    }
}
