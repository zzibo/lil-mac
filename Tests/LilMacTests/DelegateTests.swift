import Foundation
import Testing
@testable import LilMac

private func reply(_ text: String, calls: [ToolCall] = []) -> ModelReply {
    ModelReply(message: .assistant(text, toolCalls: calls), toolCalls: calls, usage: .zero)
}

private func helper(_ provider: any Provider, tools: [AnyTool] = [], budget: Int = 10) -> Agent {
    Agent(provider: provider, system: "SYS", toolset: Toolset(name: "t", tools: tools), budget: budget)
}

private final class Depths: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ depth: Int) { lock.withLock { values.append(depth) } }
    var all: [Int] { lock.withLock { values } }
}

/// Holds every request until the test releases it, and records how many ran at once.
private actor Gate: Provider {
    private(set) var started = 0
    private(set) var running = 0
    private(set) var peak = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func send(_ request: ModelRequest) async throws -> ModelReply {
        started += 1
        running += 1
        peak = max(peak, running)
        await withCheckedContinuation { waiting.append($0) }
        running -= 1
        return reply("ok")
    }

    var blocked: Int { waiting.count }
    func releaseOne() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.withLock { stored = value } }
    var value: T? { lock.withLock { stored } }
}

/// Runs `work` and returns its result, or nil if it has not finished within 5 seconds (a hang).
private func finishes<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
    let box = Box<T>()
    let task = Task { if let value = try? await work() { box.set(value) } }
    if await until({ box.value != nil }) { return box.value }
    task.cancel()
    return nil
}

