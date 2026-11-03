import Foundation
import Testing
@testable import LilMac

// MARK: helpers

private func reply(_ text: String = "", calls: [ToolCall] = [], usage: Usage = .zero) -> ModelReply {
    ModelReply(message: .assistant(text, toolCalls: calls), toolCalls: calls, usage: usage)
}

private func call(_ id: String, _ name: String, _ args: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, argumentsJSON: args)
}

private actor Ran {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

private func tool(
    _ name: String, _ kind: ToolKind, ran: Ran? = nil,
    body: @escaping @Sendable (String) async throws -> String = { _ in "ok" }
) -> AnyTool {
    AnyTool(spec: ToolSpec(name: name, description: name, schema: .object([:], required: [])), kind: kind) { json in
        await ran?.add(name)
        return try await body(json)
    }
}

private func agent(
    _ provider: any Provider, _ tools: [AnyTool] = [], budget: Int = 10,
    memory: (any MemoryStore)? = nil,
    approve: @escaping @Sendable (ToolCall) async -> Bool = { _ in false }
) -> Agent {
    Agent(provider: provider, system: "SYS", toolset: Toolset(name: "t", tools: tools),
          memory: memory, budget: budget, approve: approve)
}

private func collect(_ agent: Agent, _ messages: [Message] = [.user("hi")]) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in agent.run(messages) { events.append(event) }
    return events
}

private func toolMessages(_ request: ModelRequest) -> [Message] { request.messages.filter { $0.role == .tool } }

private struct Boom: Error {}

private struct Echo: Tool {
    struct Args: Codable, Sendable { var text: String }
    let name = "echo"
    let description = "Echoes text."
    let schema = JSONSchema.object(["text": .string()], required: ["text"])
    let kind = ToolKind.read
    func call(_ args: Args) async throws -> String { "echo: \(args.text)" }
}

private actor FakeMemory: MemoryStore {
    private(set) var logged: [RunRecord] = []
    func snapshot() async -> String { "likes tea" }
    func remember(_ text: String, in file: MemoryFile) async throws {}
    func search(_ query: String, limit: Int) async throws -> [SessionHit] { [] }
    func log(_ run: RunRecord) async throws { logged.append(run) }
}

/// Step 1 returns a tool call. Step 2 sleeps (ignoring cancellation) then returns another tool call.
private actor StallingProvider: Provider {
    private(set) var count = 0
    func send(_ request: ModelRequest) async throws -> ModelReply {
        count += 1
        if count == 2 { try? await Task.sleep(for: .seconds(30)) }
        return reply(calls: [call("c\(count)", "t")])
    }
}

private struct Failing: Provider {
    let error: any Error
    func send(_ request: ModelRequest) async throws -> ModelReply { throw error }
}

// MARK: loop

@Test func stopsAtBudget() async throws {
    let provider = ScriptedProvider((1...5).map { reply(calls: [call("c\($0)", "t")]) })
    let events = try await collect(agent(provider, [tool("t", .read)], budget: 3))
    #expect(await provider.requests.count == 3)
    guard case .budgetExhausted = events.last else { Issue.record("last was \(String(describing: events.last))"); return }
}

@Test func cancelStops() async throws {
    let provider = StallingProvider()
    let a = agent(provider, [tool("t", .read)])
    let consumer = Task { for try await _ in a.run([.user("hi")]) {} }
    while await provider.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    consumer.cancel()
    _ = try? await consumer.value
    try await Task.sleep(for: .milliseconds(200))
    #expect(await provider.count == 2)
}

@Test func readRunsActionEmits() async throws {
    let ran = Ran()
    let provider = ScriptedProvider([
        reply(calls: [call("c1", "r"), call("c2", "a")]),
        reply("done"),
    ])
    let events = try await collect(agent(provider, [
        tool("r", .read, ran: ran) { _ in "read-result" },
        tool("a", .action, ran: ran),
    ]))
    let second = await provider.requests[1]
    #expect(toolMessages(second) == [
        .tool(id: "c1", "read-result"),
        .tool(id: "c2", "Shown to the user; nothing happens until they act."),
    ])
    #expect(events.contains { if case .action(let c) = $0 { c.id == "c2" } else { false } })
    #expect(await ran.names == ["r"])
}

@Test func approvalDeclined() async throws {
    let ran = Ran()
    let provider = ScriptedProvider([reply(calls: [call("c1", "p")]), reply("done")])
    _ = try await collect(agent(provider, [tool("p", .approval, ran: ran)]))
    #expect(toolMessages(await provider.requests[1]) == [.tool(id: "c1", "The user declined.")])
    #expect(await ran.names.isEmpty)
}

