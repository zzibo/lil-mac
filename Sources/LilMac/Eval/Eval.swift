import Foundation

public struct EvalCase: Codable, Sendable {
    public struct Turn: Codable, Sendable {
        public var role: Message.Role
        public var text: String
    }

    /// One field set per check. Property names are the JSON keys, so no `CodingKeys`.
    public struct Check: Codable, Sendable {
        public var call: String?
        public var args_has: String?
        public var args_lacks: String?
        public var no_call: String?
        public var text_has: String?
        public var text_lacks: String?
    }

    public struct Expect: Codable, Sendable {
        public var all: [Check]
        public var any: [Check]?
    }

    public var id: String
    public var messages: [Turn]
    public var fixtures: [String: String]?
    public var expect: Expect
}

extension EvalCase.Expect {
    private enum CodingKeys: String, CodingKey { case all, any }

    /// `all` may be empty or missing: the case then carries no built-in checks.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(all: try c.decodeIfPresent([EvalCase.Check].self, forKey: .all) ?? [], any: try c.decodeIfPresent([EvalCase.Check].self, forKey: .any))
    }
}

extension EvalCase.Check {
    /// Strict: an unknown key, a second primary field or a stray `args_*` would otherwise score as a false pass.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        func reject(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
        }
        let primary = ["call", "no_call", "text_has", "text_lacks"]
        let known = Set(primary + ["args_has", "args_lacks"])
        if let key = raw.keys.sorted().first(where: { !known.contains($0) }) { throw reject("unknown check key \"\(key)\"") }
        guard primary.filter({ raw[$0] != nil }).count == 1 else {
            throw reject("a check needs exactly one of \(primary.joined(separator: ", "))")
        }
        if raw["call"] == nil, raw["args_has"] != nil || raw["args_lacks"] != nil {
            throw reject("args_has and args_lacks need call")
        }
        self.init(
            call: raw["call"], args_has: raw["args_has"], args_lacks: raw["args_lacks"],
            no_call: raw["no_call"], text_has: raw["text_has"], text_lacks: raw["text_lacks"])
    }
}

public struct EvalToolDef: Codable, Sendable {
    public var name: String
    public var description: String
    public var schema: JSONValue
    public var kind: ToolKind
    public var live: String?
}

public struct EvalResult: Sendable {
    public let id: String
    public let passed: Bool
    public let failures: [String]
    public let ms: Int
    public let usage: Usage
    public let calls: [ToolCall]
    public let text: String
    /// Set when the run itself failed (provider error), as opposed to a failed check.
    public var error: String? = nil

    private struct Line: Encodable {
        struct Call: Encodable { var name: String; var arguments: JSONValue }
        var id: String
        var text: String
        var calls: [Call]
        var ms: Int
        var usage: Usage
        var error: String?
    }

    /// One JSON object on one line, keys sorted, for apps that score results themselves.
    public func jsonLine() throws -> String {
        let calls = self.calls.map { call in
            Line.Call(
                name: call.name,
                arguments: (try? JSONDecoder().decode(JSONValue.self, from: Data(call.argumentsJSON.utf8)))
                    ?? .string(call.argumentsJSON))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Line(id: id, text: text, calls: calls, ms: ms, usage: usage, error: error))
        return String(decoding: data, as: UTF8.self)
    }
}

public struct EvalReport: Sendable {
    public let results: [EvalResult]

    public init(results: [EvalResult]) { self.results = results }

    public var passed: Int { results.filter(\.passed).count }

    public var p50ms: Int {
        let ms = results.map(\.ms).sorted()
        guard !ms.isEmpty else { return 0 }
        return (ms[(ms.count - 1) / 2] + ms[ms.count / 2]) / 2
    }
}

public struct EvalError: Error, CustomStringConvertible {
    public let description: String
}

