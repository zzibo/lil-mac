import Foundation
import Testing
import LilMac
@testable import LilMacTools

/// Records requests and returns a canned response. Shared static state, so the suite is `.serialized`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer[..<n])
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session(status: Int = 200, body: String = "") -> URLSession {
        self.status = status
        self.body = body
        requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

private func json(_ data: Data) throws -> NSObject { try JSONSerialization.jsonObject(with: data) as! NSObject }

@Suite(.serialized) struct WebToolsTests {
    @Test func bothToolsNeedApproval() {
        #expect(HTTPGetTool().kind == .approval)
        #expect(WebSearchTool().kind == .approval)
        #expect(HTTPGetTool().name == "http_get")
        #expect(WebSearchTool().name == "web_search")
    }

    @Test func httpGetStripsTagsAndTrims() async throws {
        let html = "<html><head><style>p{x:y}</style><script>var a=1;</script></head><body><h1>Hello</h1>\n\n<p>big   world</p></body></html>"
        let session = StubProtocol.session(body: html)
        let out = try await HTTPGetTool(session: session).call(.init(url: "https://example.com/a"))
        #expect(out == "Hello big world")
        #expect(StubProtocol.requests[0].request.httpMethod == "GET")
        #expect(StubProtocol.requests[0].request.timeoutInterval == 20)

        let cut = try await HTTPGetTool(maxCharacters: 5, session: session).call(.init(url: "https://example.com/a"))
        #expect(cut == "Hello…")
    }

    @Test(arguments: [
        ("<script>a", 24_000), ("<a ", 70_000), ("<style>b", 25_000), ("<!-- x ", 30_000), ("<b>hi</b> ", 20_000),
    ])
    func httpGetStripsPathologicalInputInLinearTime(unit: String, repeats: Int) async throws {
        let session = StubProtocol.session(body: "Hi " + String(repeating: unit, count: repeats))
        let start = ContinuousClock.now
        let out = try await HTTPGetTool(session: session).call(.init(url: "https://example.com"))
        #expect(ContinuousClock.now - start < .seconds(5))   // the old regex stripper took > 40 s here
        #expect(out.hasPrefix("Hi"))
        #expect(out.count <= 4001)
        #expect(!out.contains("<"))
    }

    @Test func httpGetDropsUnclosedScriptStyleAndComments() async throws {
        for body in ["ok<script>secret()", "ok<STYLE type=x>.secret{}", "ok<!-- secret", "ok<a href=secret"] {
            let out = try await HTTPGetTool(session: StubProtocol.session(body: body)).call(.init(url: "https://example.com"))
            #expect(out == "ok")
        }
        let closed = "a<!-- c -->b<SCRIPT>x</script >c<p>d"
        #expect(try await HTTPGetTool(session: StubProtocol.session(body: closed)).call(.init(url: "https://example.com")) == "a b c d")
        let lone = try await HTTPGetTool(session: StubProtocol.session(body: "1 < 2 and 3 > 2")).call(.init(url: "https://example.com"))
        #expect(lone == "1 < 2 and 3 > 2")
    }

    @Test func httpGetDecodesBasicEntitiesAfterStripping() async throws {
        let session = StubProtocol.session(body: "<p>Tom &amp; Jerry&nbsp;say &quot;hi&quot; &#39;x&#39; &lt;b&gt; &amp;lt;</p>")
        let out = try await HTTPGetTool(session: session).call(.init(url: "https://example.com"))
        #expect(out == #"Tom & Jerry say "hi" 'x' <b> &lt;"#)
    }

    @Test func webSearchEmptyTitleFallsBackToURL() async throws {
        let session = StubProtocol.session(body: #"{"results":[{"title":"","url":"https://a.com","text":"t"}]}"#)
        #expect(try await WebSearchTool(session: session).call(.init(query: "q", limit: nil)) == "https://a.com — https://a.com\nt")
    }

    @Test func httpGetRejectsNonHTTPAndReportsStatus() async throws {
        let session = StubProtocol.session()
        for url in ["file:///etc/passwd", "ftp://x.com/a", "not a url"] {
            let out = try await HTTPGetTool(session: session).call(.init(url: url))
            #expect(out == "Error: only http and https URLs.")
        }
        #expect(StubProtocol.requests.isEmpty)

        let failing = StubProtocol.session(status: 404, body: "nope")
        #expect(try await HTTPGetTool(session: failing).call(.init(url: "https://example.com")) == "Error: HTTP 404")
    }

    @Test func webSearchRequestShape() async throws {
        let session = StubProtocol.session(body: #"{"results":[]}"#)
        let tool = WebSearchTool(
            apiKey: "K", baseURL: URL(string: "https://proxy.example/exa/")!,
            headers: ["X-Extra": "1"], session: session)
        _ = try await tool.call(.init(query: "  swift  ", limit: 3))
        let sent = try #require(StubProtocol.requests.first)
        #expect(sent.request.url?.absoluteString == "https://proxy.example/exa/search")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == "K")
        #expect(sent.request.value(forHTTPHeaderField: "X-Extra") == "1")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try json(sent.body) == json(Data(
            #"{"query":"swift","numResults":3,"contents":{"text":{"maxCharacters":500}}}"#.utf8)))

        _ = try await WebSearchTool(session: session).call(.init(query: "q", limit: nil))
        #expect(StubProtocol.requests[1].request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(String(decoding: StubProtocol.requests[1].body, as: UTF8.self).contains(#""numResults":5"#))
    }

    @Test(arguments: [(0, 1), (-4, 1), (99, 10)])
    func webSearchClampsLimit(limit: Int, expected: Int) async throws {
        let session = StubProtocol.session(body: #"{"results":[]}"#)
        _ = try await WebSearchTool(session: session).call(.init(query: "q", limit: limit))
        #expect(String(decoding: StubProtocol.requests[0].body, as: UTF8.self).contains(#""numResults":\#(expected)"#))
    }

    @Test func webSearchRejectsBadQueriesWithoutRequest() async throws {
        let session = StubProtocol.session(body: #"{"results":[]}"#)
        let tool = WebSearchTool(session: session)
        #expect(try await tool.call(.init(query: "   ", limit: nil)) == "Error: query is empty.")
        #expect(try await tool.call(.init(query: String(repeating: "a", count: 201), limit: nil))
            == "Error: query is longer than 200 characters.")
        #expect(try await tool.call(.init(query: String(repeating: "a", count: 200), limit: nil)) == "No results.")
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func webSearchFormatsResults() async throws {
        let long = String(repeating: "x", count: 400)
        let session = StubProtocol.session(body: """
            {"results":[{"title":"One","url":"https://a.com","text":"first"},\
            {"title":"Two","url":"https://b.com","text":"\(long)"},\
            {"url":"https://c.com"}]}
            """)
        let out = try await WebSearchTool(session: session).call(.init(query: "q", limit: nil))
        #expect(out == "One — https://a.com\nfirst\n\nTwo — https://b.com\n\(String(repeating: "x", count: 300))\n\nhttps://c.com — https://c.com\n")
    }

    @Test func webSearchEmptyAndErrors() async throws {
        let empty = StubProtocol.session(body: #"{"results":[]}"#)
        #expect(try await WebSearchTool(session: empty).call(.init(query: "q", limit: nil)) == "No results.")
        let failing = StubProtocol.session(status: 500)
        #expect(try await WebSearchTool(session: failing).call(.init(query: "q", limit: nil)) == "Error: search failed (HTTP 500)")
    }
}
