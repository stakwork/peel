import Foundation
import PeelCore
import PeelDiagnostics

/// The record of the last run's problem, as the sheet shows it: redacted
/// text only (docs/diagnostics.md). Nothing here sends or exports it; the
/// agent reads it itself when asked (`DeviceReads`).
public struct DiagnosticRecord: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
}

extension AppModel {
    /// Peel left the front (the Mac's app resigning, the phone's background).
    public func leftForeground() {
        Diagnostics.setForeground(false)
        activeLease.isForeground = false
        updateActiveLease()
        // A catch-up in flight goes on under a background task for at most `backgroundCatchUpBound`, and
        // is abandoned at the end of it (or at expiry): the next foreground asks again from the cursor.
        if let engine {
            let work = platform.backgroundWork
            let token = work.begin(name: "peel.catchup") { Task { await engine.expireBackgroundCatchUp() } }
            Task {
                if await engine.appLeftForeground(keepingCatchUp: true) { await engine.finishBackgroundCatchUp() }
                work.end(token)
            }
        }
        // Only an account whose reads have loaded: an empty count would clear it.
        if phase == .ready, !readStates.isEmpty { notifier.leftForeground(unread: unreadCount) }
    }

    /// Opens the record: the newest crash report, redacted now with this
    /// account's tribe names and keys kept and its contacts' names removed
    /// (built here, never stored), or the ring alone when the run was ended
    /// without a report.
    public func showDiagnosticRecord() async {
        let names = DiagnosticsNames(chats: conversations, myAlias: myAlias)
        let report = try? await Diagnostics.latestRedactedReport(allow: names.allow, knownNames: names.knownNames)
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
