import Foundation

public struct CronError: Error, Equatable { public var message: String }

/// Five-field cron: minute hour day-of-month month day-of-week (0 or 7 = Sunday).
public struct Cron: Sendable {
    private let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    private let anyDay: Bool, anyWeekday: Bool

    public init(_ expression: String) throws {
        let f = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count == 5 else { throw CronError(message: "expected 5 fields, got \(f.count)") }
        minutes = try Self.parse(f[0], 0...59)
        hours = try Self.parse(f[1], 0...23)
        days = try Self.parse(f[2], 1...31)
        months = try Self.parse(f[3], 1...12)
        weekdays = Set(try Self.parse(f[4], 0...7).map { $0 % 7 })
        anyDay = f[2].hasPrefix("*")
        anyWeekday = f[4].hasPrefix("*")
    }

    /// Digits only: `Int("+5")` would parse.
    private static func number(_ text: Substring) -> Int? {
        text.allSatisfy { $0 >= "0" && $0 <= "9" } ? Int(text) : nil
    }

    /// `*`, lists, ranges and steps: `*/15`, `1-5`, `1,3`, `10-20/2`.
    private static func parse(_ field: String, _ bounds: ClosedRange<Int>) throws -> Set<Int> {
        var out = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let stepped = part.split(separator: "/", omittingEmptySubsequences: false)
            let range = stepped[0].split(separator: "-", omittingEmptySubsequences: false)
            var step = 1
            if stepped.count == 2 { step = number(stepped[1]) ?? 0 }
            let lo: Int?, hi: Int?
            if stepped[0] == "*" { (lo, hi) = (bounds.lowerBound, bounds.upperBound) }
            else if range.count == 1 { (lo, hi) = (number(range[0]), stepped.count == 2 ? bounds.upperBound : number(range[0])) }
            else if range.count == 2 { (lo, hi) = (number(range[0]), number(range[1])) }
            else { (lo, hi) = (nil, nil) }
            guard stepped.count <= 2, step > 0, let lo, let hi, lo <= hi, bounds.contains(lo), bounds.contains(hi) else {
                throw CronError(message: "bad field '\(field)'")
            }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out
    }

    /// The first matching minute strictly after `after`, or nil within five years.
    /// Skips whole months, days and hours that cannot match instead of scanning minutes.
    public func next(after: Date, in zone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let from = cal.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        guard var t = cal.dateInterval(of: .minute, for: after)?.end,
              let limit = cal.date(byAdding: .year, value: 5, to: after) else { return nil }
        func skip(_ unit: Calendar.Component) -> Bool {
            guard let end = cal.dateInterval(of: unit, for: t)?.end else { return false }
            t = end
            return true
        }
        while t < limit {
            let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: t)
            let dayMatch = days.contains(c.day!), weekdayMatch = weekdays.contains(c.weekday! - 1)
            let dayOK = anyDay || anyWeekday ? dayMatch && weekdayMatch : dayMatch || weekdayMatch
            let advanced =
                !months.contains(c.month!) ? skip(.month)
                : !dayOK ? skip(.day)
                : !hours.contains(c.hour!) ? skip(.hour)
                : !minutes.contains(c.minute!) ? skip(.minute)
                : nil
            guard let advanced else {
                // The repeated hour on a fall-back day: never fire twice in the same local minute.
                if (c.year, c.month, c.day, c.hour, c.minute) == (from.year, from.month, from.day, from.hour, from.minute),
                   skip(.minute) { continue }
                return t
            }
            if !advanced { return nil }
        }
        return nil
    }
}

public enum Schedule: Codable, Sendable, Equatable {
    case cron(String)
    case every(TimeInterval)
    case once(Date)

    /// `.once` returns nil once its date has passed.
    public func next(after: Date, in zone: TimeZone) -> Date? {
        switch self {
        case .cron(let expression): try? Cron(expression).next(after: after, in: zone)
        case .every(let seconds): after.addingTimeInterval(seconds)
        case .once(let date): date > after ? date : nil
        }
    }
}
