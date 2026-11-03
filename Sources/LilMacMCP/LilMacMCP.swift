import Foundation
import LilMac
import MCP

/// An HTTP MCP server to connect to. `readTools` names tools that run without approval.
public struct MCPServer: Sendable {
    public var name: String
    public var url: URL
    public var headers: [String: String]
    public var readTools: Set<String>

    public init(name: String, url: URL, headers: [String: String] = [:], readTools: Set<String> = []) {
        self.name = name
        self.url = url
        self.headers = headers
        self.readTools = readTools
    }
}

/// Connects to each server, lists its tools and wraps them as `AnyTool`. The tools keep their client alive.
public func connect(
    _ servers: [MCPServer],
    configuration: URLSessionConfiguration = .default
) async throws -> [AnyTool] {
    var result: [AnyTool] = []
    for server in servers {
        let transport = HTTPClientTransport(
            endpoint: server.url,
            configuration: configuration,
            streaming: false,  // no server push: iOS suspends long-lived streams
            requestModifier: { request in
                var request = request
                for (field, value) in server.headers { request.setValue(value, forHTTPHeaderField: field) }
                return request
            }
        )
        let client = Client(name: "LilMac", version: "1")
        try await client.connect(transport: transport)
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {
                result.append(try wrap(tool, kind: server.readTools.contains(tool.name) ? .read : .approval, client: client))
            }
            cursor = page.nextCursor
        } while cursor != nil
    }
    return result
}

private func wrap(_ tool: MCP.Tool, kind: ToolKind, client: Client) throws -> AnyTool {
    let name = tool.name
    return AnyTool(
        spec: ToolSpec(name: name, description: tool.description ?? "", schema: .raw(try JSONValue(tool.inputSchema))),
        kind: kind
    ) { json in
        let args: [String: Value]
        do {
            args = try JSONDecoder().decode([String: Value].self, from: Data(json.utf8))
        } catch {
            throw ToolError.badArguments(String(describing: error))
        }
        let reply = try await client.callTool(name: name, arguments: args)
        let text = reply.content.map { content -> String in
            switch content {
            case .text(let text, _, _): text
            case .image: "[image]"
            case .audio: "[audio]"
            case .resource, .resourceLink: "[resource]"
            }
        }.joined(separator: "\n")
        return reply.isError == true ? "Error: \(text)" : text
    }
}
