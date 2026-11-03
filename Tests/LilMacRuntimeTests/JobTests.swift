import Foundation
import LilMac
import Testing
@testable import LilMacRuntime

// MARK: doubles

actor Script: Provider {
    private var replies: [ModelReply]
    private let delay: Duration?
    init(_ replies: [ModelReply], delay: Duration? = nil) { self.replies = replies; self.delay = delay }
    func send(_ request: ModelRequest) async throws -> ModelReply {
        if let delay { try await Task.sleep(for: delay) }
        guard !replies.isEmpty else { throw ProviderError.timeout }
        return replies.removeFirst()
    }
}

func reply(_ text: String, calls: [ToolCall] = []) -> ModelReply {
    ModelReply(message: .assistant(text), toolCalls: calls, usage: .zero)
}

actor Recorder: Notifier {
    private(set) var delivered: [(text: String, at: Date?)] = []
    func deliver(_ text: String, at: Date?) async { delivered.append((text, at)) }
}

actor Counter {
    private(set) var n = 0
    func bump() { n += 1 }
}

func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).sqlite")
}

func job(_ schedule: Schedule = .cron("0 * * * *"), id: String = "j", next: Date, lead: TimeInterval = 0,
         timeout: TimeInterval = 60) -> Job {
    Job(id: id, schedule: schedule, prompt: "go", toolset: "t", lead: lead, nextRun: next, timeout: timeout)
}

func scheduler(_ store: JobStore, _ notifier: Recorder, _ provider: any Provider,
               tools: [AnyTool] = []) -> Scheduler {
    Scheduler(store: store, notifier: notifier, timeZone: utc) { job in
        Agent(provider: provider, system: "s", toolset: Toolset(name: job.toolset, tools: tools), budget: job.budget)
    }
}

// MARK: store

@Suite struct JobStoreTests {
    @Test func claimDueTwiceAtTheSameInstantClaimsOnce() async throws {
        let store = try JobStore(path: tempURL())
        try await store.add(job(next: date(2026, 10, 27, 8)))
        let now = date(2026, 10, 27, 8)
        let first = try await store.claimDue(now: now, timeZone: utc)
        #expect(first.count == 1)
        #expect(first[0].slot == date(2026, 10, 27, 8))
        #expect(try await store.claimDue(now: now, timeZone: utc).isEmpty)
    }

    @Test func missedSlotsCollapseIntoOneRun() async throws {
        let store = try JobStore(path: tempURL())
        try await store.add(job(next: date(2026, 10, 27, 8)))
        let now = date(2026, 10, 27, 13)
        #expect(try await store.claimDue(now: now, timeZone: utc).count == 1)
        #expect(try await store.list()[0].nextRun == date(2026, 10, 27, 14))
        #expect(try await store.claimDue(now: now, timeZone: utc).isEmpty)
    }

