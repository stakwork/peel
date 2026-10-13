import GRDB

extension SQLiteAgentStore {
    /// Rows a read may return: complete (their add or link has arrived) and,
    /// unless asked, not deleted.
    private static func visible(_ table: String, includeDeleted: Bool) -> String {
        let complete = table == "record"
            ? "\(table).type IS NOT NULL AND \(table).name IS NOT NULL AND \(table).created_ms IS NOT NULL"
            : "\(table).type IS NOT NULL AND \(table).from_ref IS NOT NULL AND \(table).to_ref IS NOT NULL AND \(table).created_ms IS NOT NULL"
        return includeDeleted ? complete : complete + " AND \(table).deleted_ms IS NULL"
    }

    public func read(_ refId: String, includeDeleted: Bool) throws -> Record? {
        try db.read { db in try Self.record(refId, includeDeleted: includeDeleted, db) }
    }

    public func search(_ query: String, type: String?, limit: Int, includeDeleted: Bool) throws -> [SearchHit] {
        guard let match = Self.ftsMatch(query), limit > 0 else { return [] }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT record.ref_id, record.type, record.name,
                       snippet(record_text, 1, '', '', '…', 12) AS snippet
                FROM record_text JOIN record ON record.id = record_text.rowid
                WHERE record_text MATCH ? AND \(Self.visible("record", includeDeleted: includeDeleted))
                  AND (? IS NULL OR record.type = ?)
                ORDER BY bm25(record_text), record.ref_id
                LIMIT ?
                """, arguments: [match, type, type, limit]).map { row in
                let snippet: String? = row["snippet"]
                return SearchHit(refId: row["ref_id"], type: row["type"], name: row["name"],
                                 snippet: snippet?.isEmpty == false ? snippet : nil)
            }
        }
    }

    /// Each word of `query` as a quoted prefix (a quote inside doubled, so
    /// nothing typed is FTS5 syntax), all of them required.
    static func ftsMatch(_ query: String) -> String? {
        let terms = query.split(whereSeparator: { $0.isWhitespace || $0 == "\0" })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    public func walk(
        _ refId: String, edgeTypes: Set<String>?, direction: WalkDirection, depth: Int, limit: Int,
        includeDeleted: Bool
    ) throws -> [WalkStep] {
        guard limit > 0 else { return [] }
        let linkWhere = switch direction {
        case .outgoing: "link.from_ref = :id"
        case .incoming: "link.to_ref = :id"
        case .both: "(link.from_ref = :id OR link.to_ref = :id)"
        }
        let types = edgeTypes.map { Array($0) }
        let typeWhere = types.map { " AND link.type IN (" + $0.indices.map { ":t\($0)" }.joined(separator: ", ") + ")" }
        let sql = "SELECT * FROM link WHERE \(linkWhere) AND \(Self.visible("link", includeDeleted: includeDeleted))"
            + (typeWhere ?? "") + " ORDER BY created_ms, ref_id"
        var typeArguments: [String: String] = [:]
        for (index, type) in (types ?? []).enumerated() { typeArguments["t\(index)"] = type }
        return try db.read { db in
            var steps: [WalkStep] = []
            var seen: Set<String> = [refId]
            var frontier = [refId]
            for level in 1...max(1, min(depth, maxWalkDepth)) {
                var next: [String] = []
                for id in frontier {
                    var arguments = typeArguments
                    arguments["id"] = id
                    for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)) {
                        let link = Self.link(row)
                        let other = link.from == id ? link.to : link.from
                        guard !seen.contains(other),
                              let record = try Self.record(other, includeDeleted: includeDeleted, db) else { continue }
                        seen.insert(other)
                        steps.append(WalkStep(record: record, link: link, depth: level))
                        if steps.count >= limit { return steps }
                        next.append(other)
                    }
                }
                frontier = next
            }
            return steps
        }
    }

    public func ontology() throws -> [TypeCount] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT 'record' AS kind, type, COUNT(*) AS count FROM record
                    WHERE \(Self.visible("record", includeDeleted: false)) GROUP BY type
                UNION ALL
                SELECT 'link', type, COUNT(*) FROM link
                    WHERE \(Self.visible("link", includeDeleted: false)) GROUP BY type
                ORDER BY kind DESC, count DESC, type
                """).map { row in
                TypeCount(kind: TypeCount.Kind(rawValue: row["kind"]) ?? .record, type: row["type"], count: row["count"])
            }
        }
    }

    public func records(type: String, limit: Int, includeDeleted: Bool) throws -> [Record] {
        guard limit > 0 else { return [] }
        return try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT ref_id FROM record WHERE type = ? AND \(Self.visible("record", includeDeleted: includeDeleted))
                ORDER BY created_ms, id LIMIT ?
                """, arguments: [type, limit]).compactMap { try Self.record($0, includeDeleted: includeDeleted, db) }
        }
    }

    private static func record(_ refId: String, includeDeleted: Bool, _ db: Database) throws -> Record? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM record WHERE ref_id = ? AND \(visible("record", includeDeleted: includeDeleted))",
            arguments: [refId]
        ) else { return nil }
        let createdMs: Int64 = row["created_ms"]
        return Record(refId: row["ref_id"], type: row["type"], name: row["name"], body: row["body"],
                      props: Self.props(row["props"]), createdBy: row["created_by"] ?? "", source: row["source"],
                      createdMs: createdMs, updatedMs: row["updated_ms"] ?? createdMs, deletedMs: row["deleted_ms"])
    }

    private static func link(_ row: Row) -> Link {
        Link(refId: row["ref_id"], type: row["type"], from: row["from_ref"], to: row["to_ref"],
             props: Self.props(row["props"]), createdBy: row["created_by"] ?? "", createdMs: row["created_ms"],
             deletedMs: row["deleted_ms"])
    }
}
