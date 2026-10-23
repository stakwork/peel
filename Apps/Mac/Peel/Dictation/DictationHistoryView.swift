import PeelCore
import PeelUI
import SwiftUI

/// Dictation History (docs/dictation.md, "History"): what was dictated,
/// newest first by day, each with where it went and Copy, so text that
/// reached no field can be had again. The open account's own, and only
/// while it is unlocked (`AppModel.unlockedStorage`).
struct DictationHistoryView: View {
    static let id = "dictation-history"
    /// The newest this many; older ones stay until their 30 days are up.
    private static let shown = 500

    private enum Load {
        case loading
        case days([Day])
        case failed(String)
    }

    private struct Day: Identifiable {
        let start: Date
        var records: [DictationRecord]
        var id: Date { start }
    }

    @Environment(AppModel.self) private var model
    @State private var load = Load.loading
    private var dictation: DictationController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.divider.frame(height: 1)
            content
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .task(id: model.unlockedStorage.map(ObjectIdentifier.init)) { await watch() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Text(dictation.historyOn
                 ? "Kept on this Mac for 30 days. Nothing is sent anywhere."
                 : "History is off: new dictations aren't kept.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .days(let days) = load, !days.isEmpty, let storage = model.unlockedStorage {
                InlineConfirm(prompt: "Clear every dictation?", confirm: "Clear", alignment: .trailing) {
                    do { try await storage.clearDictations() } catch { load = .failed("History couldn't be cleared") }
                } trigger: {
                    Text("Clear History")
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    @ViewBuilder private var content: some View {
        if model.unlockedStorage == nil {
            EmptyState("Unlock Peel to see your dictations")
        } else {
            switch load {
            case .loading:
                Color.clear
            case .failed(let problem):
                EmptyState(problem)
            case .days(let days) where days.isEmpty:
                EmptyState("What you dictate shows here, so you can copy it again")
            case .days(let days):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.records) { DictationHistoryRow(record: $0) }
                            } header: {
                                SectionHeader(Formatting.dayHeading(day.start))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.Space.lg)
                                    .padding(.vertical, Theme.Space.sm)
                                    .background(Theme.background)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.lg)
                }
            }
        }
    }

    private func watch() async {
        load = .loading
        guard let storage = model.unlockedStorage else { return }
        do {
            // Nothing past its 30 days, though nothing new was dictated to drop it.
            try await storage.dropDictations(olderThan: DictationDefaults.historyKeep)
            for try await records in storage.dictations(limit: Self.shown) {
                load = .days(Self.byDay(records))
            }
        } catch {
            load = .failed("History couldn't be read")
        }
    }

    /// Newest first, as they come, in one group per calendar day.
    private static func byDay(_ records: [DictationRecord]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for record in records {
            let start = calendar.startOfDay(for: record.date)
            if days.last?.start == start {
                days[days.count - 1].records.append(record)
            } else {
                days.append(Day(start: start, records: [record]))
            }
        }
        return days
    }
}

/// One dictation: its time in a column, the app, the text (three lines, all
/// on a click), where it went when it was not typed, and Copy.
private struct DictationHistoryRow: View {
    let record: DictationRecord
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(Formatting.time(record.date))
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let text = record.text {
                    Text(text)
                        .font(Theme.font(13))
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { expanded.toggle() }
                }
                Text(detail)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let text = record.text {
                CopyButton("Copy", text: text)
                    .buttonStyle(.peel(.outline, size: .sm))
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
    }

    /// The app, then where the text went when it was not typed.
    private var detail: String {
        let app = (record.appName ?? "Unknown app") + (record.heard.map { " · heard “\($0)”" } ?? "")
        switch record.outcome {
        case .typed: return app
        case .copied: return "\(app) · Copied, not typed" + (record.note.map { ": \($0)" } ?? "")
        case .blocked: return "\(app) · Not kept: " + (record.note ?? "a password field")
        case .failed: return "\(app) · " + (record.note ?? "No text")
        }
    }
}
