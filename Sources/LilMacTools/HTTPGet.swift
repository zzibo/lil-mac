import Foundation
import LilMac

public struct HTTPGetTool: Tool {
    public struct Args: Codable, Sendable {
        public var url: String
        public init(url: String) { self.url = url }
    }

    public let name = "http_get"
    public let description = "Fetch a web page over HTTP(S) and return its text with HTML tags removed."
    public let schema = JSONSchema.object(
        ["url": .string(description: "An http or https URL.")], required: ["url"])
    public let kind = ToolKind.approval

    private let maxCharacters: Int
    private let session: URLSession

    public init(maxCharacters: Int = 4000, session: URLSession = .shared) {
        self.maxCharacters = maxCharacters
        self.session = session
    }

    public func call(_ args: Args) async throws -> String {
        guard let url = URL(string: args.url), url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return "Error: only http and https URLs." }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            return "Error: HTTP \(status)"
        }
        let text = Self.stripTags(data)
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "…" : text
    }

    /// One linear pass over at most 512 KB. Drops tags, comments, and `<script>`/`<style>` bodies
    /// (to the end of input when unclosed), then decodes a few entities and collapses whitespace.
    /// ponytail: not an HTML parser; swap for one if output quality matters.
    static func stripTags(_ data: Data) -> String {
        let b = [UInt8](data.prefix(512 * 1024))
        let lower = { (c: UInt8) in (65...90).contains(c) ? c + 32 : c }
        func has(_ s: String, at i: Int) -> Bool {
            let n = Array(s.utf8)
            return i + n.count <= b.count && zip(n, b[i...]).allSatisfy { $0 == lower($1) }
        }
        func find(_ s: String, from: Int) -> Int? {
            let size = s.utf8.count
            return from + size > b.count ? nil : (from...(b.count - size)).first { has(s, at: $0) }
        }
        func afterGT(_ from: Int) -> Int { b[from...].firstIndex(of: 0x3E).map { $0 + 1 } ?? b.count }
        func isLetter(_ i: Int) -> Bool { i < b.count && (97...122).contains(lower(b[i])) }

        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            guard b[i] == 0x3C else { out.append(b[i]); i += 1; continue }
            if has("<!--", at: i) {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? b.count
            } else if let tag = ["script", "style"].first(where: { has("<" + $0, at: i) && !isLetter(i + 1 + $0.utf8.count) }) {
                i = find("</" + tag, from: i).map(afterGT) ?? b.count
            } else if isLetter(i + 1) || (i + 1 < b.count && [0x2F, 0x21, 0x3F].contains(b[i + 1])) {
                i = afterGT(i)
            } else {
                out.append(b[i]); i += 1; continue
            }
            out.append(0x20)
        }
        return String(decoding: out, as: UTF8.self)
            .replacing("&nbsp;", with: " ").replacing("&lt;", with: "<").replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"").replacing("&#39;", with: "'").replacing("&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
