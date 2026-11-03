import Foundation
import LilMac
import Testing
import UserNotifications
@testable import LilMacRuntime

// MARK: doubles

actor Dial {
    var value: String?
    init(_ value: String?) { self.value = value }
    func set(_ value: String?) { self.value = value }
}

struct StubSensor: Sensor {
    let name: String
    let dial: Dial
    func read() async -> String? { await dial.value }
}

/// Replies in order; counts requests. `stall` makes the first request wait until cancelled.
actor Spy: Provider {
    private var replies: [ModelReply]
    private let stall: Bool
    private let delay: Duration?
    private(set) var calls = 0
    init(_ replies: [ModelReply], stall: Bool = false, delay: Duration? = nil) {
        self.replies = replies; self.stall = stall; self.delay = delay
    }
    func send(_ request: ModelRequest) async throws -> ModelReply {
        calls += 1
        if stall && calls == 1 { try await Task.sleep(for: .seconds(30)) }
        if let delay { try await Task.sleep(for: delay) }
        return replies.isEmpty ? reply("HOLD") : replies.removeFirst()
    }
}

func notifyCall(_ json: String) -> ModelReply {
    reply("", calls: [ToolCall(id: UUID().uuidString, name: "notify", argumentsJSON: json)])
}

let noon = date(2026, 10, 27, 12)

func makeHeartbeat(
    _ sensors: [any Sensor], _ notifier: Recorder, _ provider: any Provider, url: URL = tempURL(),
    timeZone: TimeZone = utc, quiet: (start: Int, end: Int)? = nil, cooldown: TimeInterval = 0, cap: Int = 100
) throws -> Heartbeat {
    try Heartbeat(
        path: url, sensors: sensors, notifier: notifier, timeZone: timeZone, quietHours: quiet, cooldown: cooldown,
        dailyCap: cap
    ) {
        Agent(provider: provider, system: "s", toolset: Toolset(name: "t", tools: [AnyTool(NotifyTool())]), budget: 4)
    }
}

// MARK: heartbeat

@Suite struct HeartbeatTests {
    @Test func firstReadingWakesTheModelOnceThenSameReadingsDoNot() async throws {
        let spy = Spy([])
        let hb = try makeHeartbeat([StubSensor(name: "calendar", dial: Dial("Standup"))], Recorder(), spy)
        await hb.tick(now: noon)
        #expect(await spy.calls == 1)
        await hb.tick(now: noon.addingTimeInterval(3600))
        #expect(await spy.calls == 1)
    }

