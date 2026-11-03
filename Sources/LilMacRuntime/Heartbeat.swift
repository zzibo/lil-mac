import Foundation
import LilMac
import SQLite3

/// Reads cheap sensors and wakes the model only when a reading changed and the gates allow it.
/// Shares its SQLite file with the job store. HOLD is the default answer.
public actor Heartbeat {
    nonisolated(unsafe) private let db: OpaquePointer  // deinit needs it; FULLMUTEX makes the handle thread-safe
    private let sensors: [any Sensor]
    private let notifier: any Notifier
    private let calendar: Calendar
    private let quietHours: (start: Int, end: Int)?
    private let cooldown: TimeInterval
    private let dailyCap: Int
    private let makeAgent: @Sendable () -> Agent
    private var running = false

    /// `quietHours` are minutes after local midnight and may cross it. Hosts put `NotifyTool` in the agent's toolset.
    public init(
        path: URL, sensors: [any Sensor], notifier: any Notifier, timeZone: TimeZone = .current,
        quietHours: (start: Int, end: Int)? = (22 * 60, 8 * 60), cooldown: TimeInterval = 1800, dailyCap: Int = 12,
        makeAgent: @escaping @Sendable () -> Agent
    ) throws {
        self.sensors = sensors
        self.notifier = notifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.quietHours = quietHours
        self.cooldown = cooldown
        self.dailyCap = dailyCap
        self.makeAgent = makeAgent
        db = try JobStore.open(path, schema: [
            "CREATE TABLE IF NOT EXISTS readings(sensor TEXT PRIMARY KEY, value TEXT)",
            "CREATE TABLE IF NOT EXISTS wakes(at REAL)",
        ])
    }

    deinit { sqlite3_close(db) }

    /// A tick while another is running returns at once: the gates read the wake log, which a running tick has not written yet.
    public func tick(now: Date) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let current = await readAll()
        guard let stored = try? storedReadings(), let gated = try? isGated(now) else { return }
        let changed = current.filter { $0.value != stored[$0.name] }
        // A gated change is not saved, so it fires on a later tick.
        guard !changed.isEmpty, !gated else { return }

        let lines = changed.map { "- \($0.name): \($0.value ?? "none")" }.joined(separator: "\n")
        let prompt =
            "Heartbeat check. Changed since the last check:\n\(lines)\nIf nothing needs the user, reply HOLD. To remind the user later, call notify with the text and the time."
        var text = "", finished = false
        var reminders: [NotifyTool.Args] = []
        do {
            for try await event in makeAgent().run([.user(prompt)]) {
                switch event {
                case .text(let t): text = t
                case .checkpoint: text = ""  // a step that called tools was not the answer
                case .action(let call) where call.name == "notify":
                    if let args = try? JSONDecoder().decode(NotifyTool.Args.self, from: Data(call.argumentsJSON.utf8)),
                        !args.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        reminders.append(args)
                    }
                case .done, .budgetExhausted: finished = true
                default: break
                }
            }
        } catch {
            // A failing provider backs off by the cooldown; a cancelled run (iOS cut-off) retries on the next tick.
            if !Task.isCancelled, !(error is CancellationError) {
                try? JobStore.run(db, "INSERT INTO wakes(at) VALUES(?)", [.real(now.timeIntervalSince1970)])
            }
        }
        // Cancelled or failed: deliver nothing and keep the readings, so the change is retried.
        guard finished else { return }
        try? JobStore.run(db, "INSERT INTO wakes(at) VALUES(?)", [.real(now.timeIntervalSince1970)])

        for reminder in reminders {
            let at = reminder.at.flatMap { parseTime($0, in: calendar.timeZone) }
            await notifier.deliver(reminder.text, at: at.flatMap { $0 > now ? $0 : nil })
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reminders.isEmpty, !isHold(answer) { await notifier.deliver(answer, at: nil) }
        save(current)
    }

    private func readAll() async -> [(name: String, value: String?)] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, sensor) in sensors.enumerated() { group.addTask { (i, await sensor.read()) } }
            var values = [String?](repeating: nil, count: sensors.count)
            for await (i, value) in group { values[i] = value }
            return zip(sensors, values).map { ($0.name, $1) }
        }
    }

    private func storedReadings() throws -> [String: String] {
        var stored: [String: String] = [:]
        try JobStore.run(db, "SELECT sensor, value FROM readings") { stmt in
            guard let sensor = sqlite3_column_text(stmt, 0), let value = sqlite3_column_text(stmt, 1) else { return }
            stored[String(cString: sensor)] = String(cString: value)
        }
        return stored
    }

    private func save(_ readings: [(name: String, value: String?)]) {
        for (name, value) in readings {
            if let value {
                try? JobStore.run(db, "INSERT OR REPLACE INTO readings(sensor, value) VALUES(?, ?)", [.text(name), .text(value)])
            } else {
                try? JobStore.run(db, "DELETE FROM readings WHERE sensor = ?", [.text(name)])
            }
        }
    }

    private func isGated(_ now: Date) throws -> Bool {
        if let (start, end) = quietHours {
            let time = calendar.dateComponents([.hour, .minute], from: now)
            let minute = (time.hour ?? 0) * 60 + (time.minute ?? 0)
            if start <= end ? (start..<end).contains(minute) : (minute >= start || minute < end) { return true }
        }
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        var last = 0.0, today = 0
        try JobStore.run(
            db, "SELECT MAX(at), COUNT(CASE WHEN at >= ? AND at < ? THEN 1 END) FROM wakes",
            [.real(dayStart.timeIntervalSince1970), .real(dayEnd.timeIntervalSince1970)]
        ) { stmt in
            last = sqlite3_column_double(stmt, 0)  // NULL reads as 0: no wake yet
            today = Int(sqlite3_column_int(stmt, 1))
        }
        return now.timeIntervalSince1970 - last < cooldown || today >= dailyCap
    }
}
