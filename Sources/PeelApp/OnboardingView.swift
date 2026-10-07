import SwiftUI
import PeelCore

/// Takes an invite link. Twelve words come back with Keychain storage (phase 2).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var code = ""
    @State private var name = ""
    @State private var working = false
    @State private var problem: String?

    private var ready: Bool {
        !working && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Peel")
                    .font(.system(size: 34, weight: .semibold))
                    .kerning(-0.5)
                Text("Paste an invite link to start.")
                    .foregroundStyle(.secondary)
            }
            TextField("Invite link", text: $code, axis: .vertical)
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
                Button("Continue") { Task { await go() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
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
            try await model.join(code, name: name.trimmingCharacters(in: .whitespaces))
        } catch {
            problem = "\(error)"
        }
    }
}
