import Foundation
import Testing
@testable import LilMac
@testable import LilMacMCP

/// Answers MCP JSON-RPC over HTTP without a network. Stateless: the reply depends only on the request.
final class StubMCP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.body(of: request)
        let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let params = message["params"] as? [String: Any] ?? [:]
        var result: [String: Any]?
        switch message["method"] as? String {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] ?? "2025-03-26",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "stub", "version": "1"],
            ]
        case "tools/list":
            result = ["tools": [
                [
                    "name": "echo", "description": "Echo text",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["text": ["type": "string", "description": "what to echo"]],
                        "required": ["text"],
                    ],
                ],
                ["name": "boom", "description": "Always fails", "inputSchema": ["type": "object"]],
                ["name": "pic", "description": "Text and image", "inputSchema": ["type": "object"]],
                [
                    "name": "rich", "description": "Exotic schema",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["n": [
                            "anyOf": [["type": "integer"], ["type": "null"]],
                            "enum": [1, 2, 3], "minimum": 1, "maximum": 3, "default": 2,
                        ]],
                    ],
                ],
            ]]
        case "tools/call":
            let args = params["arguments"] as? [String: Any] ?? [:]
            let echoed = "\(request.value(forHTTPHeaderField: "X-Test") ?? "")\(args["text"] as? String ?? "")"
            switch params["name"] as? String {
            case "boom": result = ["content": [["type": "text", "text": "nope"]], "isError": true]
            case "pic":
                result = ["content": [
                    ["type": "text", "text": "a"],
                    ["type": "image", "data": "AAAA", "mimeType": "image/png"],
                ]]
            default: result = ["content": [["type": "text", "text": echoed]]]
            }
        default: break  // notifications/initialized has no id and gets 202
        }
        let status = result == nil ? 202 : 200
        var data = Data()
        if let result, let id = message["id"] {
            data = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private func connectStub(readTools: Set<String> = [], headers: [String: String] = [:]) async throws -> [AnyTool] {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubMCP.self]
    let server = MCPServer(name: "stub", url: URL(string: "http://stub.test/mcp")!, headers: headers, readTools: readTools)
    return try await connect([server], configuration: configuration)
}

@Suite struct MCPTests {
    @Test func listsToolsWithSpec() async throws {
        let tools = try await connectStub()
        #expect(tools.map(\.spec.name) == ["echo", "boom", "pic", "rich"])
        #expect(tools[0].spec == ToolSpec(
            name: "echo", description: "Echo text",
            schema: .raw([
                "type": "object",
                "properties": ["text": ["type": "string", "description": "what to echo"]],
                "required": ["text"],
            ])))
    }

    @Test func schemaPassesThroughUnchanged() async throws {
        let rich = try await connectStub()[3]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let expected = #"{"properties":{"n":{"anyOf":[{"type":"integer"},{"type":"null"}],"default":2,"enum":[1,2,3],"maximum":3,"minimum":1}},"type":"object"}"#
        #expect(String(decoding: try encoder.encode(rich.spec.schema), as: UTF8.self) == expected)
        // Providers embed the schema through JSONValue (Anthropic input_schema, OpenAI function.parameters).
        #expect(try JSONValue(rich.spec.schema) == JSONDecoder().decode(JSONValue.self, from: Data(expected.utf8)))
    }

    @Test func kindIsApprovalUnlessRead() async throws {
        let tools = try await connectStub(readTools: ["echo"])
        #expect(tools.map(\.kind) == [.read, .approval, .approval, .approval])
    }

    @Test func callReturnsEchoedText() async throws {
        let echo = try await connectStub(headers: ["X-Test": "h:"])[0]
        #expect(try await echo.call(json: #"{"text":"hi"}"#) == "h:hi")
    }

    @Test func errorResultIsPrefixed() async throws {
        let boom = try await connectStub()[1]
        #expect(try await boom.call(json: "{}") == "Error: nope")
    }

    @Test func nonTextContentIsPlaceholder() async throws {
        let pic = try await connectStub()[2]
        #expect(try await pic.call(json: "{}") == "a\n[image]")
    }

    @Test func badJSONThrowsBadArguments() async throws {
        let echo = try await connectStub()[0]
        for json in ["{nope", "[1]"] {
            await #expect {
                try await echo.call(json: json)
            } throws: { error in
                if case ToolError.badArguments = error { return true }
                return false
            }
        }
    }
}
