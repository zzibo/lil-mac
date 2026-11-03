import Foundation
import LilMac

/// Lets the model remind the user. Action kind: the agent loop reports the call and the host delivers it,
/// so `call` never runs.
public struct NotifyTool: Tool {
    public struct Args: Codable, Sendable {
        public var text: String
        public var at: String?

        public init(text: String, at: String? = nil) {
            self.text = text
            self.at = at
        }
    }

    public let name = "notify"
    public let description = "Remind the user. Give the text and, to remind later, the time. Without a time it shows now."
    public let kind = ToolKind.action
    public let schema = JSONSchema.object(
        [
            "text": .string(description: "What the notification says."),
            "at": .string(description: "Local time to show it, ISO 8601, e.g. 2026-11-01T09:00:00."),
        ], required: ["text"])

    public init() {}

    public func call(_ args: Args) async throws -> String { "Shown to the user." }
}

/// "yyyy-MM-dd" then "T" or a space, "HH:mm", optional ":ss" and fraction, optional "Z" or offset
/// ("+08", "+0800", "+08:00"). Without an offset the time is read in `zone`. Anything else is nil.
func parseTime(_ text: String, in zone: TimeZone) -> Date? {
    // ASCII digits only: `\d` also matches other scripts' digits, which `Int` can't parse.
    let pattern = /([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(\.[0-9]+)?)?(Z|[+-][0-9]{2}(?::?[0-9]{2})?)?/
    guard let m = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern) else { return nil }
    var zone = zone
    if let offset = m.8 {
        let digits = offset.dropFirst().filter(\.isNumber)
        let seconds = (Int(digits.prefix(2)) ?? 0) * 3600 + (Int(digits.dropFirst(2)) ?? 0) * 60
        guard let parsed = TimeZone(secondsFromGMT: offset.first == "-" ? -seconds : offset == "Z" ? 0 : seconds)
        else { return nil }
        zone = parsed
    }
    guard let year = Int(m.1), let month = Int(m.2), let day = Int(m.3), let hour = Int(m.4), let minute = Int(m.5)
    else { return nil }
    let second = m.6.flatMap { Int($0) } ?? 0
    guard hour < 24, minute < 60, second < 60 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    guard let date = calendar.date(from: parts) else { return nil }
    let back = calendar.dateComponents([.year, .month, .day], from: date)  // rejects 2026-11-31 and month 13
    guard (back.year, back.month, back.day) == (year, month, day) else { return nil }
    return date.addingTimeInterval(m.7.flatMap { Double($0) } ?? 0)
}