    @Test func readingsPersistAcrossReopen() async throws {
        let url = tempURL(), dial = Dial("a"), spy = Spy([])
        try await makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), spy, url: url).tick(now: noon)
        try await makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), spy, url: url).tick(now: noon.addingTimeInterval(60))
        #expect(await spy.calls == 1)
    }

    @Test func aSensorThatReadsNilWithNothingStoredIsNotAChange() async throws {
        let spy = Spy([])
        let hb = try makeHeartbeat([StubSensor(name: "calendar", dial: Dial(nil))], Recorder(), spy)
        await hb.tick(now: noon)
        #expect(await spy.calls == 0)
    }

    @Test func goingFromAReadingToNilIsAChangeAndThePromptNamesOnlyChangedSensors() async throws {
        let a = Dial("x"), b = Dial("y")
        let prompts = PromptLog()
        let hb = try Heartbeat(
            path: tempURL(), sensors: [StubSensor(name: "a", dial: a), StubSensor(name: "b", dial: b)],
            notifier: Recorder(), timeZone: utc, quietHours: nil, cooldown: 0, dailyCap: 100
        ) {
            Agent(provider: LoggingProvider(log: prompts), system: "s", toolset: Toolset(name: "t", tools: []))
        }
        await hb.tick(now: noon)
        await a.set(nil)
        await hb.tick(now: noon.addingTimeInterval(60))
        let all = await prompts.texts
        #expect(all[0] == "Heartbeat check. Changed since the last check:\n- a: x\n- b: y\nIf nothing needs the user, reply HOLD. To remind the user later, call notify with the text and the time.")
        #expect(all[1].contains("\n- a: none\n"))
        #expect(!all[1].contains("- b:"))
    }

    @Test(arguments: [
        (9 * 60, 17 * 60, date(2026, 10, 27, 12), date(2026, 10, 27, 18)),  // plain window
        (22 * 60, 8 * 60, date(2026, 10, 27, 23), date(2026, 10, 28, 9)),  // crosses midnight, before it
        (22 * 60, 8 * 60, date(2026, 10, 27, 3), date(2026, 10, 27, 9)),  // crosses midnight, after it
    ])
    func quietHoursHoldTheChangeUntilTheyEnd(start: Int, end: Int, quiet: Date, open: Date) async throws {
        let spy = Spy([])
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], Recorder(), spy, quiet: (start, end))
        await hb.tick(now: quiet)
        #expect(await spy.calls == 0)
        await hb.tick(now: open)
        #expect(await spy.calls == 1)
    }

    @Test func windowEdgesStartInclusiveEndExclusive() async throws {
        let spy = Spy([]), dial = Dial("a")
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), spy, quiet: (22 * 60, 8 * 60))
        await hb.tick(now: date(2026, 10, 27, 22, 0))
        #expect(await spy.calls == 0)
        await hb.tick(now: date(2026, 10, 28, 8, 0))
        #expect(await spy.calls == 1)
    }

    @Test func quietHoursUseTheConfiguredTimeZone() async throws {
        let singapore = TimeZone(identifier: "Asia/Singapore")!
        let spy = Spy([])
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], Recorder(), spy, timeZone: singapore, quiet: (22 * 60, 8 * 60))
        await hb.tick(now: date(2026, 10, 27, 15))  // 23:00 in Singapore
        #expect(await spy.calls == 0)
        await hb.tick(now: date(2026, 10, 27, 1))  // 09:00 in Singapore
        #expect(await spy.calls == 1)
    }

    @Test func cooldownHoldsTheChangeUntilItPasses() async throws {
        let spy = Spy([]), dial = Dial("a")
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), spy, cooldown: 1800)
        await hb.tick(now: noon)
        await dial.set("b")
        await hb.tick(now: noon.addingTimeInterval(600))
        #expect(await spy.calls == 1)
        await hb.tick(now: noon.addingTimeInterval(1801))
        #expect(await spy.calls == 2)
    }

    @Test func dailyCapHoldsTheChangeUntilTheNextLocalDay() async throws {
        let spy = Spy([]), dial = Dial("0")
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), spy, cap: 2)
        for i in 0..<3 {
            await dial.set("\(i)")
            await hb.tick(now: noon.addingTimeInterval(Double(i) * 60))
        }
        #expect(await spy.calls == 2)
        await hb.tick(now: date(2026, 10, 28, 0, 5))
        #expect(await spy.calls == 3)
    }

    @Test func holdDeliversNothing() async throws {
        let notifier = Recorder()
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], notifier, Spy([reply("HOLD")]))
        await hb.tick(now: noon)
        #expect(await notifier.delivered.isEmpty)
    }

    @Test func plainTextIsDeliveredNow() async throws {
        let notifier = Recorder()
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], notifier, Spy([reply("Leave now for the 3pm.")]))
        await hb.tick(now: noon)
        let delivered = await notifier.delivered
        #expect(delivered.map(\.text) == ["Leave now for the 3pm."])
        #expect(delivered[0].at == nil)
    }

    @Test func notifyDeliversAtTheGivenTimeAndReplacesTheFinalText() async throws {
        let notifier = Recorder()
        let spy = Spy([notifyCall(#"{"text":"Call mum","at":"2026-10-27T14:00:00Z"}"#), reply("Done, I set it.")])
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], notifier, spy)
        await hb.tick(now: noon)
        let delivered = await notifier.delivered
        #expect(delivered.map(\.text) == ["Call mum"])
        #expect(delivered[0].at == date(2026, 10, 27, 14))
    }

    @Test func notifyReadsATimeWithoutOffsetInTheHeartbeatTimeZone() async throws {
        let notifier = Recorder()
        let spy = Spy([notifyCall(#"{"text":"x","at":"2026-10-27T22:00:00"}"#)])
        let hb = try makeHeartbeat(
            [StubSensor(name: "s", dial: Dial("a"))], notifier, spy, timeZone: TimeZone(identifier: "Asia/Singapore")!)
        await hb.tick(now: noon)
        #expect(await notifier.delivered.first?.at == date(2026, 10, 27, 14))
    }

    @Test func notifyWithAPastOrMissingTimeDeliversNow() async throws {
        let notifier = Recorder()
        let spy = Spy([
            notifyCall(#"{"text":"late","at":"2026-10-27T09:00:00Z"}"#), notifyCall(#"{"text":"bare"}"#), reply("ok"),
        ])
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], notifier, spy)
        await hb.tick(now: noon)
        let delivered = await notifier.delivered
        #expect(delivered.map(\.text) == ["late", "bare"])
        #expect(delivered.allSatisfy { $0.at == nil })
    }

    @Test func badNotifyArgumentsAreIgnored() async throws {
        let notifier = Recorder()
        let spy = Spy([notifyCall("not json"), notifyCall(#"{"at":"2026-10-27T14:00:00Z"}"#), notifyCall(#"{"text":"  "}"#), reply("HOLD")])
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], notifier, spy)
        await hb.tick(now: noon)
        #expect(await notifier.delivered.isEmpty)
    }

    @Test func aCancelledRunKeepsTheChangePending() async throws {
        let spy = Spy([], stall: true)
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], Recorder(), spy, cooldown: 1800)
        let tick = Task { await hb.tick(now: noon) }
        while await spy.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        tick.cancel()
        await tick.value
        await hb.tick(now: noon.addingTimeInterval(60))
        #expect(await spy.calls == 2)
        await hb.tick(now: noon.addingTimeInterval(120))
        #expect(await spy.calls == 2)  // the second run finished, so the readings are saved
    }

    @Test func concurrentTicksRunTheModelOnce() async throws {
        let spy = Spy([], delay: .milliseconds(200))
        let hb = try makeHeartbeat([StubSensor(name: "s", dial: Dial("a"))], Recorder(), spy)  // cooldown 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { await hb.tick(now: noon) } }
        }
        #expect(await spy.calls == 1)
    }

    @Test func aFailedRunKeepsTheChangePendingAndBacksOff() async throws {
        struct Boom: Provider { func send(_ request: ModelRequest) async throws -> ModelReply { throw ProviderError.timeout } }
        let url = tempURL(), dial = Dial("a")
        try await makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), Boom(), url: url, cooldown: 1800).tick(now: noon)
        let spy = Spy([])
        let retry = try makeHeartbeat([StubSensor(name: "s", dial: dial)], Recorder(), spy, url: url, cooldown: 1800)
        await retry.tick(now: noon.addingTimeInterval(60))  // a failing provider isn't hammered every tick
        #expect(await spy.calls == 0)
        await retry.tick(now: noon.addingTimeInterval(1800))  // the change was kept, so it fires after the cooldown
        #expect(await spy.calls == 1)
    }
}

