import EventKit
import Foundation

/// A cheap, model-free reading of the world. The heartbeat wakes the model only when a reading changes.
public protocol Sensor: Sendable {
    var name: String { get }
    func read() async -> String?
}

/// The next timed calendar event that starts within `within`. Never asks for access:
/// without full calendar access the reading is nil.
public struct EventSoon: Sensor {
    public let name = "calendar"
    private let within: TimeInterval
    // EKEventStore isn't Sendable; this sensor only reads from it, which EventKit allows from any thread.
    private nonisolated(unsafe) let store: EKEventStore

    public init(within: TimeInterval = 6 * 3600, store: EKEventStore = .init()) {
        self.within = within
        self.store = store
    }

    public func read() async -> String? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now + within, calendars: nil))
        let next =
            events.filter { !$0.isAllDay && $0.startDate >= now }.min { $0.startDate < $1.startDate }
        return next.map { Self.reading(title: $0.title ?? "", start: $0.startDate) }
    }

    static func reading(title: String, start: Date, in zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(title) · \(formatter.string(from: start))"
    }
}

/// "<label>: <N> days" ("1 day") since a date. Whole days, so the reading changes at most once a day.
public struct TimeSince: Sensor {
    private let label: String
    private let date: @Sendable () async -> Date?

    public var name: String { label }

    public init(label: String, date: @escaping @Sendable () async -> Date?) {
        self.label = label
        self.date = date
    }

    public func read() async -> String? {
        guard let date = await date() else { return nil }
        let days = max(0, Int(Date().timeIntervalSince(date) / 86400))
        return "\(label): \(days) day\(days == 1 ? "" : "s")"
    }
}
