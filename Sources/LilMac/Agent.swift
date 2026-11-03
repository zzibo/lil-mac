import Foundation

public enum AgentEvent: Sendable {
    case text(String)
    case toolStarted(ToolCall)
    case action(ToolCall)
    case toolResult(ToolCall, String)
    case checkpoint([Message])
    case done(Usage)
    case budgetExhausted(Usage)
}

public struct Agent: Sendable {
    private typealias Out = AsyncThrowingStream<AgentEvent, Error>.Continuation

    let provider: any Provider
    let system: String
    let toolset: Toolset
    let memory: (any MemoryStore)?
    let compactor: Compactor?
    let budget: Int
    let approve: @Sendable (ToolCall) async -> Bool

    public init(
        provider: any Provider, system: String, toolset: Toolset,
        memory: (any MemoryStore)? = nil, compactor: Compactor? = nil,
        budget: Int = 10,
        approve: @escaping @Sendable (ToolCall) async -> Bool = { _ in false }
    ) {
        self.provider = provider
        self.system = system
        self.toolset = toolset
        self.memory = memory
        self.compactor = compactor
        self.budget = budget
        self.approve = approve
    }

    public func run(_ messages: [Message]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { out in
            let task = Task {
                do {
                    try await loop(messages, out)
                    out.finish()
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    private func loop(_ input: [Message], _ out: Out) async throws {
        var messages = input
        var usage = Usage.zero
        let snapshot = await memory?.snapshot() ?? ""
        var step = 0
        while step < budget {
            try Task.checkCancellation()
            messages = try await compactor?.fit(messages) ?? messages
            let reply = try await provider.send(
                ModelRequest(system: system, messages: withMemory(snapshot, messages), tools: toolset.specs))
            step += 1
            usage.input += reply.usage.input
            usage.output += reply.usage.output
            usage.cacheRead += reply.usage.cacheRead
            usage.cacheWrite += reply.usage.cacheWrite
            usage.model = reply.usage.model
            var assistant = reply.message
            assistant.toolCalls = reply.toolCalls
            messages.append(assistant)
            if !assistant.text.isEmpty { out.yield(.text(assistant.text)) }
            if reply.toolCalls.isEmpty {
                out.yield(.done(usage))
                await log(messages, usage)
                return
            }
            let results = await dispatch(reply.toolCalls, out)
            for (call, result) in zip(reply.toolCalls, results) { messages.append(.tool(id: call.id, result)) }
            out.yield(.checkpoint(messages))
        }
        out.yield(.budgetExhausted(usage))
        await log(messages, usage)
    }

    /// Memory rides on the first user message so `system` stays byte-identical for prompt caching.
    private func withMemory(_ snapshot: String, _ messages: [Message]) -> [Message] {
        guard !snapshot.isEmpty, let i = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        var copy = messages
        copy[i].text = "<memory>\n\(snapshot)\n</memory>\n\n" + copy[i].text
        return copy
    }

    private func log(_ messages: [Message], _ usage: Usage) async {
        try? await memory?.log(RunRecord(id: UUID().uuidString, date: .now, messages: messages, usage: usage))
    }

    /// Reads run concurrently; actions and approvals run one at a time in call order. Results keep call order.
    private func dispatch(_ calls: [ToolCall], _ out: Out) async -> [String] {
        await withTaskGroup(of: (Int, String).self) { group in
            var results = [String](repeating: "", count: calls.count)
            for (i, call) in calls.enumerated() {
                if toolset.tool(named: call.name)?.kind == .read {
                    group.addTask { (i, await execute(call, out)) }
                } else {
                    results[i] = await execute(call, out)
                }
            }
            for await (i, result) in group { results[i] = result }
            return results
        }
    }

    private func execute(_ call: ToolCall, _ out: Out) async -> String {
        let result: String
        if let tool = toolset.tool(named: call.name) {
            if tool.kind == .action {
                out.yield(.action(call))
                result = "Shown to the user; nothing happens until they act."
            } else if tool.kind == .approval, !(await approve(call)) {
                result = "The user declined."
            } else if Task.isCancelled {
                result = "Cancelled."   // never run a tool after the user stopped the run
            } else {
                out.yield(.toolStarted(call))
                do {
                    result = try await tool.call(json: call.argumentsJSON)
                } catch ToolError.badArguments(let message) {
                    result = "Error: invalid arguments: \(message)"
                } catch {
                    result = "Error: \(error)"
                }
            }
        } else {
            result = "Error: unknown tool \(call.name)"
        }
        out.yield(.toolResult(call, result))
        return result
    }
}
