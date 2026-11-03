import Foundation
import Testing
@testable import LilMac

private typealias Check = EvalCase.Check

private func call(_ name: String, _ args: String = "{}") -> ToolCall { ToolCall(id: UUID().uuidString, name: name, argumentsJSON: args) }

private func reply(_ text: String, calls: [ToolCall] = []) -> ModelReply {
    ModelReply(message: .assistant(text, toolCalls: calls), toolCalls: calls, usage: Usage(input: 10, output: 5))
}

private func evalCase(_ id: String, expect: EvalCase.Expect = .init(all: []), fixtures: [String: String]? = nil) -> EvalCase {
    EvalCase(id: id, messages: [.init(role: .user, text: "hi \(id)")], fixtures: fixtures, expect: expect)
}

private let searchDef = EvalToolDef(
    name: "web_search", description: "Search.", schema: ["type": "object"], kind: .read, live: nil)

private func tempFile(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Echoes the last user message back, so concurrent cases can be told apart; sleeps by case.
private struct Echo: Provider {
    func send(_ request: ModelRequest) async throws -> ModelReply {
        let text = request.messages.last?.text ?? ""
        if text.contains("slow") { try await Task.sleep(for: .milliseconds(150)) }
        return reply(text)
    }
}

private struct Boom: Provider {
    func send(_ request: ModelRequest) async throws -> ModelReply { throw ProviderError.http(500) }
}

@Suite struct EvalScoreTests {
    private func score(_ all: [Check] = [], any: [Check]? = nil, calls: [ToolCall] = [], text: String = "") -> [String] {
        Eval.score(.init(all: all, any: any), calls: calls, text: text)
    }

    @Test func callCheck() {
        #expect(score([Check(call: "find")], calls: [call("find")]).isEmpty)
        #expect(score([Check(call: "find")], calls: [call("other")]).count == 1)
    }

    @Test func noCallCheck() {
        #expect(score([Check(no_call: "remember")], calls: [call("find")]).isEmpty)
        #expect(score([Check(no_call: "remember")], calls: [call("remember")]).count == 1)
    }

    @Test func textChecks() {
        #expect(score([Check(text_has: "boris")], text: "Boris is here").isEmpty)
        #expect(score([Check(text_has: "zed")], text: "Boris").count == 1)
        #expect(score([Check(text_lacks: "sorry")], text: "Boris").isEmpty)
        #expect(score([Check(text_lacks: "SORRY")], text: "I'm sorry").count == 1)
    }

    @Test func argsAreCaseInsensitive() {
        #expect(score([Check(call: "find", args_has: "BORIS")], calls: [call("find", #"{"q":"boris"}"#)]).isEmpty)
        #expect(score([Check(call: "find", args_lacks: "BORIS")], calls: [call("find", #"{"q":"boris"}"#)]).count == 1)
    }

    @Test func matchingFollowsFoundationCaseFolding() {
        #expect(score([Check(text_has: "STRASSE")], text: "Straße").isEmpty)
        #expect(score([Check(text_has: "straße")], text: "STRASSE").isEmpty)
        #expect(score([Check(text_has: "istanbul")], text: "İSTANBUL").count == 1)  // lowercased() would match here
        #expect(score([Check(text_has: "")], text: "anything").isEmpty)
    }

    @Test func argsConditionsApplyToTheSameCall() {
        let check = Check(call: "find", args_has: "boris", args_lacks: "meta")
        // One call has "boris", another lacks "meta", but none does both.
        let split = [call("find", #"{"q":"boris meta"}"#), call("find", #"{"q":"zed"}"#)]
        #expect(score([check], calls: split).count == 1)
        #expect(score([check], calls: split + [call("find", #"{"q":"boris"}"#)]).isEmpty)
    }

    @Test func allMustAllPass() {
        let failures = score([Check(text_has: "a"), Check(text_has: "b"), Check(text_has: "c")], text: "a")
        #expect(failures.count == 2)
    }

    @Test func anyNeedsOnePass() {
        let checks = [Check(text_has: "x"), Check(text_has: "y")]
        #expect(score(any: checks, text: "y").isEmpty)
        #expect(score(any: checks, text: "z").count == 1)
        #expect(score(any: [], text: "z").isEmpty)
    }

    @Test func allAndAnyCombine() {
        #expect(score([Check(text_has: "a")], any: [Check(text_has: "b")], text: "a").count == 1)
        #expect(score([Check(text_has: "a")], any: [Check(text_has: "b")], text: "ab").isEmpty)
    }

    @Test func emptyCheckIsAFailure() {
        #expect(score([Check()]).count == 1)
    }
}

@Suite struct EvalRunTests {
    private let find = EvalToolDef(name: "find", description: "Find.", schema: ["type": "object"], kind: .read, live: nil)

    @Test func fixtureReachesTheModel() async {
        let provider = ScriptedProvider([reply("", calls: [call("find")]), reply("Found Boris.")])
        let c = evalCase("a", expect: .init(all: [Check(call: "find"), Check(text_has: "boris")]), fixtures: ["find": "FIXTURE-TEXT"])
        let report = await Eval.run(cases: [c], tools: [find], system: "SYS", provider: provider)
        #expect(report.results[0].passed)
        #expect(report.results[0].failures.isEmpty)
        #expect(report.results[0].calls.map(\.name) == ["find"])
        #expect(report.results[0].text == "Found Boris.")
        #expect(report.results[0].usage.input == 20)
        let requests = await provider.requests
        #expect(requests[0].system == "SYS")
        #expect(requests[0].tools.map(\.name) == ["find"])
        #expect(requests[1].messages.last?.text == "FIXTURE-TEXT")
    }

    @Test func unknownFixtureIsNoResults() async {
        let provider = ScriptedProvider([reply("", calls: [call("find")]), reply("done")])
        _ = await Eval.run(cases: [evalCase("a", fixtures: ["other": "x"])], tools: [find], system: "", provider: provider)
        #expect(await provider.requests[1].messages.last?.text == "No results.")
    }

    @Test func liveToolReplacesFixture() async {
        let provider = ScriptedProvider([reply("", calls: [call("find")]), reply("done")])
        let live = AnyTool(spec: ToolSpec(name: "find", description: "", schema: .string()), kind: .read) { _ in "LIVE" }
        _ = await Eval.run(
            cases: [evalCase("a", fixtures: ["find": "FIXTURE"])], tools: [find], system: "", provider: provider, live: ["find": live])
        #expect(await provider.requests[1].messages.last?.text == "LIVE")
    }

    @Test func approvalToolRunsAndRecords() async {
        let ask = EvalToolDef(name: "ask", description: "", schema: ["type": "object"], kind: .approval, live: nil)
        let provider = ScriptedProvider([reply("", calls: [call("ask")]), reply("done")])
        let report = await Eval.run(cases: [evalCase("a", fixtures: ["ask": "OK"])], tools: [ask], system: "", provider: provider)
        #expect(report.results[0].calls.map(\.name) == ["ask"])
        #expect(await provider.requests[1].messages.last?.text == "OK")
    }

    @Test func providerErrorFailsTheCase() async {
        let report = await Eval.run(cases: [evalCase("a")], tools: [], system: "", provider: Boom())
        #expect(!report.results[0].passed)
        #expect(report.results[0].failures.first?.hasPrefix("error: ") == true)
        #expect(report.passed == 0)
    }

    @Test func failedChecksFailTheCase() async {
        let c = evalCase("a", expect: .init(all: [Check(text_has: "never")]))
        let report = await Eval.run(cases: [c], tools: [], system: "", provider: ScriptedProvider([reply("hello")]))
        #expect(!report.results[0].passed)
        #expect(report.results[0].failures.count == 1)
    }

    @Test func resultsKeepCaseOrderUnderConcurrency() async {
        // Case 0 finishes last, so a completion-ordered result list would differ.
        let ids = ["slow-0", "1", "2", "3", "4"]
        let cases = ids.map { id in evalCase(id, expect: .init(all: [Check(text_has: "hi \(id)")])) }
        let report = await Eval.run(cases: cases, tools: [], system: "", provider: Echo(), concurrency: 3)
        #expect(report.results.map(\.id) == ids)
        #expect(report.results.allSatisfy { $0.passed })
        #expect(report.passed == 5)
        #expect(report.results[0].ms >= 100)
    }

    @Test func p50IsTheMedian() {
        func result(_ ms: Int, passed: Bool = true) -> EvalResult {
            EvalResult(id: "", passed: passed, failures: [], ms: ms, usage: .zero, calls: [], text: "")
        }
        #expect(EvalReport(results: [result(30), result(10), result(20)]).p50ms == 20)
        #expect(EvalReport(results: [result(10), result(20), result(30), result(41)]).p50ms == 25)
        #expect(EvalReport(results: []).p50ms == 0)
        #expect(EvalReport(results: [result(1), result(2, passed: false)]).passed == 1)
    }
}

@Suite struct EvalLoadTests {
    @Test func loadsCases() throws {
        let url = try tempFile(
            """
            {"id":"a","messages":[{"role":"user","text":"hi"},{"role":"assistant","text":"yo"}],"fixtures":{"find":"R"},\
            "expect":{"all":[{"call":"find","args_has":"x","args_lacks":"y"},{"no_call":"z"},{"text_has":"t"},{"text_lacks":"u"}],\
            "any":[{"text_has":"q"}]}}

            {"id":"b","messages":[{"role":"user","text":"hi"}],"expect":{"all":[]}}

            """)
        let cases = try Eval.loadCases(url)
        #expect(cases.map(\.id) == ["a", "b"])
        #expect(cases[0].messages.map(\.role) == [.user, .assistant])
        #expect(cases[0].fixtures == ["find": "R"])
        #expect(cases[0].expect.all.count == 4)
        #expect(cases[0].expect.all[0].args_lacks == "y")
        #expect(cases[0].expect.any?.count == 1)
        #expect(cases[1].fixtures == nil)
        #expect(cases[1].expect.any == nil)
    }

    @Test func badLineNamesItsNumber() throws {
        let url = try tempFile(
            """
            {"id":"a","messages":[],"expect":{"all":[]}}

            {not json}
            """)
        do {
            _ = try Eval.loadCases(url)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("line 3"))
        }
    }

    @Test func loadsTools() throws {
        let url = try tempFile(
            """
            [{"name":"find","description":"d","schema":{"type":"object","properties":{"q":{"type":"string"}}},"kind":"read"},
             {"name":"web_search","description":"s","schema":{"type":"object"},"kind":"approval","live":"exa"}]
            """)
        let tools = try Eval.loadTools(url)
        #expect(tools.map(\.name) == ["find", "web_search"])
        #expect(tools[0].kind == .read)
        #expect(tools[0].live == nil)
        #expect(tools[1].kind == .approval)
        #expect(tools[1].live == "exa")
        #expect(tools[0].schema == ["type": "object", "properties": ["q": ["type": "string"]]])
    }

    /// The error text for a cases file, or nil when it loads.
    private func loadError(_ text: String) throws -> String? {
        do { _ = try Eval.loadCases(try tempFile(text)); return nil } catch { return "\(error)" }
    }

    private func line(_ check: String) -> String {
        #"{"id":"a","messages":[],"expect":{"all":[\#(check)]}}"#
    }

    @Test(arguments: [
        #"{"call":"find","text_has":"zzz"}"#,
        #"{"text_has":"a","text_lacks":"a"}"#,
        #"{"no_call":"x","call":"y"}"#,
        #"{}"#,
        #"{"text_hass":"a"}"#,
        #"{"call":"find","args_hass":"a"}"#,
        #"{"text_has":"a","args_has":"a"}"#,
        #"{"no_call":"a","args_lacks":"a"}"#,
        #"{"text_has":1}"#,
    ])
    func invalidChecksAreRejectedWithTheLineNumber(check: String) throws {
        let error = try loadError("\n" + line(check) + "\n")
        #expect(error?.contains("line 2") == true, "\(check): \(error ?? "loaded")")
    }

    @Test func invalidCheckInAnyIsRejectedToo() throws {
        let text = #"{"id":"a","messages":[],"expect":{"all":[],"any":[{"text_has":"a","call":"b"}]}}"#
        #expect(try loadError(text)?.contains("line 1") == true)
    }

    @Test func validChecksStillLoad() throws {
        #expect(try loadError(line(#"{"call":"find","args_has":"a","args_lacks":"b"}"#)) == nil)
    }

    @Test func crlfFilesLoad() throws {
        let a = line(#"{"text_has":"a"}"#), b = line(#"{"text_has":"b"}"#)
        let url = try tempFile(a + "\r\n\r\n" + b + "\r\n")
        #expect(try Eval.loadCases(url).count == 2)
        #expect(try loadError(a + "\r\n\r\n" + #"{bad}"# + "\r\n")?.contains("line 3") == true)
    }

    @Test func blankFileLoadsNoCases() throws {
        #expect(try Eval.loadCases(tempFile("")).isEmpty)
        #expect(try Eval.loadCases(tempFile("\n  \r\n\n")).isEmpty)
    }

    @Test func liveToolsMapsOnlyWhatIsListed() async throws {
        var asked: [String] = []
        let exa = AnyTool(spec: ToolSpec(name: "x", description: "", schema: .string()), kind: .read) { _ in "EXA" }
        let defs = [
            searchDef, EvalToolDef(name: "find", description: "", schema: [:], kind: .read, live: nil),
        ].map { def -> EvalToolDef in
            var d = def
            if d.name == "web_search" { d.live = "exa" }
            return d
        }
        let live = try Eval.liveTools(for: defs, sources: ["exa": { asked.append("exa"); return exa }, "other": { asked.append("other"); return exa }])
        #expect(Array(live.keys) == ["web_search"])
        #expect(asked == ["exa"])
        #expect(try await live["web_search"]?.call(json: "{}") == "EXA")
        #expect(try Eval.liveTools(for: [], sources: ["exa": { asked.append("again"); return exa }]).isEmpty)
        #expect(asked == ["exa"])
    }

    @Test func liveToolsRejectsAnUnknownSource() {
        var def = searchDef
        def.live = "bing"
        #expect(throws: EvalError.self) { try Eval.liveTools(for: [def], sources: [:]) }
    }

    @Test func emptyOrMissingAllLoadsAndPasses() async throws {
        let text = #"""
            {"id":"empty","messages":[{"role":"user","text":"hi"}],"expect":{"all":[]}}
            {"id":"missing","messages":[{"role":"user","text":"hi"}],"expect":{}}
            {"id":"anyonly","messages":[{"role":"user","text":"hi"}],"expect":{"any":[{"text_has":"nope"}]}}
            """#
        let cases = try Eval.loadCases(tempFile(text))
        #expect(cases.map(\.id) == ["empty", "missing", "anyonly"])
        #expect(cases.allSatisfy { $0.expect.all.isEmpty })
        let report = await Eval.run(cases: cases, tools: [], system: "", provider: Echo())
        #expect(report.results.map(\.passed) == [true, true, false])
    }

    @Test func erroredRunFailsEvenWithNoChecks() async {
        let report = await Eval.run(cases: [evalCase("a")], tools: [], system: "", provider: Boom())
        #expect(!report.results[0].passed)
        #expect(report.results[0].error?.isEmpty == false)
    }
}

@Suite struct EvalJSONLineTests {
    private func result(error: String? = nil, args: String = #"{"q":"boris","a":[1,true]}"#) -> EvalResult {
        EvalResult(
            id: "a", passed: error == nil, failures: [], ms: 12,
            usage: Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, model: "m"),
            calls: [call("find", args)], text: "hi \"there\"/", error: error)
    }

    @Test func encodesOneLineWithSortedKeys() throws {
        let line = try result().jsonLine()
        #expect(!line.contains("\n"))
        #expect(
            line
                == #"{"calls":[{"arguments":{"a":[1,true],"q":"boris"},"name":"find"}],"id":"a","ms":12,"text":"hi \"there\"/","usage":{"cacheRead":3,"cacheWrite":4,"input":1,"model":"m","output":2}}"#
        )
    }

    @Test func unparsableArgumentsStayAString() throws {
        let line = try result(args: "{oops").jsonLine()
        #expect(line.contains(#""arguments":"{oops""#))
        #expect(try result(args: "").jsonLine().contains(#""arguments":"""#))
    }

    @Test func errorIsPresentOnlyWhenTheRunErrored() throws {
        #expect(try result(error: "boom").jsonLine().contains(#""error":"boom""#))
        #expect(try !result().jsonLine().contains("error"))
    }
}