actor PromptLog {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}

struct LoggingProvider: Provider {
    let log: PromptLog
    func send(_ request: ModelRequest) async throws -> ModelReply {
        await log.add(request.messages.last?.text ?? "")
        return reply("HOLD")
    }
}

// MARK: time parsing

@Suite struct ParseTimeTests {
    let singapore = TimeZone(identifier: "Asia/Singapore")!

    @Test(arguments: [
        ("2026-11-01T09:00:00Z", date(2026, 11, 1, 9), 0.0),
        ("2026-11-01T09:00:00.5Z", date(2026, 11, 1, 9), 0.5),
        ("2026-11-01T09:00:00.5+08:00", date(2026, 11, 1, 1), 0.5),
        ("2026-11-01T09:00:00+08:00", date(2026, 11, 1, 1), 0),
        ("2026-11-01T09:00:00+0800", date(2026, 11, 1, 1), 0),
        ("2026-11-01T09:00:00+08", date(2026, 11, 1, 1), 0),
        ("2026-11-01T09:00:00-05:30", date(2026, 11, 1, 14, 30), 0),
        ("2026-11-01T09:00Z", date(2026, 11, 1, 9), 0),
        ("2026-11-01 09:00+08:00", date(2026, 11, 1, 1), 0),
        ("2026-11-01T09:00", date(2026, 11, 1, 1), 0),  // no offset: heartbeat zone (+08)
        ("2026-11-01T09:00:00", date(2026, 11, 1, 1), 0),
        ("2026-11-01T09:00:00.25", date(2026, 11, 1, 1), 0.25),
        ("2026-11-01 09:00:00", date(2026, 11, 1, 1), 0),
        (" 2026-11-01 09:00:00 ", date(2026, 11, 1, 1), 0),
    ])
    func accepts(text: String, expected: Date, fraction: Double) throws {
        let parsed = try #require(parseTime(text, in: singapore))
        #expect(abs(parsed.timeIntervalSince(expected) - fraction) < 0.001)
    }

