import Testing
@testable import LilMac

private func reply(_ text: String) -> ModelReply {
    ModelReply(message: .assistant(text), toolCalls: [], usage: .zero)
}

private func call(_ id: String) -> ToolCall { ToolCall(id: id, name: "read", argumentsJSON: "{\"q\":1}") }

/// Ten short alternating messages that always sit in the tail.
private func tail(_ n: Int = 10) -> [Message] {
    (0..<n).map { $0.isMultiple(of: 2) ? .user("u\($0)") : .assistant("a\($0)") }
}

private func compactor(_ summarizer: ScriptedProvider, window: Int = 1000) -> Compactor {
    Compactor(contextWindow: window, summarizer: summarizer)   // limit: 500 tokens = 2000 characters
}

@Test func underThresholdIsUnchanged() async throws {
    let summarizer = ScriptedProvider([])
    let messages = [.user("hi"), .assistant("hello")] + tail()
    let out = try await compactor(summarizer).fit(messages)
    #expect(out == messages)
    #expect(await summarizer.requests.isEmpty)
}

@Test func overTrimsOldToolResultsWithoutSummarizing() async throws {
    let summarizer = ScriptedProvider([])
    let head: [Message] = [.user("q"), .assistant("", toolCalls: [call("c1")]), .tool(id: "c1", String(repeating: "x", count: 4000))]
    let out = try await compactor(summarizer).fit(head + tail())
    #expect(out.count == 13)
    #expect(out[2].role == .tool)
    #expect(out[2].toolCallId == "c1")
    #expect(out[2].text == "[trimmed]")
    #expect(Array(out[3...]) == tail())
    #expect(await summarizer.requests.isEmpty)
}

@Test func stillOverSummarizesOnceAndKeepsLastTenVerbatim() async throws {
    let summarizer = ScriptedProvider([reply("they met Boris")])
    let head: [Message] = [
        .user(String(repeating: "a", count: 1500)),
        .assistant("", toolCalls: [call("c1")]),
        .tool(id: "c1", "result"),
        .assistant(String(repeating: "b", count: 1500)),
    ]
    let out = try await compactor(summarizer).fit(head + tail())
    #expect(out.count == 11)
    #expect(out[0] == .user("Earlier in this conversation: they met Boris"))
    #expect(Array(out[1...]) == tail())

    let requests = await summarizer.requests
    #expect(requests.count == 1)
    #expect(requests[0].system == "Summarize this conversation for the assistant's own memory. Keep names, facts, decisions, promises and open questions. Be brief.")
    #expect(requests[0].tools.isEmpty)
    #expect(requests[0].messages.count == 1)
    #expect(requests[0].messages[0].role == .user)
    let rendered = requests[0].messages[0].text
    #expect(rendered.contains("tool: [trimmed]"))
    #expect(rendered.contains("called read({\"q\":1})"))
    #expect(rendered.hasPrefix("user: aaa"))
}

@Test func cutNeverOrphansAToolResult() async throws {
    let summarizer = ScriptedProvider([reply("S")])
    // 12 messages: the naive cut (index 2) would start the tail on a tool result.
    let messages: [Message] = [
        .user(String(repeating: "a", count: 3000)),
        .assistant("", toolCalls: [call("c1"), call("c2")]),
        .tool(id: "c1", "r1"),
        .tool(id: "c2", "r2"),
    ] + tail(8)
    let out = try await compactor(summarizer).fit(messages)
    #expect(out.count == 12)   // summary + messages[1...]
    #expect(out[1].role == .assistant)
    #expect(out[1].toolCalls.count == 2)
    #expect(out[2].text == "r1")
    #expect(out[3].text == "r2")
    #expect(await summarizer.requests.count == 1)
}

@Test func negativeKeepLastIsClampedToZero() async throws {
    let summarizer = ScriptedProvider([reply("S")])
    let messages: [Message] = [.user(String(repeating: "a", count: 3000)), .assistant("b")]
    let out = try await Compactor(contextWindow: 1000, keepLast: -3, summarizer: summarizer).fit(messages)
    #expect(out == [.user("Earlier in this conversation: S")])
}

@Test func summarizerErrorPropagates() async throws {
    let summarizer = ScriptedProvider([])   // exhausted: send throws
    let messages: [Message] = [.user(String(repeating: "a", count: 3000))] + tail()
    await #expect(throws: ScriptedProviderError.self) { try await compactor(summarizer).fit(messages) }
}
