import Foundation

/// Arbitrary JSON. Request bodies are built from it and encoded with `.sortedKeys` (see `postJSON`).
public enum JSONValue: Codable, Sendable, Equatable,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Any `Encodable` (such as `JSONSchema`) as a `JSONValue`.
    public init(_ value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// This object with one more key; any other case is returned unchanged.
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var o) = self else { return self }
        o[key] = value
        return .object(o)
    }

    var sortedJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}

/// POSTs `body` (sorted keys, so bytes are stable for prompt caching) and maps failures to `ProviderError`.
func postJSON(_ url: URL, headers: [String: String], body: JSONValue, session: URLSession) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    request.httpBody = try encoder.encode(body)
    do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        return data
    } catch let error as URLError where error.code == .timedOut {
        throw ProviderError.timeout
    }
}

func decodeReply<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw ProviderError.badResponse(String(describing: error)) }
}

/// Claude Messages API, direct or through a proxy.
public struct Anthropic: Provider {
    let url: URL
    let model: String
    let headers: [String: String]
    let maxTokens: Int
    let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!, model: String, apiKey: String? = nil,
        headers: [String: String] = [:], maxTokens: Int = 4096, session: URLSession = .shared
    ) {
        url = baseURL.appendingPathComponent("v1/messages")
        self.model = model
        self.maxTokens = maxTokens
        self.session = session
        var merged = ["anthropic-version": "2023-06-01"]
        if let apiKey { merged["x-api-key"] = apiKey }
        self.headers = merged.merging(headers) { _, new in new }
    }

    // Wire names are snake_case on purpose: no key strategy, so `input` objects keep their own keys.
    private struct Wire: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
            var id: String?
            var name: String?
            var input: JSONValue?
        }
        struct WireUsage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation_input_tokens: Int?
        }
        var model: String?
        var content: [Block]
        var usage: WireUsage?
    }

    public func send(_ request: ModelRequest) async throws -> ModelReply {
        // The API rejects empty content: turns with no blocks are dropped, and adjacent user turns
        // (tool results, or what an empty assistant turn leaves behind) become one message.
        var turns: [(role: String, content: [JSONValue])] = []
        func add(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if role == "user", turns.last?.role == "user" { turns[turns.count - 1].content += blocks }
            else { turns.append((role, blocks)) }
        }
        func text(_ text: String) -> [JSONValue] { text.isEmpty ? [] : [["type": "text", "text": .string(text)]] }
        for message in request.messages {
            switch message.role {
            case .system: continue
            case .user: add("user", text(message.text))
            case .assistant:
                add("assistant", text(message.text) + message.toolCalls.map { call in
                    var input = try? JSONDecoder().decode(JSONValue.self, from: Data(call.argumentsJSON.utf8))
                    if case .object? = input {} else { input = [:] }
                    return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": input!]
                })
            case .tool:
                add("user", [[
                    "type": "tool_result", "tool_use_id": .string(message.toolCallId ?? ""), "content": .string(message.text),
                ]])
            }
        }
        let cache: JSONValue = ["type": "ephemeral"]
        if let last = turns.indices.last, let block = turns[last].content.indices.last {
            turns[last].content[block] = turns[last].content[block].with("cache_control", cache)
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .integer(Int64(maxTokens)),
            "messages": .array(turns.map { ["role": .string($0.role), "content": .array($0.content)] }),
        ]
        if !request.system.isEmpty {
            body["system"] = [["type": "text", "text": .string(request.system), "cache_control": cache]]
        }
        if !request.tools.isEmpty {
            var tools = try request.tools.map { spec -> JSONValue in
                ["name": .string(spec.name), "description": .string(spec.description), "input_schema": try JSONValue(spec.schema)]
            }
            tools[tools.count - 1] = tools[tools.count - 1].with("cache_control", cache)
            body["tools"] = .array(tools)
        }

        let data = try await postJSON(url, headers: headers, body: .object(body), session: session)
        let wire = try decodeReply(Wire.self, from: data)
        let text = wire.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        let calls = wire.content.compactMap { block -> ToolCall? in
            guard block.type == "tool_use", let id = block.id, let name = block.name else { return nil }
            return ToolCall(id: id, name: name, argumentsJSON: (block.input ?? [:]).sortedJSONString)
        }
        let u = wire.usage
        return ModelReply(
            message: .assistant(text, toolCalls: calls), toolCalls: calls,
            usage: Usage(
                input: u?.input_tokens ?? 0, output: u?.output_tokens ?? 0,
                cacheRead: u?.cache_read_input_tokens ?? 0, cacheWrite: u?.cache_creation_input_tokens ?? 0,
                model: wire.model ?? model))
    }
}
