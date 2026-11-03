/// Keeps a long transcript under `threshold` × `contextWindow` tokens (about 4 characters each).
/// First trims old tool results (free), then summarizes everything before the last `keepLast` messages.
public struct Compactor: Sendable {
    let limit: Int
    let keepLast: Int
    let summarizer: any Provider

    public init(contextWindow: Int, threshold: Double = 0.5, keepLast: Int = 10, summarizer: any Provider) {
        self.limit = Int(threshold * Double(contextWindow))
        self.keepLast = max(0, keepLast)
        self.summarizer = summarizer
    }

    /// A summarizer error propagates to the caller; nothing is retried or swallowed.
    public func fit(_ messages: [Message]) async throws -> [Message] {
        guard estimate(messages) > limit else { return messages }
        var cut = max(0, messages.count - keepLast)
        // A tool result must stay with the assistant message that called it.
        while cut > 0, cut < messages.count, messages[cut].role == .tool { cut -= 1 }
        guard cut > 0 else { return messages }

        let tail = Array(messages[cut...])
        let head = messages[..<cut].map { message in
            var message = message
            if message.role == .tool { message.text = "[trimmed]" }
            return message
        }
        if estimate(head + tail) <= limit { return head + tail }

        let transcript = head.map { message in
            ["\(message.role.rawValue): \(message.text)"]
                + message.toolCalls.map { "called \($0.name)(\($0.argumentsJSON))" }
        }.joined().joined(separator: "\n")
        let reply = try await summarizer.send(ModelRequest(
            system: "Summarize this conversation for the assistant's own memory. Keep names, facts, decisions, promises and open questions. Be brief.",
            messages: [.user(transcript)], tools: []))
        return [.user("Earlier in this conversation: \(reply.message.text)")] + tail
    }

    private func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + $1.text.count + $1.toolCalls.reduce(0) { $0 + $1.argumentsJSON.count } } / 4
    }
}