    @Test(arguments: [0, 2, 20, 50])
    func lateClaimOnFallBackDayStillFiresOnce(minutesLate: Int) async throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let store = try JobStore(path: tempURL())
        try await store.add(job(.cron("30 1 * * *"), next: date(2026, 11, 1, 5, 30)))   // 01:30 EDT
        let now = date(2026, 11, 1, 5, 30).addingTimeInterval(Double(minutesLate) * 60)
        #expect(try await store.claimDue(now: now, timeZone: newYork).count == 1)
        #expect(try await store.list()[0].nextRun == date(2026, 11, 2, 6, 30))   // next day 01:30 EST
    }

    @Test func lateEveryJobCountsFromNow() async throws {
        let store = try JobStore(path: tempURL())
        try await store.add(job(.every(900), next: date(2026, 10, 27, 8)))
        let now = date(2026, 10, 27, 8, 14)
        #expect(try await store.claimDue(now: now, timeZone: utc).count == 1)
        #expect(try await store.list()[0].nextRun == now.addingTimeInterval(900))
    }

    @Test func notDueYetIsLeftAlone() async throws {
        let store = try JobStore(path: tempURL())
        try await store.add(job(next: date(2026, 10, 27, 8)))
        #expect(try await store.claimDue(now: date(2026, 10, 27, 7, 59), timeZone: utc).isEmpty)
    }

    @Test func upsertReplacesInOneRowAndAddsWhenMissing() async throws {
        let store = try JobStore(path: tempURL())
        var j = job(id: "u", next: date(2026, 10, 27, 8))
        try await store.upsert(j)  // missing: adds
        j.prompt = "newer"
        j.nextRun = date(2026, 10, 28, 9)
        j.messages = [.user("latest")]
        try await store.upsert(j)
        let jobs = try await store.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].prompt == "newer")
        #expect(jobs[0].nextRun == date(2026, 10, 28, 9))
        #expect(jobs[0].messages == [.user("latest")])
        await #expect(throws: (any Error).self) { try await store.add(j) }  // add still refuses a duplicate id
    }

    @Test func persistsAcrossReopenAndDeletes() async throws {
        let url = tempURL()
        var j = job(next: date(2026, 10, 27, 8))
        j.messages = [.user("resume"), .assistant("ok")]
        try await JobStore(path: url).add(j)
        let store = try JobStore(path: url)
        let loaded = try await store.list()
        #expect(loaded.map(\.id) == ["j"])
        #expect(loaded[0].messages == j.messages)
        try await store.delete("j")
        #expect(try await store.list().isEmpty)
    }

    @Test func concurrentFirstOpensNeverFailWithLocked() async throws {
        for _ in 0..<50 {
            let url = tempURL()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<4 {
                    group.addTask { if i.isMultiple(of: 2) { _ = try JobStore(path: url) } else { _ = try SessionLog(path: url) } }
                }
                try await group.waitForAll()
            }
        }
    }

    @Test func twoConnectionsOnOneFileWorkConcurrently() async throws {
        let url = tempURL()
        let store = try JobStore(path: url)
        let log = try SessionLog(path: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { try await store.add(job(id: "j\(i)", next: date(2026, 10, 27, 8))) }
                group.addTask {
                    try await log.log(RunRecord(id: "r\(i)", date: .now, messages: [.user("hello \(i)")], usage: .zero))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.list().count == 40)
        #expect(try await log.search("hello", limit: 100).count == 40)
    }
}

// MARK: scheduler

@Suite struct SchedulerTests {
    let noon = date(2026, 10, 27, 12)

