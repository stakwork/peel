import Foundation
import GRDB

/// One request an agent asked this device (`deviceRequest`, v25), as
/// `Engine+DeviceRequests` keeps it: received (stored, acked), running,
/// then done with its answer, which a new copy of the request is sent again.
struct DeviceRequestRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "deviceRequest"

    enum State: String, Codable {
        case received, running, done
    }

    /// The agent contact that asked it: a request is its id within its agent.
    var agent: String
    var id: String
    var kind: String
    /// The request's `args`, as JSON.
    var args: String
    /// Seconds since 1970 after which it is never done.
    var notAfter: Int64
    var state: State
    var status: ControlEnvelope.Status?
    /// The answer's text (`DeviceAnswer.text`), sent as `result.text`.
    var result: String?
    var error: String?
    /// The uuids of the messages that asked it: a copy seen before
    /// (history brings stored messages back) is not answered again.
    var messages: [String] = []
    /// Whether the answer went; one that did not goes once online.
    var sent = false
    /// Milliseconds since 1970.
    var receivedAt: Int64
}

extension Storage {
    /// Stores `row` unless its request is stored already, and notes that
    /// message `copy` asked it: the stored row, and whether `copy` is new
    /// to it. In one transaction, so of two copies only one is new.
    func admit(_ row: DeviceRequestRow, copy: String) throws -> (row: DeviceRequestRow, newCopy: Bool) {
        try pool.write { db in
            guard var stored = try DeviceRequestRow.fetchOne(db, key: ["agent": row.agent, "id": row.id]) else {
                var row = row
                row.messages = [copy]
                try row.insert(db)
                return (row, true)
            }
            guard !stored.messages.contains(copy) else { return (stored, false) }
            stored.messages.append(copy)
            try stored.update(db, columns: ["messages"])
            return (stored, true)
        }
    }

    /// Marks a request not done yet as running, and returns it; nil when it
    /// is done (or gone). The caller is the one doing it
    /// (`Engine.answeringRequests`), so a row found running was cut short.
    func claimDeviceRequest(_ id: String, of agent: String) throws -> DeviceRequestRow? {
        try pool.write { db in
            try DeviceRequestRow.fetchOne(db, sql: """
                UPDATE deviceRequest SET state = 'running' WHERE agent = ? AND id = ? AND state != 'done' RETURNING *
                """, arguments: [agent, id])
        }
    }

    /// Records a running request's answer, and returns it; nil when it is
    /// not running.
    func finishDeviceRequest(_ id: String, of agent: String, with answer: DeviceAnswer) throws -> DeviceRequestRow? {
        try pool.write { db in
            try DeviceRequestRow.fetchOne(db, sql: """
                UPDATE deviceRequest SET state = 'done', status = ?, result = ?, error = ?
                WHERE agent = ? AND id = ? AND state = 'running' RETURNING *
                """, arguments: [answer.status.rawValue, answer.text, answer.error, agent, id])
        }
    }

    func markDeviceRequestSent(_ id: String, of agent: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE deviceRequest SET sent = 1 WHERE agent = ? AND id = ?", arguments: [agent, id])
        }
    }

    /// `agent`'s requests not done, or done but not answered, oldest first:
    /// a stop or a lost connection cut them short.
    func owedDeviceRequests(of agent: String) throws -> [DeviceRequestRow] {
        try pool.read { db in
            try DeviceRequestRow.fetchAll(db, sql: """
                SELECT * FROM deviceRequest WHERE agent = ? AND (state != 'done' OR sent = 0) ORDER BY receivedAt
                """, arguments: [agent])
        }
    }

    /// Forgets the requests that expired before `seconds` (since 1970): the
    /// agent asks again only until a request expires, and a repeat after
    /// that is answered `expired`, as it would be anyway.
    func forgetDeviceRequests(expiredBefore seconds: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM deviceRequest WHERE notAfter < ?", arguments: [seconds])
        }
    }
}
