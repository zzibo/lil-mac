import Foundation

/// Standard JSON Schema. Key order is only stable under `JSONEncoder.OutputFormatting.sortedKeys`;
/// providers must set it so tool specs stay byte-identical for prompt caching.
public indirect enum JSONSchema: Sendable, Equatable, Encodable {
    case object([String: JSONSchema], required: [String])
    case string(description: String? = nil)
    case integer
    case number
    case boolean
    case array(JSONSchema)
    case enumeration([String])
    /// A schema supplied as-is (MCP tools), encoded unchanged.
    case raw(JSONValue)

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        if case .raw(let value) = self { return try value.encode(to: encoder) }
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .object(let properties, let required):
            try c.encode("object", forKey: Key("type"))
            var props = c.nestedContainer(keyedBy: Key.self, forKey: Key("properties"))
            for (name, schema) in properties { try props.encode(schema, forKey: Key(name)) }
            try c.encode(required, forKey: Key("required"))
        case .string(let description):
            try c.encode("string", forKey: Key("type"))
            try c.encodeIfPresent(description, forKey: Key("description"))
        case .integer: try c.encode("integer", forKey: Key("type"))
        case .number: try c.encode("number", forKey: Key("type"))
        case .boolean: try c.encode("boolean", forKey: Key("type"))
        case .array(let items):
            try c.encode("array", forKey: Key("type"))
            try c.encode(items, forKey: Key("items"))
        case .enumeration(let values):
            try c.encode("string", forKey: Key("type"))
            try c.encode(values, forKey: Key("enum"))
        case .raw: break  // handled above
        }
    }
}

public enum ToolKind: String, Codable, Sendable { case read, action, approval }

public enum ToolError: Error, Equatable {
    case badArguments(String)
    case unknownTool(String)
}

public protocol Tool: Sendable {
    associatedtype Args: Codable & Sendable
    var name: String { get }
    var description: String { get }
    var schema: JSONSchema { get }
    var kind: ToolKind { get }
    func call(_ args: Args) async throws -> String
}

/// What goes to a provider.
public struct ToolSpec: Sendable, Equatable, Encodable {
    public var name: String
    public var description: String
    public var schema: JSONSchema

    public init(name: String, description: String, schema: JSONSchema) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

public struct AnyTool: Sendable {
    public let spec: ToolSpec
    public let kind: ToolKind
    private let run: @Sendable (String) async throws -> String

    /// For tools defined at runtime (MCP, eval fixtures).
    public init(spec: ToolSpec, kind: ToolKind, call: @escaping @Sendable (String) async throws -> String) {
        self.spec = spec
        self.kind = kind
        self.run = call
    }

    public init<T: Tool>(_ tool: T) {
        self.init(
            spec: ToolSpec(name: tool.name, description: tool.description, schema: tool.schema),
            kind: tool.kind
        ) { json in
            let args: T.Args
            do {
                args = try JSONDecoder().decode(T.Args.self, from: Data(json.utf8))
            } catch {
                throw ToolError.badArguments(String(describing: error))
            }
            return try await tool.call(args)
        }
    }

    public func call(json: String) async throws -> String { try await run(json) }
}

public struct Toolset: Sendable {
    public var name: String
    public var tools: [AnyTool]

    public init(name: String, tools: [AnyTool]) {
        self.name = name
        self.tools = tools
    }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public func tool(named name: String) -> AnyTool? { tools.first { $0.spec.name == name } }
}
