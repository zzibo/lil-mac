import Foundation
import Testing
@testable import LilMac

private func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Test func schemaEncodesToStandardJSONSchema() throws {
    let schema = JSONSchema.object(["q": .string()], required: ["q"])
    #expect(try encode(schema) == #"{"properties":{"q":{"type":"string"}},"required":["q"],"type":"object"}"#)
    #expect(try encode(schema) == encode(schema))
}

@Test func schemaEncodesEveryCase() throws {
    #expect(try encode(JSONSchema.string(description: "d")) == #"{"description":"d","type":"string"}"#)
    #expect(try encode(JSONSchema.integer) == #"{"type":"integer"}"#)
    #expect(try encode(JSONSchema.number) == #"{"type":"number"}"#)
    #expect(try encode(JSONSchema.boolean) == #"{"type":"boolean"}"#)
    #expect(try encode(JSONSchema.array(.integer)) == #"{"items":{"type":"integer"},"type":"array"}"#)
    #expect(try encode(JSONSchema.enumeration(["a", "b"])) == #"{"enum":["a","b"],"type":"string"}"#)
}

private struct Echo: Tool {
    struct Args: Codable, Sendable { var text: String }
    let name = "echo"
    let description = "Echoes text."
    let schema = JSONSchema.object(["text": .string()], required: ["text"])
    let kind = ToolKind.read
    func call(_ args: Args) async throws -> String { "echo: \(args.text)" }
}

@Test func anyToolRejectsBadJSON() async throws {
    let tool = AnyTool(Echo())
    await #expect(throws: ToolError.self) { try await tool.call(json: "not json") }
    await #expect(throws: ToolError.self) { try await tool.call(json: #"{"wrong":1}"#) }
}

@Test func anyToolCallsThrough() async throws {
    let tool = AnyTool(Echo())
    #expect(try await tool.call(json: #"{"text":"hi"}"#) == "echo: hi")
    #expect(tool.spec.name == "echo")
    #expect(tool.kind == .read)
}

@Test func anyToolFromClosureAndToolset() async throws {
    let spec = ToolSpec(name: "now", description: "Time.", schema: .object([:], required: []))
    let toolset = Toolset(name: "t", tools: [AnyTool(spec: spec, kind: .action) { _ in "noon" }, AnyTool(Echo())])
    #expect(toolset.specs.map(\.name) == ["now", "echo"])
    #expect(try await toolset.tool(named: "now")?.call(json: "{}") == "noon")
    #expect(toolset.tool(named: "nope") == nil)
}

@Test func messageAndReplyRoundTrip() throws {
    let call = ToolCall(id: "c1", name: "echo", argumentsJSON: #"{"text":"hi"}"#)
    let message = Message(role: .assistant, text: "ok", toolCalls: [call])
    let reply = ModelReply(
        message: message, toolCalls: [call],
        usage: Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, model: "m"))
    let decoder = JSONDecoder()
    #expect(try decoder.decode(Message.self, from: JSONEncoder().encode(message)) == message)
    #expect(try decoder.decode(ModelReply.self, from: JSONEncoder().encode(reply)) == reply)
    #expect(Message.tool(id: "c1", "r") == Message(role: .tool, text: "r", toolCallId: "c1"))
}

@Test func scriptedProviderReplaysInOrderAndRecords() async throws {
    func reply(_ text: String) -> ModelReply {
        ModelReply(message: .assistant(text), toolCalls: [], usage: .zero)
    }
    let provider = ScriptedProvider([reply("one"), reply("two")])
    let first = try await provider.send(ModelRequest(system: "s", messages: [.user("a")], tools: []))
    let second = try await provider.send(ModelRequest(system: "s", messages: [.user("b")], tools: []))
    #expect(first.message.text == "one")
    #expect(second.message.text == "two")
    #expect(await provider.requests.map { $0.messages.first?.text } == ["a", "b"])
    await #expect(throws: ScriptedProviderError.self) {
        try await provider.send(ModelRequest(system: "s", messages: [], tools: []))
    }
}
