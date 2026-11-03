import Foundation
import Testing
@testable import LilMac

/// Records requests and returns a canned response. Shared static state, so the suite is `.serialized`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var error: URLError?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer[..<n])
            }
            stream.close()
        }
        Self.requests.append((request, body))
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session(status: Int = 200, body: String = "{}", error: URLError? = nil) -> URLSession {
        self.status = status
        self.body = body
        self.error = error
        requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

private func parse(_ data: Data) throws -> NSObject { try JSONSerialization.jsonObject(with: data) as! NSObject }
private func parse(_ json: String) throws -> NSObject { try parse(Data(json.utf8)) }

private let getSpec = ToolSpec(
    name: "get", description: "Get it",
    schema: .object(["b": .integer, "a": .string()], required: ["a"]))
private let putSpec = ToolSpec(name: "put", description: "Put it", schema: .object([:], required: []))
private let cacheMark = #"{"type":"ephemeral"}"#

@Suite(.serialized) struct ProviderTests {
    @Test func openAIRequestShape() async throws {
        let session = StubProtocol.session()
        let provider = OpenAICompatible(
            model: "m", apiKey: "K", headers: ["X-Title": "Lil"], session: session)
        let request = ModelRequest(
            system: "sys",
            messages: [
                .user("hi"),
                .assistant("", toolCalls: [ToolCall(id: "c1", name: "get", argumentsJSON: #"{"a":"x"}"#)]),
                .tool(id: "c1", "r1"),
            ],
            tools: [getSpec])
        _ = try? await provider.send(request)
        _ = try? await provider.send(request)

        let sent = StubProtocol.requests
        #expect(sent.count == 2)
        #expect(sent[0].request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(sent[0].request.httpMethod == "POST")
        #expect(sent[0].request.timeoutInterval == 60)
        #expect(sent[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer K")
        #expect(sent[0].request.value(forHTTPHeaderField: "X-Title") == "Lil")
        #expect(try parse(sent[0].body) == parse(#"""
            {"model":"m","messages":[{"role":"system","content":"sys"},{"role":"user","content":"hi"},\#
            {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get","arguments":"{\"a\":\"x\"}"}}]},\#
            {"role":"tool","tool_call_id":"c1","content":"r1"}],\#
            "tools":[{"type":"function","function":{"name":"get","description":"Get it","parameters":{"properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"],"type":"object"}}}]}
            """#))
        #expect(sent[0].body == sent[1].body)
    }

    @Test func openAIReplyMapsToolCallsAndUsage() async throws {
        let session = StubProtocol.session(body: #"""
            {"model":"gpt-x","choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get","arguments":"{\"a\":1}"}}]}}],\#
            "usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":4}}}
            """#)
        let reply = try await OpenAICompatible(model: "m", session: session)
            .send(ModelRequest(system: "s", messages: [.user("hi")], tools: []))
        let call = ToolCall(id: "c1", name: "get", argumentsJSON: #"{"a":1}"#)
        #expect(reply == ModelReply(
            message: .assistant("", toolCalls: [call]), toolCalls: [call],
            usage: Usage(input: 10, output: 5, cacheRead: 4, cacheWrite: 0, model: "gpt-x")))
        #expect(StubProtocol.requests[0].request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func openAICacheControlMarksSystemAndLastMessage() async throws {
        let session = StubProtocol.session()
        let provider = OpenAICompatible(model: "m", cacheControl: true, maxTokens: 100, session: session)
        _ = try? await provider.send(ModelRequest(system: "sys", messages: [.user("hi")], tools: []))
        #expect(try parse(StubProtocol.requests[0].body) == parse("""
            {"model":"m","max_tokens":100,"messages":[\
            {"role":"system","content":[{"type":"text","text":"sys","cache_control":\(cacheMark)}]},\
            {"role":"user","content":[{"type":"text","text":"hi","cache_control":\(cacheMark)}]}]}
            """))
    }

    @Test func anthropicRequestShape() async throws {
        let session = StubProtocol.session()
        let provider = Anthropic(model: "m", apiKey: "K", headers: ["X-Extra": "1"], session: session)
        _ = try? await provider.send(ModelRequest(
            system: "sys",
            messages: [
                .user("hi"),
                .assistant("ok", toolCalls: [
                    ToolCall(id: "c1", name: "get", argumentsJSON: #"{"a":"x"}"#),
                    ToolCall(id: "c2", name: "put", argumentsJSON: "not json"),
                ]),
                .tool(id: "c1", "r1"),
                .tool(id: "c2", "r2"),
            ],
            tools: [getSpec, putSpec]))

        let sent = try #require(StubProtocol.requests.first)
        #expect(sent.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.request.timeoutInterval == 60)
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == "K")
        #expect(sent.request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(sent.request.value(forHTTPHeaderField: "X-Extra") == "1")
        #expect(try parse(sent.body) == parse("""
            {"model":"m","max_tokens":4096,\
            "system":[{"type":"text","text":"sys","cache_control":\(cacheMark)}],\
            "tools":[{"name":"get","description":"Get it","input_schema":{"properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a"],"type":"object"}},\
            {"name":"put","description":"Put it","input_schema":{"properties":{},"required":[],"type":"object"},"cache_control":\(cacheMark)}],\
            "messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},\
            {"role":"assistant","content":[{"type":"text","text":"ok"},\
            {"type":"tool_use","id":"c1","name":"get","input":{"a":"x"}},\
            {"type":"tool_use","id":"c2","name":"put","input":{}}]},\
            {"role":"user","content":[{"type":"tool_result","tool_use_id":"c1","content":"r1"},\
            {"type":"tool_result","tool_use_id":"c2","content":"r2","cache_control":\(cacheMark)}]}]}
            """))
    }

    @Test func anthropicBodyIsByteStable() async throws {
        let session = StubProtocol.session()
        let request = ModelRequest(system: "s", messages: [.user("hi")], tools: [getSpec])
        _ = try? await Anthropic(model: "m", session: session).send(request)
        _ = try? await Anthropic(model: "m", session: session).send(request)
        #expect(StubProtocol.requests[0].body == StubProtocol.requests[1].body)
    }

    @Test func anthropicReplyMapsToolUseAndUsage() async throws {
        let session = StubProtocol.session(body: """
            {"model":"claude-x","content":[{"type":"text","text":"hello"},\
            {"type":"tool_use","id":"t1","name":"get","input":{"z":1,"a":"x"}}],\
            "usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}
            """)
        let reply = try await Anthropic(model: "m", session: session)
            .send(ModelRequest(system: "s", messages: [.user("hi")], tools: []))
        let call = ToolCall(id: "t1", name: "get", argumentsJSON: #"{"a":"x","z":1}"#)
        #expect(reply == ModelReply(
            message: .assistant("hello", toolCalls: [call]), toolCalls: [call],
            usage: Usage(input: 7, output: 3, cacheRead: 2, cacheWrite: 1, model: "claude-x")))
    }

    @Test func anthropicNeverSendsEmptyContent() async throws {
        let session = StubProtocol.session()
        let provider = Anthropic(model: "m", session: session)
        _ = try? await provider.send(ModelRequest(
            system: "", messages: [.user("u"), .assistant(""), .user("n")], tools: []))
        #expect(try parse(StubProtocol.requests[0].body) == parse("""
            {"model":"m","max_tokens":4096,"messages":[{"role":"user","content":[\
            {"type":"text","text":"u"},{"type":"text","text":"n","cache_control":\(cacheMark)}]}]}
            """))

        _ = try? await provider.send(ModelRequest(
            system: "s", messages: [.user(""), .assistant("a"), .user("")], tools: []))
        #expect(try parse(StubProtocol.requests[1].body) == parse("""
            {"model":"m","max_tokens":4096,"system":[{"type":"text","text":"s","cache_control":\(cacheMark)}],\
            "messages":[{"role":"assistant","content":[{"type":"text","text":"a","cache_control":\(cacheMark)}]}]}
            """))
    }

    @Test func anthropicKeepsLargeIntegersExact() async throws {
        let big = "1234567890123456789"
        let session = StubProtocol.session(body: """
            {"model":"c","content":[{"type":"tool_use","id":"t1","name":"get","input":{"n":\(big),"f":1.5}}]}
            """)
        let provider = Anthropic(model: "m", session: session)
        let reply = try await provider.send(ModelRequest(
            system: "s",
            messages: [.assistant("", toolCalls: [ToolCall(id: "c", name: "get", argumentsJSON: #"{"n":\#(big)}"#)])],
            tools: []))
        #expect(reply.toolCalls[0].argumentsJSON == #"{"f":1.5,"n":\#(big)}"#)
        #expect(String(decoding: StubProtocol.requests[0].body, as: UTF8.self).contains(#""input":{"n":\#(big)}"#))
    }

    @Test func openAIToolCallWithoutIdGetsIndexedId() async throws {
        let session = StubProtocol.session(body: #"""
            {"model":"g","choices":[{"message":{"content":"","tool_calls":[\#
            {"type":"function","function":{"name":"a","arguments":"{}"}},\#
            {"id":"","type":"function","function":{"name":"b","arguments":"{}"}},\#
            {"id":"keep","type":"function","function":{"name":"c","arguments":"{}"}}]}}]}
            """#)
        let reply = try await OpenAICompatible(model: "m", session: session)
            .send(ModelRequest(system: "s", messages: [.user("hi")], tools: []))
        #expect(reply.toolCalls.map(\.id) == ["call_0", "call_1", "keep"])
    }

    @Test(arguments: [(429, ProviderError.http(429)), (401, .http(401)), (503, .http(503))])
    func httpErrorMapsToProviderError(status: Int, expected: ProviderError) async throws {
        let request = ModelRequest(system: "s", messages: [.user("hi")], tools: [])
        let openAI = OpenAICompatible(model: "m", session: StubProtocol.session(status: status))
        await #expect(throws: expected) { try await openAI.send(request) }
        let anthropic = Anthropic(model: "m", session: StubProtocol.session(status: status))
        await #expect(throws: expected) { try await anthropic.send(request) }
    }

    @Test(arguments: ["https://proxy.example/api/v1", "https://proxy.example/api/v1/"])
    func baseURLTrailingSlashDoesNotMatter(base: String) async throws {
        let request = ModelRequest(system: "s", messages: [.user("hi")], tools: [])
        let url = URL(string: base)!
        _ = try? await OpenAICompatible(baseURL: url, model: "m", session: StubProtocol.session()).send(request)
        #expect(StubProtocol.requests[0].request.url?.absoluteString == "https://proxy.example/api/v1/chat/completions")
        _ = try? await Anthropic(baseURL: url, model: "m", session: StubProtocol.session()).send(request)
        #expect(StubProtocol.requests[0].request.url?.absoluteString == "https://proxy.example/api/v1/v1/messages")
    }

    @Test func timeoutMapsToProviderError() async throws {
        let request = ModelRequest(system: "s", messages: [.user("hi")], tools: [])
        let provider = OpenAICompatible(model: "m", session: StubProtocol.session(error: URLError(.timedOut)))
        await #expect(throws: ProviderError.timeout) { try await provider.send(request) }
    }

    @Test func undecodableBodyIsBadResponse() async throws {
        let provider = OpenAICompatible(model: "m", session: StubProtocol.session(body: "nope"))
        let request = ModelRequest(system: "s", messages: [.user("hi")], tools: [])
        do {
            _ = try await provider.send(request)
            Issue.record("expected throw")
        } catch ProviderError.badResponse {
        }
    }

    @Test func appleOnDeviceRejectsTools() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let request = ModelRequest(system: "s", messages: [.user("hi")], tools: [getSpec])
            await #expect(throws: ProviderError.unsupported("tools")) { try await AppleOnDevice().send(request) }
        }
        #endif
    }
}
