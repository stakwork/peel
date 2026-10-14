import Foundation
import PeelCore

extension AppModel {
    /// Rows with the sender's zone when they wrote: a run's first message's
    /// own offset, else the sender's newest earlier on the page, else their
    /// newest within 90 days before it from storage (one query for the page,
    /// off the main thread, one answer per sender, kept in `senderZoneCache`;
    /// the rows are worked out again when it comes back); the rest of a run
    /// take their own offset or the run's. Never on yours.
    public func withSenderZones(_ rows: [ChatRow], in chat: String) -> [ChatRow] {
        var rows = rows
        // The chat open and its thread share a chat; others are let go.
        if senderZoneCache[chat] == nil { senderZoneCache = senderZoneCache.filter { $0.key == selectedChat } }
        let cache = senderZoneCache[chat] ?? [:]
        // By sender: a tribe member's alias, or "" for the contact.
        var latest: [String: TimeZone] = [:]
        // Each sender still to look up, at their first run's first message.
        var unresolved: [String: Int64] = [:]
        var runZone: TimeZone?
        for index in rows.indices where rows[index].kind == .message {
            let row = rows[index]
            guard !row.message.fromMe, !row.inTribe || row.member != nil else {
                if row.startsRun { runZone = nil }
                continue
            }
            let sender = row.member ?? ""
            let first = row.images.first ?? row.message
            if row.startsRun {
                runZone = first.senderTimeZone ?? latest[sender] ?? cache[sender] ?? nil
                if runZone == nil, cache[sender] == nil, unresolved[sender] == nil, let timestamp = first.timestamp {
                    unresolved[sender] = timestamp
                }
                rows[index].senderZone = runZone
            } else {
                rows[index].senderZone = row.message.senderTimeZone ?? runZone
            }
            if let zone = row.shown.last(where: { $0.senderTZ != nil })?.senderTimeZone { latest[sender] = zone }
        }
        lookUpSenderZones(unresolved, in: chat)
        return rows
    }

    /// Reads the senders' zones from storage off the main thread, keeps
    /// them, and works the rows out again with them. A sender already being
    /// looked up is not asked twice; one whose read failed is asked again
    /// at the next rebuild.
    private func lookUpSenderZones(_ wanted: [String: Int64], in chat: String) {
        let senders = wanted.keys.filter { !(senderZonesAsked[chat]?.contains($0) ?? false) }
        guard !senders.isEmpty, let storage = engine?.storage else { return }
        senderZonesAsked[chat, default: []].formUnion(senders)
        let inTribe = isTribe(chat)
        let points = senders.map { (alias: inTribe ? $0 : nil, timestamp: wanted[$0]!) }
        Task {
            let found = try? await Task.detached {
                try storage.senderTimeZones(in: chat, inTribe: inTribe, wanted: points)
            }.value
            senderZonesAsked[chat]?.subtract(senders)
            guard let found, engine?.storage === storage, chat == selectedChat else { return }
            for (position, sender) in senders.enumerated() {
                senderZoneCache[chat, default: [:]][sender] = .some(found[position])
            }
            rebuildRows()
        }
    }

    /// Their offset minus yours at `date`, in seconds: positive when they
    /// are ahead. Yours is this Mac's, the zone every time on screen is in
    /// (a zone chosen in Account is what you send, not what you see).
    public func difference(_ zone: TimeZone, at date: Date = .now) -> Int {
        zone.secondsFromGMT(for: date) - TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)
    }

    /// "20:02 your time · 02:02 for Evan", for a message's time when the
    /// sender's offset then was not yours.
    public func timeTooltip(_ date: Date, zone: TimeZone?, name: String) -> String? {
        guard let zone, difference(zone, at: date) != 0 else { return nil }
        return "\(Formatting.time(date, in: .autoupdatingCurrent)) your time · \(Formatting.time(date, in: zone)) for \(name)"
    }

    /// "02:14 local time · 6 h ahead": someone's time now, when their
    /// offset is not yours.
    public func localTimeLine(_ local: LocalTime?, at now: Date) -> String? {
        guard let local, let offset = Formatting.offset(difference(local.zone, at: now)) else { return nil }
        return "\(Formatting.time(now, in: local.zone)) local time · \(offset)"
    }

    /// A contact's local time, or with `member` a tribe member's; nil when
    /// they have not shared one in 90 days.
    public func localTime(of chat: String, member: String?) async -> LocalTime? {
        try? await engine?.localTime(of: chat, member: member)
    }

    /// Whether your offset goes with what you send in `chat`: on unless
    /// turned off; nil before an account is open.
    public func timeZoneSharing(in chat: String) async -> Bool? {
        guard let engine else { return nil }
        return (try? await engine.timeZoneSharing(in: chat)) ?? true
    }

    /// Turns sharing your offset on or off in a direct message or a private tribe.
    public func setTimeZoneSharing(_ on: Bool, in chat: String) async throws {
        try await signedIn().setTimeZoneSharing(on, in: chat)
    }

    /// Chooses this account's zone (an IANA name), or nil for this Mac's.
    public func setTimeZone(_ identifier: String?) async throws {
        try await signedIn().setTimeZone(identifier)
    }
}
