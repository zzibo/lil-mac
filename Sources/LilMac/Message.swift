public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct Message: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }

    public var role: Role
    public var text: String
    public var toolCalls: [ToolCall]
    public var toolCallId: String?

    public init(role: Role, text: String, toolCalls: [ToolCall] = [], toolCallId: String? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    public static func system(_ text: String) -> Message { .init(role: .system, text: text) }
    public static func user(_ text: String) -> Message { .init(role: .user, text: text) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> Message {
        .init(role: .assistant, text: text, toolCalls: toolCalls)
    }
    public static func tool(id: String, _ text: String) -> Message {
        .init(role: .tool, text: text, toolCallId: id)
    }
}