    @Test func leadRunsEarlyAndDeliversAtTheSlot() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        let slot = date(2026, 10, 27, 8)
        try await store.add(job(.cron("0 8 * * *"), next: slot, lead: 6 * 3600))
        let s = scheduler(store, notifier, Script([reply("Brief"), reply("again")]))
        let early = date(2026, 10, 27, 2, 30)
        await s.tick(now: early, deadline: early.addingTimeInterval(30))
        let delivered = await notifier.delivered
        #expect(delivered.count == 1)
        #expect(delivered[0].text == "Brief")
        #expect(delivered[0].at == slot)
        #expect(try await store.list()[0].nextRun == date(2026, 10, 28, 8))  // not today's slot again
        await s.tick(now: early.addingTimeInterval(60), deadline: early.addingTimeInterval(90))
        #expect(await notifier.delivered.count == 1)
    }

    @Test func overdueRunDeliversNow() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        try await store.add(job(next: date(2026, 10, 27, 8)))
        await scheduler(store, notifier, Script([reply("late")])).tick(now: noon, deadline: noon.addingTimeInterval(30))
        let delivered = await notifier.delivered
        #expect(delivered.count == 1)
        #expect(delivered[0].at == nil)
        #expect(try await store.runs("j") == ["done"])
    }

    @Test(arguments: ["HOLD", " hold \n", "", "  ", "HOLD.", "**HOLD**", "\"HOLD\"", "HOLD - nothing new", "HOLD: no change", "Hold."])
    func holdAndEmptyDeliverNothing(_ text: String) async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        try await store.add(job(next: date(2026, 10, 27, 8)))
        await scheduler(store, notifier, Script([reply(text)])).tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await notifier.delivered.isEmpty)
        #expect(try await store.runs("j") == ["done"])
    }

    @Test(arguments: ["Holding the deck for you", "Hold the meeting at 3, bring slides"])
    func textThatOnlyStartsWithHoldWordsIsDelivered(_ text: String) async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        try await store.add(job(next: date(2026, 10, 27, 8)))
        await scheduler(store, notifier, Script([reply(text)]))
            .tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await notifier.delivered.map(\.text) == [text])
    }

    @Test func cancellingTheTickAlwaysCutsOffAndKeepsTheSlot() async throws {
        let store = try JobStore(path: tempURL())
        let slot = date(2026, 10, 27, 8)
        try await store.add(job(next: slot))
        let s = scheduler(store, Recorder(), Script([], delay: .seconds(30)))
        for i in 1...30 {
            let tick = Task { await s.tick(now: noon, deadline: noon.addingTimeInterval(60)) }
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...20)))
            tick.cancel()
            await tick.value
            #expect(try await store.runs("j") == Array(repeating: "cutoff", count: i))
            #expect(try await store.list()[0].nextRun == slot)
        }
    }

    @Test func oneShotIsRetriedAfterTransientFailuresThenDropped() async throws {
        let store = try JobStore(path: tempURL())
        let slot = date(2026, 10, 27, 8)
        try await store.add(job(.once(slot), next: slot))
        let broken = scheduler(store, Recorder(), Script([]))
        for _ in 0..<2 {
            await broken.tick(now: noon, deadline: noon.addingTimeInterval(30))
            #expect(try await store.list().map(\.nextRun) == [slot])
        }
        await broken.tick(now: noon, deadline: noon.addingTimeInterval(30))  // third failure
        #expect(try await store.list().isEmpty)
        #expect(try await store.runs("j") == ["failed", "failed", "failed"])
    }

    @Test func oneShotIsDeliveredOnARetry() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        let slot = date(2026, 10, 27, 8)
        try await store.add(job(.once(slot), next: slot, timeout: 0.2))
        await scheduler(store, notifier, Script([reply("x")], delay: .seconds(30)))
            .tick(now: noon, deadline: noon.addingTimeInterval(30))  // times out
        #expect(try await store.list().count == 1)
        await scheduler(store, notifier, Script([reply("reminder")])).tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await notifier.delivered.map(\.text) == ["reminder"])
        #expect(try await store.list().isEmpty)
        #expect(try await store.runs("j") == ["timeout", "done"])
    }

    @Test func timeoutLogsAndDeliversNothing() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        try await store.add(job(next: date(2026, 10, 27, 8), timeout: 0.2))
        let slow = Script([reply("never")], delay: .seconds(30))
        await scheduler(store, notifier, slow).tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await notifier.delivered.isEmpty)
        #expect(try await store.runs("j") == ["timeout"])
    }

    @Test func deadlineCutsOffAndTheSlotRunsLater() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        let slot = date(2026, 10, 27, 8)
        try await store.add(job(next: slot))
        let slow = Script([reply("never")], delay: .seconds(30))
        await scheduler(store, notifier, slow).tick(now: noon, deadline: noon.addingTimeInterval(0.2))
        #expect(await notifier.delivered.isEmpty)
        #expect(try await store.runs("j") == ["cutoff"])
        #expect(try await store.list()[0].nextRun == slot)

        let later = noon.addingTimeInterval(600)
        let s = scheduler(store, notifier, Script([reply("caught up")]))
        await s.tick(now: later, deadline: later.addingTimeInterval(30))
        #expect(await notifier.delivered.map(\.text) == ["caught up"])
        #expect(try await store.runs("j") == ["cutoff", "done"])
        await s.tick(now: later, deadline: later.addingTimeInterval(30))
        #expect(await notifier.delivered.count == 1)
    }

    @Test func deadlineAlreadyPassedSkipsTheRun() async throws {
        let store = try JobStore(path: tempURL())
        try await store.add(job(next: date(2026, 10, 27, 8)))
        await scheduler(store, Recorder(), Script([])).tick(now: noon, deadline: noon)
        #expect(try await store.runs("j") == ["cutoff"])
    }

    @Test func failedRunIsLogged() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        try await store.add(job(next: date(2026, 10, 27, 8)))
        await scheduler(store, notifier, Script([])).tick(now: noon, deadline: noon.addingTimeInterval(30))  // provider throws
        #expect(await notifier.delivered.isEmpty)
        #expect(try await store.runs("j") == ["failed"])
    }

    @Test func oneShotJobIsRemovedAfterItsRun() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        try await store.add(job(.once(date(2026, 10, 27, 8)), next: date(2026, 10, 27, 8)))
        await scheduler(store, notifier, Script([reply("once")])).tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await notifier.delivered.map(\.text) == ["once"])
        #expect(try await store.list().isEmpty)
    }

    @Test func approvalToolIsDeclinedAndTheRunCompletes() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        let ran = Counter()
        let danger = AnyTool(
            spec: ToolSpec(name: "danger", description: "d", schema: .object([:], required: [])), kind: .approval
        ) { _ in await ran.bump(); return "boom" }
        try await store.add(job(next: date(2026, 10, 27, 8)))
        let provider = Script([
            reply("", calls: [ToolCall(id: "1", name: "danger", argumentsJSON: "{}")]),
            reply("finished"),
        ])
        await scheduler(store, notifier, provider, tools: [danger]).tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await ran.n == 0)
        #expect(await notifier.delivered.map(\.text) == ["finished"])
        #expect(try await store.runs("j") == ["done"])
    }

    @Test func exhaustedBudgetIsFailedAndSendsNothing() async throws {
        let store = try JobStore(path: tempURL())
        let notifier = Recorder()
        var j = job(next: date(2026, 10, 27, 8))
        j.budget = 1
        try await store.add(j)
        let call = ToolCall(id: "1", name: "missing", argumentsJSON: "{}")
        await scheduler(store, notifier, Script([reply("working", calls: [call])]))
            .tick(now: noon, deadline: noon.addingTimeInterval(30))
        #expect(await notifier.delivered.isEmpty)
        #expect(try await store.runs("j") == ["failed"])
    }
}

