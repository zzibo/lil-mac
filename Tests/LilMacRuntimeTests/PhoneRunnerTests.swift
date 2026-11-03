import Foundation
import LilMac
import Testing
@testable import LilMacRuntime

// MARK: doubles

/// Virtual time: `sleep` returns at once and advances `now`; past `limit` it parks until cancelled.
actor VirtualClock {
    let limit: Duration
    private(set) var now = Duration.zero
    private(set) var ticks: [Duration] = []
    private(set) var parked = false
    init(limit: Duration) { self.limit = limit }
    func sleep(_ d: Duration) async throws {
        if now + d > limit {
            parked = true
            try await Task.sleep(for: .seconds(3600))
        }
        now += d
    }
    func tick() -> Duration { ticks.append(now); return now }
    var seconds: [Int] { ticks.map { Int($0.components.seconds) } }
}

actor Holder { var ticker: ForegroundTicker?; func set(_ t: ForegroundTicker) { ticker = t } }

/// Counts ticks and the most that ran at once.
actor Probe {
    private(set) var started = 0, active = 0, peak = 0
    func enter() { started += 1; active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

func settle(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: ForegroundTicker

@Suite struct ForegroundTickerTests {
    /// 95 s at 30 s: the first tick is immediate, so ticks land at 0, 30, 60 and 90 (4, not 3).
    @Test func ticksImmediatelyThenEveryInterval() async {
        let clock = VirtualClock(limit: .seconds(95))
        let ticker = ForegroundTicker(interval: .seconds(30), sleep: { try await clock.sleep($0) }) { _ = await clock.tick() }
        await ticker.start()
        await settle { await clock.parked }
        await ticker.stop()
        #expect(await clock.seconds == [0, 30, 60, 90])
    }

    @Test func tenSecondsGivesTenTicksIn95Seconds() async {
        let clock = VirtualClock(limit: .seconds(95))
        let ticker = ForegroundTicker(interval: .seconds(10), sleep: { try await clock.sleep($0) }) { _ = await clock.tick() }
        await ticker.start()
        await settle { await clock.parked }
        await ticker.stop()
        #expect(await clock.seconds == Array(stride(from: 0, through: 90, by: 10)))
    }

    @Test func newIntervalTakesEffectFromTheNextWait() async {
        let clock = VirtualClock(limit: .seconds(95))
        let holder = Holder()
        let ticker = ForegroundTicker(interval: .seconds(30), sleep: { try await clock.sleep($0) }) {
            if await clock.tick() == .seconds(30) { await holder.ticker?.setInterval(.seconds(10)) }
        }
        await holder.set(ticker)
        await ticker.start()
        await settle { await clock.parked }
        await ticker.stop()
        #expect(await clock.seconds == [0, 30, 40, 50, 60, 70, 80, 90])
    }

    @Test func aSlowTickNeverOverlapsTheNext() async {
        let probe = Probe()
        let ticker = ForegroundTicker(interval: .milliseconds(1), sleep: { _ in }) {
            await probe.enter()
            try? await Task.sleep(for: .milliseconds(20))
            await probe.leave()
        }
        await ticker.start()
        await settle { await probe.started >= 3 }
        await ticker.stop()
        #expect(await probe.peak == 1)
        #expect(await probe.started >= 3)
    }

    @Test func stopEndsTheTicks() async {
        let probe = Probe()
        let ticker = ForegroundTicker(interval: .milliseconds(10)) { await probe.enter(); await probe.leave() }
        await ticker.start()
        await settle { await probe.started >= 2 }
        await ticker.stop()
        try? await Task.sleep(for: .milliseconds(40))  // a tick already in flight may land
        let after = await probe.started
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await probe.started == after)
    }

    @Test func startingTwiceRunsOneLoop() async {
        let clock = VirtualClock(limit: .seconds(95))
        let ticker = ForegroundTicker(interval: .seconds(30), sleep: { try await clock.sleep($0) }) { _ = await clock.tick() }
        await ticker.start()
        await ticker.start()
        await settle { await clock.parked }
        await ticker.stop()
        #expect(await clock.seconds == [0, 30, 60, 90])
    }

    @Test func restartDuringATickWaitsForIt() async {
        let probe = Probe()
        let ticker = ForegroundTicker(interval: .milliseconds(1), sleep: { _ in }) {
            await probe.enter()
            await Task { try? await Task.sleep(for: .milliseconds(50)) }.value  // a tick ignores cancellation
            await probe.leave()
        }
        await ticker.start()
        await settle { await probe.active == 1 }
        await ticker.stop()
        await ticker.start()
        try? await Task.sleep(for: .milliseconds(200))
        await ticker.stop()
        #expect(await probe.peak == 1)
        #expect(await probe.started >= 2)
    }

    @Test func aSecondStopKeepsTheHandleOfTheLoopStillInItsTick() async {
        let probe = Probe()
        let ticker = ForegroundTicker(interval: .milliseconds(1), sleep: { _ in }) {
            await probe.enter()
            await Task { try? await Task.sleep(for: .milliseconds(50)) }.value  // a tick ignores cancellation
            await probe.leave()
        }
        await ticker.start()
        await settle { await probe.active == 1 }
        await ticker.stop()
        await ticker.stop()
        await ticker.start()
        try? await Task.sleep(for: .milliseconds(200))
        await ticker.stop()
        #expect(await probe.peak == 1)
        #expect(await probe.started >= 2)
    }
}

// MARK: resume

/// Answers `calls[0]` at once; every later request parks until cancelled when `stall` is set.
actor Staged: Provider {
    private var replies: [ModelReply]
    private let stall: Bool
    private(set) var sends = 0
    private(set) var idsAtFirstSend: [String] = []
    private let store: JobStore?
    init(_ replies: [ModelReply], stall: Bool = false, store: JobStore? = nil) {
        self.replies = replies; self.stall = stall; self.store = store
    }
    func send(_ request: ModelRequest) async throws -> ModelReply {
        sends += 1
        if sends == 1, let store { idsAtFirstSend = try await store.list().map(\.id) }
        if replies.isEmpty {
            if stall { try await Task.sleep(for: .seconds(3600)) }
            return reply("done")
        }
        return replies.removeFirst()
    }
}

actor Events {
    private(set) var all: [AgentEvent] = []
    func add(_ e: AgentEvent) { all.append(e) }
    var actions: [ToolCall] { all.compactMap { if case .action(let c) = $0 { c } else { nil } } }
    var checkpoint: [Message]? { all.compactMap { if case .checkpoint(let m) = $0 { m } else { nil } }.last }
}

let lookupCall = ToolCall(id: "c1", name: "lookup", argumentsJSON: "{}")
let noteCall = ToolCall(id: "c2", name: "save_note", argumentsJSON: "{\"text\":\"milk\"}")

func chatAgent(_ provider: any Provider) -> Agent {
    let lookup = AnyTool(spec: ToolSpec(name: "lookup", description: "d", schema: .object([:], required: [])), kind: .read) { _ in "fact" }
    let note = AnyTool(spec: ToolSpec(name: "save_note", description: "d", schema: .object([:], required: [])), kind: .action) { _ in "" }
    return Agent(provider: provider, system: "s", toolset: Toolset(name: "chat", tools: [lookup, note]))
}

func resumeJobs(_ store: JobStore) async throws -> [Job] {
    try await store.list().filter { $0.id.hasPrefix(resumePrefix) }
}

@Suite struct ResumeTests {
    let transcript: [Message] = [.user("hi"), .assistant("", toolCalls: [lookupCall]), .tool(id: "c1", "fact")]

    @Test func eachCheckpointReplacesTheSavedJob() async throws {
        let store = try JobStore(path: tempURL())
        let (expiry, _) = AsyncStream<Void>.makeStream()
        let provider = Staged([reply("", calls: [lookupCall])], store: store)
        let matches = Counter()
        await ChatRuns(store: store).run(chatAgent(provider), [.user("hi")], toolset: "chat", expiry: expiry) {
            guard case .checkpoint(let all) = $0 else { return }
            let jobs = (try? await resumeJobs(store)) ?? []
            if jobs.count == 1, jobs[0].messages == all { await matches.bump() }  // the saved job is this checkpoint
        }
        #expect(await matches.n == 1)
        #expect(await provider.idsAtFirstSend.count == 1)  // saved with the original messages before step 1
        #expect(try await resumeJobs(store).isEmpty)  // finished normally: deleted
    }

    @Test func expiryLeavesTheLatestTranscriptSaved() async throws {
        let store = try JobStore(path: tempURL())
        let (expiry, expire) = AsyncStream<Void>.makeStream()
        let events = Events()
        let provider = Staged([reply("", calls: [lookupCall])], stall: true)
        await ChatRuns(store: store).run(chatAgent(provider), [.user("hi")], toolset: "chat", expiry: expiry) {
            await events.add($0)
            if case .checkpoint = $0 { expire.yield() }
        }

        let jobs = try await resumeJobs(store)
        #expect(jobs.count == 1)
        let saved = try #require(jobs.first)
        #expect(saved.schedule == .once(.distantFuture))
        #expect(saved.toolset == "chat")
        #expect(saved.messages == (await events.checkpoint))
        #expect(saved.messages?.count == 3)  // user, assistant with the call, tool result
        #expect(saved.messages?.last?.role == .tool)
        #expect(try await store.claimDue(now: .now).isEmpty)  // the scheduler never claims it
    }

    @Test func expiryBeforeAnyCheckpointKeepsTheOriginalMessages() async throws {
        let store = try JobStore(path: tempURL())
        let (expiry, expire) = AsyncStream<Void>.makeStream()
        let provider = Staged([], stall: true)
        let run = Task { await ChatRuns(store: store).run(chatAgent(provider), [.user("hi")], toolset: "chat", expiry: expiry) { _ in } }
        await settle { await provider.sends >= 1 }
        expire.yield()
        await run.value
        #expect(try await resumeJobs(store).first?.messages == [.user("hi")])
    }

    @Test func finishedRunLeavesNothingAndSendsDone() async throws {
        let store = try JobStore(path: tempURL())
        let (expiry, _) = AsyncStream<Void>.makeStream()
        let events = Events()
        await ChatRuns(store: store).run(chatAgent(Staged([reply("hello")])), [.user("hi")], toolset: "chat", expiry: expiry) {
            await events.add($0)
        }
        #expect(try await store.list().isEmpty)
        #expect(await events.all.contains { if case .done = $0 { true } else { false } })
    }

    @Test func aRunTheUserStopsLeavesNothing() async throws {
        let store = try JobStore(path: tempURL())
        let (expiry, _) = AsyncStream<Void>.makeStream()
        let provider = Staged([], stall: true)
        let run = Task { await ChatRuns(store: store).run(chatAgent(provider), [.user("hi")], toolset: "chat", expiry: expiry) { _ in } }
        await settle { await provider.sends >= 1 }
        run.cancel()
        await run.value
        #expect(try await store.list().isEmpty)
    }

    @Test func resumeKeepsItsJobWhileRunningAndDeletesItOnFinish() async throws {
        let store = try JobStore(path: tempURL())
        let runs = ChatRuns(store: store)
        try await saveResumeJob([.user("hi")], toolset: "chat", id: "resume-old", to: store)
        try await store.add(job(id: "keep", next: .distantFuture))
        let provider = Staged([reply("", calls: [noteCall])], store: store)
        let events = Events()
        let (expiry, _) = AsyncStream<Void>.makeStream()
        await runs.resume { id, messages, toolset in
            await runs.run(chatAgent(provider), messages, toolset: toolset, id: id, expiry: expiry) { await events.add($0) }
        }

        #expect(await provider.idsAtFirstSend.contains("resume-old"))  // saved until it finishes: a kill loses nothing
        #expect(await events.actions == [noteCall])
        #expect(try await store.list().map(\.id) == ["keep"])
    }

    @Test func resumeRunsOnceWhenCalledManyTimesAtTheSameTime() async throws {
        let store = try JobStore(path: tempURL())
        let runs = ChatRuns(store: store)
        try await saveResumeJob([.user("hi")], toolset: "chat", to: store)
        let provider = Staged([reply("", calls: [noteCall])])
        let (expiry, _) = AsyncStream<Void>.makeStream()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await runs.resume { id, messages, toolset in
                        await runs.run(chatAgent(provider), messages, toolset: toolset, id: id, expiry: expiry) { _ in }
                    }
                }
            }
        }
        #expect(await provider.sends == 2)  // one run: the action step, then the answer
        #expect(try await resumeJobs(store).isEmpty)
    }

    @Test func resumePassesTheSavedIdMessagesAndToolset() async throws {
        let store = try JobStore(path: tempURL())
        try await saveResumeJob(transcript, toolset: "notes", id: "resume-old", to: store)
        nonisolated(unsafe) var got: (String, [Message], String)?
        await ChatRuns(store: store).resume { got = ($0, $1, $2) }
        #expect(got?.0 == "resume-old")
        #expect(got?.1 == transcript)
        #expect(got?.2 == "notes")
    }

    @Test func aResumedRunThatIsCutOffKeepsItsIdWithTheNewerTranscript() async throws {
        let store = try JobStore(path: tempURL())
        let runs = ChatRuns(store: store)
        try await saveResumeJob(transcript, toolset: "chat", id: "resume-old", to: store)
        let provider = Staged([reply("", calls: [lookupCall])], stall: true)
        let (expiry, expire) = AsyncStream<Void>.makeStream()
        await runs.resume { id, messages, toolset in
            await runs.run(chatAgent(provider), messages, toolset: toolset, id: id, expiry: expiry) {
                if case .checkpoint = $0 { expire.yield() }
            }
        }
        let jobs = try await resumeJobs(store)
        #expect(jobs.map(\.id) == ["resume-old"])
        #expect(jobs.first?.messages?.count == transcript.count + 2)  // the resumed step: assistant call, tool result
        #expect(Array(jobs.first?.messages?.prefix(transcript.count) ?? []) == transcript)
    }

    @Test func aResumedRunCutOffBeforeAnyCheckpointKeepsTheSameJob() async throws {
        let store = try JobStore(path: tempURL())
        let runs = ChatRuns(store: store)
        try await saveResumeJob(transcript, toolset: "chat", id: "resume-old", to: store)
        let provider = Staged([], stall: true)
        let (expiry, expire) = AsyncStream<Void>.makeStream()
        let cut = Task {
            await settle { await provider.sends >= 1 }
            expire.yield()
        }
        await runs.resume { id, messages, toolset in
            await runs.run(chatAgent(provider), messages, toolset: toolset, id: id, expiry: expiry) { _ in }
        }
        await cut.value
        let jobs = try await resumeJobs(store)
        #expect(jobs.map(\.id) == ["resume-old"])
        #expect(jobs.first?.messages == transcript)
    }

    @Test func aRunInFlightIsNotClaimedByResume() async throws {
        let store = try JobStore(path: tempURL())
        let runs = ChatRuns(store: store)
        let provider = Staged([], stall: true)
        let (expiry, _) = AsyncStream<Void>.makeStream()
        let run = Task { await runs.run(chatAgent(provider), [.user("hi")], toolset: "chat", expiry: expiry) { _ in } }
        await settle { await provider.sends >= 1 }
        let started = Counter()
        await runs.resume { _, _, _ in await started.bump() }
        run.cancel()
        await run.value
        #expect(await started.n == 0)
    }
}
