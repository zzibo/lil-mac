import Foundation
import LilMac
import SQLite3

public struct Job: Codable, Sendable, Identifiable {
    public var id: String
    public var schedule: Schedule
    public var prompt: String
    public var toolset: String
    /// Runs this long before `nextRun`; the result is delivered at `nextRun`.
    public var lead: TimeInterval
    public var nextRun: Date
    public var timeout: TimeInterval
    /// Step budget: the run's cost cap.
    public var budget: Int
    /// A saved chat to resume instead of starting from `prompt`.
    public var messages: [Message]?

    public init(
        id: String, schedule: Schedule, prompt: String, toolset: String, lead: TimeInterval = 0, nextRun: Date,
        timeout: TimeInterval = 60, budget: Int = 6, messages: [Message]? = nil
    ) {
        self.id = id
        self.schedule = schedule
        self.prompt = prompt
        self.toolset = toolset
        self.lead = lead
        self.nextRun = nextRun
        self.timeout = timeout
        self.budget = budget
        self.messages = messages
    }
}

struct JobStoreError: Error { var message: String; var code: Int32 = 0 }

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

/// Jobs in SQLite (WAL). May share a file with `SessionLog`: both set a busy timeout.
public actor JobStore {
    nonisolated(unsafe) private let db: OpaquePointer  // deinit needs it; FULLMUTEX makes the handle thread-safe

    public init(path: URL) throws {
        db = try Self.open(path, schema: [
            "CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, json TEXT NOT NULL, next_run REAL NOT NULL, lead REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS job_runs(job_id TEXT NOT NULL, started REAL NOT NULL, status TEXT NOT NULL)",
        ])
    }

    /// Opens `path` (WAL, busy timeout) and creates `schema`. Shared by every store that may live in the same file.
    static func open(_ path: URL, schema: [String]) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw JobStoreError(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
        // Switching to WAL ignores the busy timeout when another connection opens the same new file, so retry.
        let giveUp = Date().addingTimeInterval(5)
        while true {
            do {
                try run(handle, "PRAGMA journal_mode=WAL")
                for sql in schema { try run(handle, sql) }
                return handle
            } catch let error as JobStoreError where Date() < giveUp && (error.code == SQLITE_BUSY || error.code == SQLITE_LOCKED) {
                usleep(20_000)
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }
    }

    deinit { sqlite3_close(db) }

    public func add(_ job: Job) throws { try write(job, "INSERT") }

    /// Adds the job, or replaces the one with the same id, in one statement.
    public func upsert(_ job: Job) throws { try write(job, "INSERT OR REPLACE") }

    private func write(_ job: Job, _ verb: String) throws {
        let json = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        try Self.run(
            db, "\(verb) INTO jobs(id, json, next_run, lead) VALUES(?, ?, ?, ?)",
            [.text(job.id), .text(json), .real(job.nextRun.timeIntervalSince1970), .real(job.lead)])
    }

    public func list() throws -> [Job] { try select("SELECT json, next_run FROM jobs ORDER BY next_run, id") }

    public func delete(_ id: String) throws { try Self.run(db, "DELETE FROM jobs WHERE id = ?", [.text(id)]) }

    /// Claims every job with `nextRun - lead <= now` in one transaction and advances its `nextRun` before
    /// any run starts, so a kill or a second tick cannot run the same slot twice. Missed slots collapse into one.
    /// A one-shot job parks at `.distantFuture`; the caller deletes it after the run or restores it with `reschedule`.
    public func claimDue(now: Date, timeZone: TimeZone = .current) throws -> [(job: Job, slot: Date)] {
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            let due = try select(
                "SELECT json, next_run FROM jobs WHERE next_run - lead <= ? ORDER BY next_run, id",
                [.real(now.timeIntervalSince1970)])
            for job in due {
                // Step from the slot (a lead puts `now` before it; a repeated DST hour must not fire the same
                // wall-clock time twice), then collapse missed slots into this one run.
                // `every` counts from when it ran, so a late run doesn't fire again moments later.
                var from = job.nextRun
                if case .every = job.schedule { from = max(now, job.nextRun) }
                var next = job.schedule.next(after: from, in: timeZone)
                if let n = next, n <= now { next = job.schedule.next(after: now, in: timeZone) }
                let nextRun = next ?? .distantFuture
                try Self.run(
                    db, "UPDATE jobs SET next_run = ? WHERE id = ?", [.real(nextRun.timeIntervalSince1970), .text(job.id)])
            }
            try Self.run(db, "COMMIT")
            return due.map { ($0, $0.nextRun) }
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    public func reschedule(_ id: String, to date: Date) throws {
        try Self.run(db, "UPDATE jobs SET next_run = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(id)])
    }

    /// `status`: "done", "cutoff", "failed" or "timeout".
    public func recordRun(_ id: String, started: Date, status: String) throws {
        try Self.run(
            db, "INSERT INTO job_runs(job_id, started, status) VALUES(?, ?, ?)",
            [.text(id), .real(started.timeIntervalSince1970), .text(status)])
    }

    /// Statuses of a job's runs, oldest first.
    public func runs(_ id: String) throws -> [String] {
        var statuses: [String] = []
        try Self.run(db, "SELECT status FROM job_runs WHERE job_id = ? ORDER BY rowid", [.text(id)]) { stmt in
            statuses.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return statuses
    }

    private func select(_ sql: String, _ binds: [Bind] = []) throws -> [Job] {
        var jobs: [Job] = []
        try Self.run(db, sql, binds) { stmt in
            var job = try JSONDecoder().decode(Job.self, from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8))
            job.nextRun = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))  // the column is the live value
            jobs.append(job)
        }
        return jobs
    }

    enum Bind { case text(String), real(Double) }

    /// Prepared statement with bound parameters; calls `row` for each result row.
    static func run(
        _ db: OpaquePointer, _ sql: String, _ binds: [Bind] = [], row: (OpaquePointer) throws -> Void = { _ in }
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw JobStoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            switch bind {
            case .text(let s): sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient)
            case .real(let d): sqlite3_bind_double(stmt, Int32(i + 1), d)
            }
        }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: try row(stmt)
            case SQLITE_DONE: return
            default: throw JobStoreError(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db) & 0xFF)
            }
        }
    }
}
