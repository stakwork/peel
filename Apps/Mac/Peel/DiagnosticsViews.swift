import SwiftUI
import PeelUI

/// The notice under the detail column when the last run ended badly: Peel
/// recorded it on this Mac, and the record can be read, copied or deleted.
/// Nothing is sent anywhere (docs/diagnostics.md).
struct DiagnosticsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Callout(
            detail: "Peel recorded a problem from the last run. The record stays on this Mac.",
            icon: .problem, dismiss: { model.diagnosticsNotice = false }
        ) {
            Button("Show record") { Task { await model.showDiagnosticRecord() } }
                .buttonStyle(.peel(.link))
        }
    }
}

/// The redacted record in a scrolling monospaced view, with Copy and Delete.
/// No send, share or export.
struct DiagnosticRecordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: DiagnosticRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Problem record")
                .font(Theme.font(15, .semibold))
            Text("Names, amounts, keys and paths are removed where Peel could find them. Nothing has been sent.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
            ScrollView([.vertical, .horizontal]) {
                Text(record.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.divider))
            HStack {
                CopyButton("Copy", text: record.text)
                    .buttonStyle(.peel(.outline))
                Button("Delete") { model.deleteDiagnosticRecord() }
                    .buttonStyle(.peel(.outline))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.peel(.primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640, height: 520)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
    }
}