    @Test(arguments: [
        "", "tomorrow", "2026-11-01", "2026-11-01T09", "2026-11-01T09:00:00 now", "2026-11-01T09:00:00Zjunk",
        "2026-11-01T09:00:00+08:00 extra", "2026-11-01T09:00:00.Z", "2026-13-01T09:00", "2026-11-31T09:00",
        "2026-11-01T25:00", "2026-11-01T09:60", "2026-11-01T09:00:60", "2026-11-01T09:00+99:00", "09:00",
        "٢٠٢٦-١١-٠١T٠٩:٠٠",  // non-ASCII digits: rejected, not a crash
    ])
    func rejects(text: String) {
        #expect(parseTime(text, in: singapore) == nil)
    }
}

// MARK: sensors

@Suite struct SensorTests {
    @Test func timeSinceCountsWholeDays() async throws {
        let now = Date()
        let cases: [(age: Double, days: Int)] = [(266_400, 3), (3 * 86400 + 72_000, 3), (3600, 0), (86_460, 1)]
        for (age, days) in cases {
            let reading = await TimeSince(label: "Last workout") { now.addingTimeInterval(-age) }.read()
            #expect(reading == "Last workout: \(days) day\(days == 1 ? "" : "s")")
        }
    }

    @Test func timeSinceIsNilWithoutADate() async {
        #expect(await TimeSince(label: "x") { nil }.read() == nil)
    }

    @Test func eventSoonReadsNilWhenCalendarAccessIsNotGranted() async {
        #expect(await EventSoon().read() == nil)
    }

    @Test func eventSoonFormatsTitleAndLocalStart() {
        let singapore = TimeZone(identifier: "Asia/Singapore")!
        #expect(EventSoon.reading(title: "Standup", start: date(2026, 10, 27, 1, 5), in: singapore) == "Standup · 2026-10-27 09:05")
    }
}

// MARK: notifier and tool

/// UNNotificationRequest is not Sendable, so keep what the tests check.
struct Captured: Sendable {
    var id: String, body: String, title: String
    var hasTrigger: Bool, repeats: Bool, interval: TimeInterval?
}

actor Requests {
    private(set) var all: [Captured] = []
    func add(_ r: Captured) { all.append(r) }
}

func capture(_ requests: Requests) -> LocalNotifier {
    LocalNotifier { request in
        let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
        let captured = Captured(
            id: request.identifier, body: request.content.body, title: request.content.title,
            hasTrigger: request.trigger != nil, repeats: trigger?.repeats ?? false, interval: trigger?.timeInterval)
        await requests.add(captured)
    }
}

@Suite struct LocalNotifierTests {
    @Test func futureTimeBecomesATimeIntervalTrigger() async throws {
        let requests = Requests()
        let at = Date(timeIntervalSinceNow: 7200)
        await capture(requests).deliver("Call mum", at: at)
        let request = try #require(await requests.all.first)
        #expect(request.body == "Call mum")
        #expect(request.title.isEmpty)
        #expect(request.hasTrigger && !request.repeats)
        #expect(abs(try #require(request.interval) - 7200) < 5)
        #expect(UUID(uuidString: request.id) != nil)
    }

    @Test(arguments: [nil, Date(timeIntervalSinceNow: -3600)])
    func nilOrPastTimeHasNoTrigger(at: Date?) async throws {
        let requests = Requests()
        await capture(requests).deliver("now", at: at)
        let request = try #require(await requests.all.first)
        #expect(!request.hasTrigger)
        #expect(request.body == "now")
    }

    @Test func notifyToolIsAnActionTool() {
        let tool = NotifyTool()
        #expect(tool.name == "notify")
        #expect(tool.kind == .action)
    }
}
