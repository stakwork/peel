import Foundation

/// The official apps' preferences file, decrypted: `{"items": [{"key",
/// "identifier", "date", "value"}]}` (`DataSyncModels.swift:27-122`), read
/// and merged without the network (`docs/phases/11-preferences-sync.md`).
/// Everything Peel does not change goes back as it came: other keys,
/// duplicates, extra fields, other top-level fields.
/// One preference by its key and identifier, as the file and the store name it.
public struct PreferenceID: Hashable, Sendable {
    public let key: String
    public let identifier: String
}

struct PreferencesFile: Equatable {
    /// Every top-level field but `items`.
    var others: [String: JSONValue] = [:]
    var items: [[String: JSONValue]] = []

    init() {}

    /// The file as the official apps read it, or `unreadablePreferences`
    /// (Peel then neither reads nor writes it: the Mac app stops syncing on
    /// such a file, and the older iOS app replaces it with its own items) if any item
    /// would make them fail: an item that is not an object, a `key`,
    /// `identifier` or `date` that is not a string, or a value none of
    /// their kinds reads (`DataSyncModels.swift:134-199`).
    init(text: String) throws {
        guard case .object(var fields)? = JSONValue(text: text),
              case .array(let list)? = fields.removeValue(forKey: "items") else { throw Engine.Failure.unreadablePreferences }
        items = try list.map { value in
            guard case .object(let item) = value, item["key"]?.string != nil, item["identifier"]?.string != nil,
                  item["date"]?.string != nil, let value = item["value"], Self.officialReads(value) else {
                throw Engine.Failure.unreadablePreferences
            }
            return item
        }
        others = fields
    }

    var text: String {
        get throws {
            var fields = others
            fields["items"] = .array(items.map(JSONValue.object))
            return try JSONValue.object(fields).text
        }
    }