public enum Eval {
    public static func loadCases(_ url: URL) throws -> [EvalCase] {
        // "\r\n" is one Character in Swift, so test for both forms.
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        var cases: [EvalCase] = []
        for (i, line) in lines.enumerated() where !line.allSatisfy(\.isWhitespace) {
            do {
                cases.append(try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8)))
            } catch {
                var reason = "\(error)"
                if case DecodingError.dataCorrupted(let context) = error { reason = context.debugDescription }
                throw EvalError(description: "\(url.lastPathComponent) line \(i + 1): \(reason)")
            }
        }
        return cases
    }

    /// Maps each tool's `live` source to a tool by name. A source is built only when a tool lists it.
    public static func liveTools(for tools: [EvalToolDef], sources: [String: () throws -> AnyTool]) throws -> [String: AnyTool] {
        var live: [String: AnyTool] = [:]
        for tool in tools {
            guard let source = tool.live else { continue }
            guard let make = sources[source] else { throw EvalError(description: "tool \(tool.name): unknown live source \"\(source)\"") }
            live[tool.name] = try make()
        }
        return live
    }

    public static func loadTools(_ url: URL) throws -> [EvalToolDef] {
        try JSONDecoder().decode([EvalToolDef].self, from: Data(contentsOf: url))
    }

    public static func run(
        cases: [EvalCase], tools: [EvalToolDef], system: String, provider: any Provider,
        live: [String: AnyTool] = [:], budget: Int = 6, concurrency: Int = 4
    ) async -> EvalReport {
        let work: @Sendable (Int) async -> (Int, EvalResult) = { i in
            (i, await runOne(cases[i], tools, system, provider, live, budget))
        }
        var results = [EvalResult?](repeating: nil, count: cases.count)
        await withTaskGroup(of: (Int, EvalResult).self) { group in
            var next = 0
            while next < min(max(concurrency, 1), cases.count) {
                let i = next
                group.addTask { await work(i) }
                next += 1
            }
            for await (i, result) in group {
                results[i] = result
                if next < cases.count {
                    let j = next
                    group.addTask { await work(j) }
                    next += 1
                }
            }
        }
        return EvalReport(results: results.compactMap { $0 })
    }

    private static func runOne(
        _ c: EvalCase, _ defs: [EvalToolDef], _ system: String, _ provider: any Provider,
        _ live: [String: AnyTool], _ budget: Int
    ) async -> EvalResult {
        let fixtures = c.fixtures ?? [:]
        let tools = defs.map { def -> AnyTool in
            let spec = ToolSpec(name: def.name, description: def.description, schema: .raw(def.schema))
            if let tool = live[def.name] { return AnyTool(spec: spec, kind: def.kind) { try await tool.call(json: $0) } }
            return AnyTool(spec: spec, kind: def.kind) { _ in fixtures[def.name] ?? "No results." }
        }
        let agent = Agent(
            provider: provider, system: system, toolset: Toolset(name: "eval", tools: tools),
            budget: budget, approve: { _ in true })
        var calls: [ToolCall] = []
        var text = ""
        var usage = Usage.zero
        var failures: [String] = []
        var runError: String?
        let start = ContinuousClock.now
        do {
            for try await event in agent.run(c.messages.map { Message(role: $0.role, text: $0.text) }) {
                switch event {
                case .text(let t): text += t
                case .toolResult(let call, _): calls.append(call)
                case .done(let u), .budgetExhausted(let u): usage = u
                default: break
                }
            }
            failures = score(c.expect, calls: calls, text: text)
        } catch {
            runError = "\(error)"
            failures = ["error: \(error)"]
        }
        let d = start.duration(to: .now).components
        let ms = Int(d.seconds) * 1000 + Int(d.attoseconds / 1_000_000_000_000_000)
        return EvalResult(id: c.id, passed: failures.isEmpty, failures: failures, ms: ms, usage: usage, calls: calls, text: text, error: runError)
    }

    /// Failure reasons; empty means pass. Every `all` check must pass, and one `any` check when `any` is non-empty.
    public static func score(_ expect: EvalCase.Expect, calls: [ToolCall], text: String) -> [String] {
        func has(_ haystack: String, _ needle: String) -> Bool {
            needle.isEmpty || haystack.range(of: needle, options: .caseInsensitive) != nil
        }

        func passes(_ c: EvalCase.Check) -> Bool? {
            if let name = c.call {
                return calls.contains { call in
                    call.name == name && (c.args_has.map { has(call.argumentsJSON, $0) } ?? true)
                        && (c.args_lacks.map { !has(call.argumentsJSON, $0) } ?? true)
                }
            }
            if let name = c.no_call { return !calls.contains { $0.name == name } }
            if let s = c.text_has { return has(text, s) }
            if let s = c.text_lacks { return !has(text, s) }
            return nil
        }

        func describe(_ c: EvalCase.Check) -> String {
            if let name = c.call {
                let args = [c.args_has.map { "args_has \"\($0)\"" }, c.args_lacks.map { "args_lacks \"\($0)\"" }].compactMap { $0 }
                return "no call to \(name)" + (args.isEmpty ? "" : " with " + args.joined(separator: ", "))
            }
            if let name = c.no_call { return "unexpected call to \(name)" }
            if let s = c.text_has { return "text lacks \"\(s)\"" }
            if let s = c.text_lacks { return "text has \"\(s)\"" }
            return "empty check"
        }

        var failures = expect.all.filter { passes($0) != true }.map(describe)
        if let any = expect.any, !any.isEmpty, !any.contains(where: { passes($0) == true }) {
            failures.append("none of any passed: " + any.map(describe).joined(separator: " | "))
        }
        return failures
    }
}
