import LilMac

enum ScriptedProviderError: Error { case exhausted }

/// Replays canned replies in order and records every request it receives.
actor ScriptedProvider: Provider {
    private var replies: [ModelReply]
    private(set) var requests: [ModelRequest] = []

    init(_ replies: [ModelReply]) { self.replies = replies }

    func send(_ request: ModelRequest) async throws -> ModelReply {
        requests.append(request)
        guard !replies.isEmpty else { throw ScriptedProviderError.exhausted }
        return replies.removeFirst()
    }
}
