import PeelUI
import SwiftUI

/// A row at the top of Chats when the last run ended badly: Peel recorded
/// it on this iPhone, and the record can be read, copied or deleted.
/// Nothing is sent anywhere (docs/diagnostics.md).
struct DiagnosticsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Peel recorded a problem from the last run. The record stays on this iPhone.")
                    .phoneFont(.row)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.attention)
            }
            HStack(spacing: 16) {
                Button("Show record") { Task { await model.showDiagnosticRecord() } }
                Button("Dismiss") { model.diagnosticsNotice = false }
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.borderless)
            .phoneFont(.row)
        }
        .padding(.vertical, 4)
    }
}

/// The redacted record in a scrolling monospaced view, with Copy and
/// Delete. No send, share or export.
struct DiagnosticRecordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: DiagnosticRecord
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(record.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(Theme.phoneGutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    Text("Names, amounts, keys and paths are removed where Peel could find them. Nothing has been sent.")
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.secondaryText)
                    HStack(spacing: 12) {
                        Button {
                            Clipboard.copy(record.text)
                            copied = true
                        } label: { ActionLabel(copied ? "Copied" : "Copy") }
                            .secondaryAction()
                        Button { model.deleteDiagnosticRecord() } label: { ActionLabel("Delete") }
                            .secondaryAction()
                    }
                }
                .padding(.horizontal, Theme.phoneGutter)
                .padding(.vertical, Theme.Space.md)
                .background(Theme.background)
            }
            .background(Theme.background.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .navigationTitle("Problem record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}
