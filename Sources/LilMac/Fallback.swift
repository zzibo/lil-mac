import Foundation

/// Tries providers in order. Rate limits, 5xx and timeouts move on to the next provider; any other error stops.
public struct Fallback: Provider {
    private let providers: [any Provider]

    public init(_ providers: [any Provider]) { self.providers = providers }

    public func send(_ request: ModelRequest) async throws -> ModelReply {
        var last: any Error = ProviderError.unsupported("no providers")
        for provider in providers {
            do { return try await provider.send(request) }
            catch where Self.isTransient(error) { last = error }
        }
        throw last
    }

    private static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case ProviderError.http(let code): code == 429 || (500...599).contains(code)
        case ProviderError.timeout: true
        case let error as URLError: error.code == .timedOut
        default: false
        }
    }
}
