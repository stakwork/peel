import Foundation
import PeelCore
import PeelDiagnostics

/// The record of the last run's problem, as the sheet shows it: redacted
/// text only (docs/diagnostics.md). Nothing here sends or exports it.
public struct DiagnosticRecord: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
}

extension AppModel {
    /// Peel left the front (the Mac's app resigning, the phone's background).
    public func leftForeground() {
        Diagnostics.setForeground(false)
    }

    /// Opens the record: the newest crash report, redacted now with this
    /// account's tribe names and keys kept and its contacts' names removed
    /// (built here, never stored), or the ring alone when the run was ended
    /// without a report.
    public func showDiagnosticRecord() async {
        let tribes = conversations.filter(\.isTribe)
        let allow = tribes.compactMap(\.alias) + tribes.map(\.chat)
        let people = conversations.filter { !$0.isTribe }.compactMap(\.alias) + [myAlias].compactMap { $0 }
        let report = try? await Diagnostics.latestRedactedReport(allow: allow, knownNames: people)
        let text = report?.rendered() ?? Diagnostics.snapshot().rendered()
        diagnosticsRecord = DiagnosticRecord(text: text)
    }

    /// Removes the record, raw and redacted, and the notice.
    public func deleteDiagnosticRecord() {
        Diagnostics.deleteRecords()
        diagnosticsRecord = nil
        diagnosticsNotice = false
    }
}
