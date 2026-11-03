import Foundation
import SQLite3

struct SQLiteError: Error { var message: String; var code: Int32 = 0 }

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

/// Past runs in SQLite (WAL) with FTS5 search over message text.
public actor SessionLog {
    nonisolated(unsafe) private let db: OpaquePointer  // deinit needs it; FULLMUTEX makes the handle thread-safe

    public init(path: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)  // a second connection (jobs) may hold the write lock
        // Switching to WAL ignores the busy timeout when another connection opens the same new file, so retry.
        let giveUp = Date().addingTimeInterval(5)
        while true {
            do {
                try Self.run(handle, "PRAGMA journal_mode=WAL")
                try Self.run(handle, "CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, date REAL, usage TEXT)")
                try Self.run(handle, "CREATE VIRTUAL TABLE IF NOT EXISTS run_text USING fts5(run_id UNINDEXED, date UNINDEXED, text)")
                break
            } catch let error as SQLiteError where Date() < giveUp && (error.code == SQLITE_BUSY || error.code == SQLITE_LOCKED) {
                usleep(20_000)
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }
        db = handle  // assigned last: deinit only ever closes a fully set-up handle
    }

    deinit { sqlite3_close(db) }

    public func log(_ run: RunRecord) throws {
        let usage = String(decoding: try JSONEncoder().encode(run.usage), as: UTF8.self)
        let date = run.date.timeIntervalSince1970
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            try Self.run(db, "INSERT OR REPLACE INTO runs(id, date, usage) VALUES(?, ?, ?)", [.text(run.id), .real(date), .text(usage)])
            // ponytail: run_id is UNINDEXED so this scans run_text; fine at phone scale.
            try Self.run(db, "DELETE FROM run_text WHERE run_id = ?", [.text(run.id)])
            for text in run.messages.map(\.text.withoutNUL) where !text.isEmpty {
                try Self.run(db, "INSERT INTO run_text(run_id, date, text) VALUES(?, ?, ?)", [.text(run.id), .real(date), .text(text)])
            }
            try Self.run(db, "COMMIT")
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    public func search(_ query: String, limit: Int) throws -> [SessionHit] {
        // Quote every term so user input can never be FTS5 syntax.
        let match = query.withoutNUL.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
        guard !match.isEmpty, limit > 0 else { return [] }
        var hits: [SessionHit] = []
        try Self.run(
            db,
            "SELECT run_id, date, text FROM run_text WHERE run_text MATCH ? ORDER BY date DESC LIMIT ?",
            [.text(match), .int(limit)]
        ) { stmt in
            hits.append(SessionHit(
                runId: String(cString: sqlite3_column_text(stmt, 0)),
                text: String(String(cString: sqlite3_column_text(stmt, 2)).prefix(300)),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            ))
        }
        return hits
    }

    private enum Bind { case text(String), real(Double), int(Int) }

    /// Prepared statement with bound parameters; calls `row` for each result row.
    private static func run(
        _ db: OpaquePointer, _ sql: String, _ binds: [Bind] = [], row: (OpaquePointer) -> Void = { _ in }
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            let index = Int32(i + 1)
            switch bind {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .int(let n): sqlite3_bind_int64(stmt, index, Int64(n))
            }
        }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(stmt)
            case SQLITE_DONE: return
            default: throw SQLiteError(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db) & 0xFF)
            }
        }
    }
}