// MARK: tool

@Suite struct ScheduleToolTests {
    func tool(_ store: JobStore) -> ScheduleTool {
        ScheduleTool(store: store, timeZone: utc, now: { date(2026, 10, 27, 9) })
    }

    @Test func schedulesACronJob() async throws {
        let store = try JobStore(path: tempURL())
        let t = tool(store)
        #expect(t.kind == .approval)
        let out = try await t.call(.init(prompt: "brief me", cron: "0 8 * * *", leadMinutes: 30))
        #expect(out.hasPrefix("Scheduled "))
        #expect(out.hasSuffix("next run 2026-10-28T08:00:00Z."))
        let jobs = try await store.list()
        #expect(jobs.count == 1)
        #expect(jobs[0].lead == 1800)
        #expect(jobs[0].nextRun == date(2026, 10, 28, 8))
        #expect(jobs[0].schedule == .cron("0 8 * * *"))
    }

    @Test func everyAndAt() async throws {
        let store = try JobStore(path: tempURL())
        let t = tool(store)
        _ = try await t.call(.init(prompt: "p", everyMinutes: 30))
        _ = try await t.call(.init(prompt: "p", at: "2026-11-01T09:00:00+08:00"))
        let jobs = try await store.list().sorted { $0.nextRun < $1.nextRun }
        #expect(jobs[0].schedule == .every(1800))
        #expect(jobs[0].nextRun == date(2026, 10, 27, 9, 30))
        #expect(jobs[1].schedule == .once(date(2026, 11, 1, 1)))
    }

    @Test func rejectsBadInputWithAnErrorString() async throws {
        let store = try JobStore(path: tempURL())
        let t = tool(store)
        let bad: [ScheduleTool.Args] = [
            .init(prompt: "p"),
            .init(prompt: "p", cron: "0 8 * * *", everyMinutes: 5),
            .init(prompt: "p", cron: "nope"),
            .init(prompt: "p", everyMinutes: 0),
            .init(prompt: "p", at: "tomorrow"),
            .init(prompt: "p", at: "2020-01-01T00:00:00Z"),
            .init(prompt: "p", cron: "0 8 * * *", leadMinutes: -1),
        ]
        for args in bad { #expect(try await t.call(args).hasPrefix("Error:")) }
        #expect(try await store.list().isEmpty)
    }
}
