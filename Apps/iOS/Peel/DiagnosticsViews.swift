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
/// Delete. No send, share or export from this sheet.
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

/// You › Diagnostics, always there: the event ring as text (how the last run
/// ended, then the recent events with their times), to read after a PIN
/// prompt. Copy and Share are the person's own act; nothing is sent
/// automatically. Clear empties the ring only, never a crash record.
struct DiagnosticsScreen: View {
    private static let eventLimit = 500
    @State private var text = ""
    @State private var copied = false
    @State private var confirmingClear = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(Theme.phoneGutter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                Text("Enums and numbers only: no names, messages, amounts or keys. The record stays on this iPhone; Copy and Share are yours to use, nothing is sent automatically.")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 12) {
                    Button { load() } label: { ActionLabel("Refresh") }
                        .secondaryAction()
                    Button {
                        Clipboard.copy(text)
                        copied = true
                    } label: { ActionLabel(copied ? "Copied" : "Copy") }
                        .secondaryAction()
                    ShareLink(item: text) { ActionLabel("Share") }
                        .secondaryAction()
                    Button { confirmingClear = true } label: { ActionLabel("Clear") }
                        .secondaryAction()
                }
            }
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.vertical, Theme.Space.md)
            .background(Theme.background)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .confirmationDialog("Clear the event record?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Diagnostics.clearEvents()
                load()
            }
        } message: {
            Text("Crash records are kept.")
        }
    }

    private func load() {
        copied = false
        let now = ISO8601DateFormatter().string(from: Date())
        text = "Now: \(now)\n" + Diagnostics.snapshot().rendered(limit: Self.eventLimit)
    }
}
