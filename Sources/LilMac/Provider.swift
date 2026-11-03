public struct Usage: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var model: String

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, model: String = "") {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.model = model
    }

    public static let zero = Usage()
}

public struct ModelRequest: Sendable, Equatable {
    public var system: String
    public var messages: [Message]
    public var tools: [ToolSpec]

    public init(system: String, messages: [Message], tools: [ToolSpec]) {
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

public struct ModelReply: Codable, Sendable, Equatable {
    public var message: Message
    public var toolCalls: [ToolCall]
    public var usage: Usage

    public init(message: Message, toolCalls: [ToolCall], usage: Usage) {
        self.message = message
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

public enum ProviderError: Error, Equatable {
    case http(Int)
    case timeout
    case unsupported(String)
    case badResponse(String)
}

public protocol Provider: Sendable {
    func send(_ request: ModelRequest) async throws -> ModelReply
}