    /// Whether the official apps' `SettingValue` reads `value`: a string, an
    /// int or a bool, or an object of one of their three kinds.
    static func officialReads(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .int, .bool:
            return true
        case .object(let fields):
            let strings = { (names: [String]) in names.allSatisfy { fields[$0]?.string != nil } }
            return strings(["chat_pubkey", "feed_url", "feed_id", "subscribed", "sats_per_minute", "player_speed", "item_id"])
                || strings(["duration", "current_time"]) || strings(["timezone_enabled"]) || strings(["timezoneEnabled"])
        default:
            return false
        }
    }

    /// An item's date in seconds, if it reads as one (finite: "nan" and
    /// "inf" parse but are no date).
    static func readDate(of item: [String: JSONValue]) -> Double? {
        item["date"]?.string.flatMap(TimeInterval.init).flatMap { $0.isFinite ? $0 : nil }
    }

    /// An item's date in seconds; one that does not read counts as the
    /// oldest, so a choice made here replaces it. (The official apps count
    /// it as now, `DataSyncModels.swift:108-113`, which would let it beat
    /// every change forever; replacing it gives them a readable date.)
    static func date(of item: [String: JSONValue]) -> Double {
        readDate(of: item) ?? 0
    }

    /// A row a sync takes from the file, and the stored row it was merged
    /// against (nil if there was none): it is written only over that.
    struct Change: Equatable, Sendable {
        let row: PreferenceRow
        let expected: PreferenceRow?
    }

    /// What a sync does: the file to upload if it changed (and which items
    /// it changed), and the rows to apply here.
    struct Merge {
        var file: PreferencesFile
        var uploads: [PreferenceID] = []
        var apply: [Change] = []
        /// Secret values taken from the file, for the Keychain; the row
        /// that dates each is in `apply`, a placeholder.
        var secrets: [SecretChange] = []
        /// Secrets the file holds that differ from what is connected here
        /// and were not taken (no value, never the file's key).
        var differing: [PreferenceID] = []
        var changed: Bool { !uploads.isEmpty }
    }

    /// Merges the stored preferences into the file, per key and identifier,
    /// for the keys that follow the account. With the same key and
    /// identifier more than once, the last copy is the file's value, as in
    /// the official apps, which apply every item in order.
    ///
    /// 1. Stored strictly newer: it replaces the item, every copy of it.
    /// 2. Otherwise the file's wins and is applied, if it is a value of the
    ///    key and its apply policy takes it over the stored one; if not, the
    ///    stored row keeps its value and takes the file's date.
    /// 3. In the file only: applied, likewise.
    /// 4. Stored only: added if chosen on a device (date above 0); one from
    ///    before sync only under a `peel.` key, with date 0, so any real
    ///    choice beats it, and an official key is never pushed from it.
    ///    With `bootstrapping` (no file yet), only rows dated from it on go,
    ///    so a file started anew holds only what was chosen since.
    ///
    /// A stored value the official apps would rewrite is never uploaded,
    /// nor is any row of an import-only key (`Entry.uploads`).
    ///
    /// `keys` are the keys this device syncs (`Preferences.syncedKeys(enabling:)`):
    /// any other stays in the file as it is. `secrets` holds the real value
    /// of each secret key as this device has it now (from the Keychain, for
    /// this call only; none for none connected). A secret's row holds a
    /// placeholder and a date, and is ordered like any other: its value
    /// goes up from `secrets`, never from the row. One from the file is
    /// taken only where none is connected here and it is newer than the
    /// row (or there is none); a different one is never taken over what is
    /// connected: it is left, its date taken, and listed in `differing`.
    func merged(
        with rows: [PreferenceRow], bootstrapping since: Double? = nil, now: Date = .now,
        keys: Set<String> = Preferences.synced, secrets: [String: JSONValue] = [:]
    ) -> Merge {
        var merge = Merge(file: self)
        var copies: [PreferenceID: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let key = item["key"]?.string, let identifier = item["identifier"]?.string,
                  keys.contains(key) else { continue }
            copies[PreferenceID(key: key, identifier: identifier), default: []].append(index)
        }
        /// The file's date for a row that keeps its value, at most a day
        /// ahead of this clock: a garbage date would otherwise carry every
        /// later change here with it.
        func raise(_ row: PreferenceRow?, to dated: Double?) {
            if let row, let dated, case let date = min(dated, (now.timeIntervalSince1970 + 86_400).rounded(.down)),
               date > row.updatedAt {
                var raised = row
                raised.updatedAt = date
                merge.apply.append(Change(row: raised, expected: row))
            }
        }
        func applySecret(_ item: [String: JSONValue], _ pair: PreferenceID, _ entry: Preferences.Entry, over row: PreferenceRow?) {
            let dated = Self.readDate(of: item)
            let date = dated ?? 0
            guard let value = item["value"], entry.takes(value, nil) else { return raise(row, to: dated) }
            if let local = secrets[pair.key] {
                // The same key is already here; a different one is not taken over it.
                if !entry.sameSecret(value, local) { merge.differing.append(pair) }
                return raise(row, to: dated)
            }
            // None connected: the file's is taken once, when it is newer than
            // what was last seen. A person who disconnected is not given it
            // back by the same item on the next sync.
            guard row == nil || date > row?.updatedAt ?? 0 else { return }
            merge.secrets.append(SecretChange(pair: pair, value: value))
            merge.apply.append(Change(
                row: PreferenceRow(key: pair.key, identifier: pair.identifier, value: Storage.secretPlaceholder, updatedAt: date),
                expected: row
            ))
        }
        func apply(_ item: [String: JSONValue], _ pair: PreferenceID, over row: PreferenceRow?) {
            let dated = Self.readDate(of: item)
            let date = dated ?? 0
            guard let value = item["value"], let entry = Preferences.registry[pair.key] else { return }
            if entry.scope == .secret { return applySecret(item, pair, entry, over: row) }
            let normal = entry.normalised(value)
            guard entry.takes(normal, row.flatMap { JSONValue(text: $0.value) }), let text = try? normal.text else {
                // Refused here (a looser threshold, or no value of the key's):
                // this device keeps its value but takes the file's date, so
                // a later change here is dated after the file's and replaces it.
                raise(row, to: dated)
                return
            }
            // The same value takes the file's date only if it has one, or
            // an undated item would be applied again on every sync.
            if text == row?.value, date == row?.updatedAt || dated == nil { return }
            merge.apply.append(Change(
                row: PreferenceRow(key: pair.key, identifier: pair.identifier, value: text, updatedAt: date), expected: row
            ))
        }
        /// The row as the file's item: a secret's value comes from `secrets`,
        /// never from the row, and none is made for an empty one; an
        /// import-only key has none.
        func uploadItem(_ row: PreferenceRow) -> [String: JSONValue]? {
            guard let entry = Preferences.registry[row.key], entry.uploads else { return nil }
            guard entry.scope == .secret else { return row.item }
            guard let value = secrets[row.key], Preferences.isOfficialFixedPoint(value) else { return nil }
            return row.item(carrying: value)
        }
        for row in rows where keys.contains(row.key) {
            let pair = PreferenceID(key: row.key, identifier: row.identifier)
            if let indexes = copies.removeValue(forKey: pair), let last = indexes.last {
                if row.updatedAt > Self.date(of: items[last]), let mine = uploadItem(row) {
                    for index in indexes { merge.file.items[index] = mine }
                    merge.uploads.append(pair)
                } else {
                    apply(items[last], pair, over: row)
                }
            } else if let mine = uploadItem(row), since.map({ row.updatedAt > 0 && row.updatedAt >= $0 })
                        ?? (row.updatedAt > 0 || row.key.hasPrefix(Preferences.peelPrefix)) {
                merge.file.items.append(mine)
                merge.uploads.append(pair)
            }
        }
        for (pair, indexes) in copies.sorted(by: { $0.value[0] < $1.value[0] }) {
            apply(items[indexes[indexes.count - 1]], pair, over: nil)
        }
        return merge
    }
}

extension Storage {
    /// Applies what a sync took from the file, each only where the stored
    /// row is still exactly the one it was merged against (or still none),
    /// so a change made here while the sync was out is never lost, whatever
    /// the clocks say; it goes up on the next sync. Returns how many values
    /// changed (a new date alone is not a change).
    func applyPreferences(_ changes: [PreferencesFile.Change]) throws -> Int {
        guard !changes.isEmpty else { return 0 }
        return try pool.write { db in
            var changed = 0
            for change in changes {
                let row = change.row
                let stored = try PreferenceRow.fetchOne(db, key: ["key": row.key, "identifier": row.identifier])
                guard stored == change.expected else { continue }
                try row.upsert(db)
                if stored?.value != row.value { changed += 1 }
            }
            return changed
        }
    }
}

extension PreferenceRow {
    /// The row as the file's item, or nil if the official apps would not
    /// write its value back unchanged.
    var item: [String: JSONValue]? {
        guard !isSecret, let value = JSONValue(text: value), Preferences.isOfficialFixedPoint(value) else { return nil }
        return item(carrying: value)
    }

    /// The row's key, identifier and date around `value`.
    func item(carrying value: JSONValue) -> [String: JSONValue] {
        [
            "key": .string(key), "identifier": .string(identifier),
            "date": .string(String(format: "%.0f", updatedAt)), "value": value,
        ]
    }
}