/// Sends `n` delegates through `slots` against helpers that block, then frees them one at a time.
/// Returns how many helpers had started before the first release, and the peak running at once.
private func drive(_ slots: DelegateSlots, helpers n: Int, limit: Int) async throws -> (firstWave: Int, peak: Int)? {
    let gate = Gate()
    let tool = DelegateTool(slots: slots) { _, _ in helper(gate) }
    // One wave: send `count` delegates, check exactly `limit` start, then free them one at a time.
    func wave(_ count: Int) async throws -> Int? {
        let before = await gate.started
        let tasks = (0..<count).map { i in Task { try await tool.call(.init(task: "t\(i)", toolset: nil)) } }
        guard await until({ await gate.blocked == limit }) else { return nil }
        try await Task.sleep(for: .milliseconds(100))
        let started = await gate.started - before
        for _ in 0..<count {
            guard await until({ await gate.blocked > 0 }) else { return nil }
            await gate.releaseOne()
        }
        for task in tasks { #expect(try await task.value == "ok") }
        return started
    }
    guard let firstWave = try await wave(n) else { return nil }
    // After the queue drained, a leaked permit would let more than `limit` run at once.
    guard let secondWave = try await wave(limit + 1), secondWave == limit else { return nil }
    return (firstWave, await gate.peak)
}

private func until(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test func tooDeepNeverBuildsAHelper() async throws {
    let depths = Depths()
    let tool = DelegateTool(depth: 2) { _, depth in
        depths.add(depth)
        return helper(ScriptedProvider([]))
    }
    let out = try await tool.call(.init(task: "x", toolset: nil))
    #expect(out == "Error: too deep: helpers can't start more helpers here.")
    #expect(depths.all.isEmpty)
}

@Test func returnsTheHelpersFinalText() async throws {
    let tool = DelegateTool { toolset, _ in
        #expect(toolset == "web")
        return helper(ScriptedProvider([reply("found it")]))
    }
    #expect(try await tool.call(.init(task: "look", toolset: "web")) == "found it")
}

@Test func helperWithNoTextSaysDone() async throws {
    let tool = DelegateTool { _, _ in helper(ScriptedProvider([reply("")])) }
    #expect(try await tool.call(.init(task: "x", toolset: nil)) == "Done.")
}

@Test func budgetExhaustedReportsTheLastNote() async throws {
    let loop = ToolCall(id: "c", name: "nope", argumentsJSON: "{}")
    let tool = DelegateTool { _, _ in
        helper(ScriptedProvider([reply("step one", calls: [loop])]), budget: 1)
    }
    #expect(try await tool.call(.init(task: "x", toolset: nil)) == "Helper ran out of steps. Last note: step one")
}

@Test func thrownErrorBecomesAnErrorString() async throws {
    let tool = DelegateTool { _, _ in helper(ScriptedProvider([])) }   // exhausted provider throws
    let out = try await tool.call(.init(task: "x", toolset: nil))
    #expect(out.hasPrefix("Error: "))
}

@Test func nestedHelperGetsDepthPlusOne() async throws {
    let depths = Depths()
    @Sendable func make(_ toolset: String?, _ depth: Int) -> Agent {
        depths.add(depth)
        if depth == 1 {
            let inner = ToolCall(id: "c1", name: "delegate", argumentsJSON: "{\"task\":\"inner\"}")
            return helper(
                ScriptedProvider([reply("", calls: [inner]), reply("outer done")]),
                tools: [AnyTool(DelegateTool(depth: depth, makeAgent: make))])
        }
        return helper(ScriptedProvider([reply("inner done")]))
    }
    let out = try await DelegateTool(makeAgent: make).call(.init(task: "go", toolset: nil))
    #expect(out == "outer done")
    #expect(depths.all == [1, 2])
}

@Test func atMostThreeHelpersRunAtOnce() async throws {
    let result = try #require(try await drive(DelegateSlots(limit: 3), helpers: 10, limit: 3))
    #expect(result.firstWave == 3)   // the rest wait for a slot
    #expect(result.peak == 3)
}

@Test func defaultSlotsAllowExactlyThree() async throws {
    let result = try #require(try await drive(DelegateSlots(), helpers: 5, limit: 3))
    #expect(result.firstWave == 3)
    #expect(result.peak == 3)
}

@Test func limitBelowOneIsClampedToOne() async throws {
    let result = try #require(try await drive(DelegateSlots(limit: 0), helpers: 3, limit: 1))
    #expect(result.firstWave == 1)
    #expect(result.peak == 1)
}

/// A top-level delegate whose helper delegates again, `calls` levels of `delegate` calls per helper.
private func nestedTool(slots: DelegateSlots) -> DelegateTool {
    @Sendable func make(_ toolset: String?, _ depth: Int) -> Agent {
        if depth == 1 {
            let inner = ToolCall(id: "c1", name: "delegate", argumentsJSON: "{\"task\":\"inner\"}")
            return helper(
                ScriptedProvider([reply("", calls: [inner]), reply("outer done")]),
                tools: [AnyTool(DelegateTool(depth: depth, slots: slots, makeAgent: make))])
        }
        return helper(ScriptedProvider([reply("inner done")]))
    }
    return DelegateTool(slots: slots, makeAgent: make)
}

@Test func nestedDelegationInsideOneSlotCompletes() async throws {
    let tool = nestedTool(slots: DelegateSlots(limit: 1))
    let out = await finishes { try await tool.call(.init(task: "go", toolset: nil)) }
    #expect(out == "outer done")
}

@Test func parallelDelegatesThatEachDelegateComplete() async throws {
    let tool = nestedTool(slots: DelegateSlots(limit: 3))
    let outs = await finishes {
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<3 { group.addTask { try await tool.call(.init(task: "t\(i)", toolset: nil)) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
    #expect(outs == ["outer done", "outer done", "outer done"])
}

@Test func cancelledWaiterLeavesTheQueueWithoutTakingASlot() async throws {
    let gate = Gate()
    let slots = DelegateSlots(limit: 1)
    let holder = DelegateTool(slots: slots) { _, _ in helper(gate) }
    let quick = DelegateTool(slots: slots) { _, _ in helper(ScriptedProvider([reply("quick")])) }
    let first = Task { try await holder.call(.init(task: "a", toolset: nil)) }
    #expect(await until { await gate.blocked == 1 })

    let waiter = Task { try await quick.call(.init(task: "b", toolset: nil)) }
    try await Task.sleep(for: .milliseconds(100))   // let it queue behind the holder
    waiter.cancel()
    #expect(await finishes { try await waiter.value } == "Error: cancelled")

    await gate.releaseOne()
    #expect(try await first.value == "ok")
    #expect(await gate.started == 1)
    // The slot came back; a cancelled waiter did not keep it.
    #expect(await finishes { try await quick.call(.init(task: "c", toolset: nil)) } == "quick")
}

@Test func nestedHelpersAreAlsoCappedAtThreeAtOnce() async throws {
    let gate = Gate()
    let tool = DelegateTool(depth: 1, nestedSlots: DelegateSlots(limit: 3)) { _, _ in helper(gate) }
    let tasks = (0..<6).map { i in Task { try await tool.call(.init(task: "t\(i)", toolset: nil)) } }
    #expect(await until({ await gate.blocked == 3 }))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await gate.started == 3)
    for _ in 0..<6 {
        #expect(await until({ await gate.blocked > 0 }))
        await gate.releaseOne()
    }
    for task in tasks { #expect(try await task.value == "ok") }
    #expect(await gate.peak == 3)
}
