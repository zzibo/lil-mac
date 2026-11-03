import Foundation

/// Chat Completions wire format: OpenRouter (default), Groq, Gemini's OpenAI endpoint, or an app's key proxy.
public struct OpenAICompatible: Provider {
    public static let openRouter = URL(string: "https://openrouter.ai/api/v1")!

    let url: URL
    let model: String
    let headers: [String: String]
    let cacheControl: Bool
    let maxTokens: Int?
    let session: URLSession

    public init(
        baseURL: URL = OpenAICompatible.openRouter, model: String, apiKey: String? = nil,
        headers: [String: String] = [:], cacheControl: Bool = false,
        maxTokens: Int? = nil, session: URLSession = .shared
    ) {
        url = baseURL.appendingPathComponent("chat/completions")
        self.model = model
        self.cacheControl = cacheControl
        self.maxTokens = maxTokens
        self.session = session
        var merged: [String: String] = [:]
        if let apiKey { merged["Authorization"] = "Bearer \(apiKey)" }
        self.headers = merged.merging(headers) { _, new in new }
    }

    // Wire names are snake_case on purpose; they match the JSON keys with no mapping code.
    private struct Wire: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable {
                struct Call: Decodable {
                    struct Fn: Decodable { var name: String; var arguments: String }
                    var id: String?
                    var function: Fn
                }
                var content: String?
                var tool_calls: [Call]?
            }
            var message: Msg
        }
        struct WireUsage: Decodable {
            struct Details: Decodable { var cached_tokens: Int? }
            var prompt_tokens: Int?
            var completion_tokens: Int?
            var prompt_tokens_details: Details?
        }
        var model: String?
        var choices: [Choice]
        var usage: WireUsage?
    }

    public func send(_ request: ModelRequest) async throws -> ModelReply {
        let mark: JSONValue = ["type": "ephemeral"]
        func content(_ text: String, cached: Bool) -> JSONValue {
            cached ? [["type": "text", "text": .string(text), "cache_control": mark]] : .string(text)
        }
        let last = request.messages.count - 1
        var messages: [JSONValue] = [["role": "system", "content": content(request.system, cached: cacheControl)]]
        for (i, m) in request.messages.enumerated() {
            let cached = cacheControl && i == last
            switch m.role {
            case .system, .user:
                messages.append(["role": .string(m.role.rawValue), "content": content(m.text, cached: cached)])
            case .assistant:
                var message: JSONValue = [
                    "role": "assistant", "content": m.text.isEmpty ? .null : content(m.text, cached: cached),
                ]
                if !m.toolCalls.isEmpty {
                    message = message.with("tool_calls", .array(m.toolCalls.map {
                        ["id": .string($0.id), "type": "function",
                         "function": ["name": .string($0.name), "arguments": .string($0.argumentsJSON)]]
                    }))
                }
                messages.append(message)
            case .tool:
                messages.append([
                    "role": "tool", "tool_call_id": .string(m.toolCallId ?? ""), "content": content(m.text, cached: cached),
                ])
            }
        }

        var body: [String: JSONValue] = ["model": .string(model), "messages": .array(messages)]
        if let maxTokens { body["max_tokens"] = .integer(Int64(maxTokens)) }
        if !request.tools.isEmpty {
            body["tools"] = .array(try request.tools.map { spec in
                ["type": "function", "function": [
                    "name": .string(spec.name), "description": .string(spec.description),
                    "parameters": try JSONValue(spec.schema),
                ]]
            })
        }

        let data = try await postJSON(url, headers: headers, body: .object(body), session: session)
        let wire = try decodeReply(Wire.self, from: data)
        guard let message = wire.choices.first?.message else { throw ProviderError.badResponse("no choices") }
        let calls = (message.tool_calls ?? []).enumerated().map { i, call in
            // Some compatible servers omit the id; the loop needs one to pair the tool result.
            ToolCall(
                id: call.id.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(i)",
                name: call.function.name, argumentsJSON: call.function.arguments)
        }
        let u = wire.usage
        return ModelReply(
            message: .assistant(message.content ?? "", toolCalls: calls), toolCalls: calls,
            usage: Usage(
                input: u?.prompt_tokens ?? 0, output: u?.completion_tokens ?? 0,
                cacheRead: u?.prompt_tokens_details?.cached_tokens ?? 0, model: wire.model ?? model))
    }
}
