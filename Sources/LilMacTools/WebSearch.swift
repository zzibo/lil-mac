import Foundation
import LilMac

public struct WebSearchTool: Tool {
    public struct Args: Codable, Sendable {
        public var query: String
        public var limit: Int?
        public init(query: String, limit: Int? = nil) {
            self.query = query
            self.limit = limit
        }
    }

    public let name = "web_search"
    public let description = "Search the web. Returns titles, URLs, and short excerpts."
    public let schema = JSONSchema.object(
        [
            "query": .string(description: "Search query, at most 200 characters."),
            "limit": .integer,
        ], required: ["query"])
    public let kind = ToolKind.approval

    private let apiKey: String?
    private let baseURL: URL
    private let headers: [String: String]
    private let session: URLSession

    public init(
        apiKey: String? = nil, baseURL: URL = URL(string: "https://api.exa.ai")!,
        headers: [String: String] = [:], session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.headers = headers
        self.session = session
    }

    private struct Body: Encodable {
        struct Contents: Encodable { var text = Text(); struct Text: Encodable { var maxCharacters = 500 } }
        var query: String
        var numResults: Int
        var contents = Contents()
    }

    private struct Reply: Decodable {
        struct Hit: Decodable { var title: String?; var url: String; var text: String? }
        var results: [Hit]
    }

    public func call(_ args: Args) async throws -> String {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return "Error: query is empty." }
        if query.count > 200 { return "Error: query is longer than 200 characters." }

        var request = URLRequest(url: baseURL.appendingPathComponent("search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(Body(query: query, numResults: min(max(args.limit ?? 5, 1), 10)))

        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            return "Error: search failed (HTTP \(status))"
        }
        let hits = try JSONDecoder().decode(Reply.self, from: data).results
        if hits.isEmpty { return "No results." }
        return hits
            .map { "\($0.title.flatMap { $0.isEmpty ? nil : $0 } ?? $0.url) — \($0.url)\n\(String(($0.text ?? "").prefix(300)))" }
            .joined(separator: "\n\n")
    }
}
