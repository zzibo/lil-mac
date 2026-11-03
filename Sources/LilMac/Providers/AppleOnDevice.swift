#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model. Text only in v0.1: tools throw `ProviderError.unsupported("tools")`.
@available(iOS 26, macOS 26, *)
public struct AppleOnDevice: Provider {
    public init() {}

    public func send(_ request: ModelRequest) async throws -> ModelReply {
        guard request.tools.isEmpty else { throw ProviderError.unsupported("tools") }
        // The last user message is the prompt; earlier user and assistant turns go in front as plain lines.
        let end = request.messages.lastIndex { $0.role == .user } ?? request.messages.endIndex
        var lines = request.messages[..<end].compactMap { m -> String? in
            switch m.role {
            case .user: "User: \(m.text)"
            case .assistant: m.text.isEmpty ? nil : "Assistant: \(m.text)"
            case .system, .tool: nil
            }
        }
        if end < request.messages.endIndex { lines.append(request.messages[end].text) }
        let session = LanguageModelSession(instructions: request.system)
        let response = try await session.respond(to: lines.joined(separator: "\n"))
        return ModelReply(
            message: .assistant(response.content), toolCalls: [], usage: Usage(model: "apple-on-device"))
    }
}
#endif
