import Foundation
import LilMac
import UIKit

/// A model with no network, deterministic from the request. Tools pick the script:
/// `notify` is a heartbeat, `lookup` is chat, none is a brief. "slow" and "very slow" in the user's text delay the final reply.
struct FakeProvider: Provider {
    func send(_ request: ModelRequest) async throws -> ModelReply {
        let names = request.tools.map(\.name)
        let kind = names.contains("notify") ? "heartbeat" : names.contains("lookup") ? "chat" : "brief"
        let state = await MainActor.run { UIApplication.shared.applicationState }
        let app = state == .active ? "active" : state == .inactive ? "inactive" : "background"
        DeviceLog.write("fake send kind=\(kind) app=\(app)")

        let user = request.messages.last { $0.role == .user }?.text ?? ""
        let fresh = request.messages.last?.role == .user
        switch kind {
        case "heartbeat" where fresh:
            let at = Date(timeIntervalSinceNow: 120).formatted(.iso8601)
            return reply("", [try call("fake-notify", "notify", ["text": "Fake heartbeat noticed a change", "at": at])])
        case "heartbeat": return try await final("HOLD", user)
        case "chat" where fresh:
            return reply("", [try call("fake-lookup", "lookup", ["topic": user]), try call("fake-note", "save_note", ["title": user])])
        case "chat":
            let lookup = request.messages.last { !$0.toolCalls.isEmpty }?.toolCalls.first { $0.name == "lookup" }
            let result = request.messages.last { $0.toolCallId == lookup?.id }?.text ?? ""
            return try await final("Fake agent. Looked up: \(result)", user)
        default:
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss"
            return try await final("Fake brief at \(clock.string(from: .now))", user)
        }
    }

    private func call(_ id: String, _ name: String, _ arguments: [String: String]) throws -> ToolCall {
        ToolCall(id: id, name: name, argumentsJSON: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))
    }

    private func reply(_ text: String, _ calls: [ToolCall]) -> ModelReply {
        ModelReply(message: .assistant(text), toolCalls: calls, usage: Usage(model: "fake"))
    }

    /// `Task.sleep` throws on cancel, so a cancelled run stops here.
    private func final(_ text: String, _ user: String) async throws -> ModelReply {
        let lower = user.lowercased()
        try await Task.sleep(for: .seconds(lower.contains("very slow") ? 90 : lower.contains("slow") ? 20 : 0.2))
        return reply(text, [])
    }
}