@Test func approvalAccepted() async throws {
    let ran = Ran()
    let provider = ScriptedProvider([reply(calls: [call("c1", "p")]), reply("done")])
    _ = try await collect(agent(provider, [tool("p", .approval, ran: ran)], approve: { $0.id == "c1" }))
    #expect(toolMessages(await provider.requests[1]) == [.tool(id: "c1", "ok")])
    #expect(await ran.names == ["p"])
}

@Test func unknownToolAndBadArgs() async throws {
    let provider = ScriptedProvider([
        reply(calls: [call("c1", "nope"), call("c2", "echo", "not json"), call("c3", "boom")]),
        reply("done"),
    ])
    let events = try await collect(agent(provider, [
        AnyTool(Echo()),
        tool("boom", .read) { _ in throw Boom() },
    ]))
    let results = toolMessages(await provider.requests[1])
    #expect(results.map(\.toolCallId) == ["c1", "c2", "c3"])
    #expect(results[0].text == "Error: unknown tool nope")
    #expect(results[1].text.hasPrefix("Error: invalid arguments: "))
    #expect(results[2].text == "Error: Boom()")
    guard case .done = events.last else { Issue.record("last was \(String(describing: events.last))"); return }
}

@Test func sameToolTwice() async throws {
    let provider = ScriptedProvider([
        reply(calls: [call("c1", "t", "slow"), call("c2", "t", "fast")]),
        reply("done"),
    ])
    _ = try await collect(agent(provider, [tool("t", .read) { json in
        if json == "slow" { try await Task.sleep(for: .milliseconds(80)) }
        return "r:\(json)"
    }]))
    #expect(toolMessages(await provider.requests[1]) == [.tool(id: "c1", "r:slow"), .tool(id: "c2", "r:fast")])
}

@Test func systemByteStable() async throws {
    let memory = FakeMemory()
    let provider = ScriptedProvider([reply(calls: [call("c1", "t")]), reply("done")])
    _ = try await collect(agent(provider, [tool("t", .read)], memory: memory))
    let requests = await provider.requests
    #expect(requests.map(\.system) == ["SYS", "SYS"])
    #expect(requests.allSatisfy { $0.messages[0].text == "<memory>\nlikes tea\n</memory>\n\nhi" })
    let logged = await memory.logged
    #expect(logged.count == 1)
    #expect(logged[0].messages.first == .user("hi"))
    #expect(logged[0].messages.last?.text == "done")
}

@Test func checkpointAfterStep() async throws {
    let c = call("c1", "t")
    let provider = ScriptedProvider([reply(calls: [c]), reply("done")])
    let events = try await collect(agent(provider, [tool("t", .read)]))
    let checkpoints = events.compactMap { event -> [Message]? in
        if case .checkpoint(let m) = event { m } else { nil }
    }
    #expect(checkpoints == [[.user("hi"), .assistant("", toolCalls: [c]), .tool(id: "c1", "ok")]])
}

@Test func doneSumsUsage() async throws {
    let provider = ScriptedProvider([
        reply(calls: [call("c1", "t")], usage: Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, model: "a")),
        reply("done", usage: Usage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, model: "b")),
    ])
    let events = try await collect(agent(provider, [tool("t", .read)]))
    guard case .done(let usage) = events.last else { Issue.record("no done"); return }
    #expect(usage == Usage(input: 11, output: 22, cacheRead: 33, cacheWrite: 44, model: "b"))
}

// MARK: fallback

@Test func fallbackOn5xx() async throws {
    let second = ScriptedProvider([reply("from second")])
    let provider = Fallback([Failing(error: ProviderError.http(503)), second])
    let result = try await provider.send(ModelRequest(system: "s", messages: [.user("hi")], tools: []))
    #expect(result.message.text == "from second")
}

@Test func fallbackRethrows401() async throws {
    let second = ScriptedProvider([reply("from second")])
    let provider = Fallback([Failing(error: ProviderError.http(401)), second])
    await #expect(throws: ProviderError.http(401)) {
        try await provider.send(ModelRequest(system: "s", messages: [], tools: []))
    }
    #expect(await second.requests.isEmpty)
}

@Test func fallbackTriesAllThenRethrowsLast() async throws {
    let provider = Fallback([
        Failing(error: ProviderError.http(429)),
        Failing(error: URLError(.timedOut)),
        Failing(error: ProviderError.timeout),
        Failing(error: ProviderError.http(502)),
    ])
    await #expect(throws: ProviderError.http(502)) {
        try await provider.send(ModelRequest(system: "s", messages: [], tools: []))
    }
}
