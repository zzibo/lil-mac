import Foundation
import LilMac

/// Lets the model create a job. Approval kind: the user confirms every schedule.
public struct ScheduleTool: Tool {
    public struct Args: Codable, Sendable {
        public var prompt: String
        public var cron: String?
        public var everyMinutes: Int?
        public var at: String?
        public var leadMinutes: Int?
        public var toolset: String?

        public init(
            prompt: String, cron: String? = nil, everyMinutes: Int? = nil, at: String? = nil,
            leadMinutes: Int? = nil, toolset: String? = nil
        ) {
            self.prompt = prompt
            self.cron = cron
            self.everyMinutes = everyMinutes
            self.at = at
            self.leadMinutes = leadMinutes
            self.toolset = toolset
        }
    }

    public let name = "schedule"
    public let description = "Schedule a prompt to run later. Give exactly one of cron, everyMinutes or at."
    public let kind = ToolKind.approval
    public let schema = JSONSchema.object(
        [
            "prompt": .string(description: "What to do when the job runs."),
            "cron": .string(description: "Five fields: minute hour day-of-month month day-of-week, e.g. 0 8 * * 1-5."),
            "everyMinutes": .integer,
            "at": .string(description: "One run at this ISO 8601 time, e.g. 2026-11-01T09:00:00+08:00."),
            "leadMinutes": .integer,
            "toolset": .string(description: "Toolset the run uses."),
        ], required: ["prompt"])

    let store: JobStore
    let defaultToolset: String
    let timeZone: TimeZone
    let now: @Sendable () -> Date

    public init(
        store: JobStore, defaultToolset: String = "default", timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.defaultToolset = defaultToolset
        self.timeZone = timeZone
        self.now = now
    }

    public func call(_ args: Args) async throws -> String {
        let schedule: Schedule
        switch (args.cron, args.everyMinutes, args.at) {
        case (let cron?, nil, nil):
            guard (try? Cron(cron)) != nil else { return "Error: invalid cron expression." }
            schedule = .cron(cron)
        case (nil, let minutes?, nil):
            guard minutes > 0 else { return "Error: everyMinutes must be positive." }
            schedule = .every(Double(minutes) * 60)
        case (nil, nil, let at?):
            guard let date = ISO8601DateFormatter().date(from: at) else { return "Error: at must be an ISO 8601 time." }
            schedule = .once(date)
        default:
            return "Error: give exactly one of cron, everyMinutes or at."
        }
        guard (args.leadMinutes ?? 0) >= 0 else { return "Error: leadMinutes cannot be negative." }
        guard let next = schedule.next(after: now(), in: timeZone) else { return "Error: no future run time." }
        let id = String(UUID().uuidString.prefix(8))
        try await store.add(Job(
            id: id, schedule: schedule, prompt: args.prompt, toolset: args.toolset ?? defaultToolset,
            lead: Double(args.leadMinutes ?? 0) * 60, nextRun: next))
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        return "Scheduled \(id), next run \(iso.string(from: next))."
    }
}
