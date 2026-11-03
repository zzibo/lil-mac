import Foundation
import LilMac
import LilMacTools

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lilmac-eval: \(message)\n".utf8))
    exit(2)
}

let usage = """
    usage: lilmac-eval CASES --tools FILE [--system FILE] [--model ID] [--anthropic] [--base-url URL]
                       [--exa-base-url URL] [--price-in USD_PER_M] [--price-out USD_PER_M] [--concurrency N] [--out FILE]
    """

var casesPath: String?
var values: [String: String] = [:]
var useAnthropic = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--anthropic": useAnthropic = true
    case "--tools", "--system", "--model", "--base-url", "--exa-base-url", "--price-in", "--price-out", "--concurrency", "--out":
        guard let value = args.popFirst() else { fail("\(arg) needs a value\n\(usage)") }
        values[arg] = value
    case _ where arg.hasPrefix("--"): fail("unknown option \(arg)\n\(usage)")
    default:
        guard casesPath == nil else { fail("unexpected argument \(arg)\n\(usage)") }
        casesPath = arg
    }
}
guard let casesPath, let toolsPath = values["--tools"] else { fail(usage) }

func number(_ option: String, _ values: [String: String]) -> Double? {
    guard let text = values[option] else { return nil }
    guard let n = Double(text), n.isFinite, n >= 0 else { fail("\(option) needs a non-negative number") }
    return n
}
let priceIn = number("--price-in", values), priceOut = number("--price-out", values)
var concurrency = 4
if let text = values["--concurrency"] {
    guard let n = Int(text), n > 0 else { fail("--concurrency needs a positive integer") }
    concurrency = n
}

func urlOption(_ option: String, _ values: [String: String]) -> URL? {
    guard let text = values[option] else { return nil }
    guard let url = URL(string: text), url.scheme != nil, url.host != nil else { fail("\(option) needs a full URL") }
    return url
}

let env = ProcessInfo.processInfo.environment
func key(_ name: String) -> String {
    guard let value = env[name], !value.isEmpty else { fail("\(name) is not set") }
    return value
}

let provider: any Provider
if useAnthropic {
    guard let model = values["--model"] else { fail("--anthropic needs --model ID") }
    provider = Anthropic(model: model, apiKey: key("ANTHROPIC_API_KEY"))
} else {
    provider = OpenAICompatible(
        baseURL: urlOption("--base-url", values) ?? OpenAICompatible.openRouter, model: values["--model"] ?? "anthropic/claude-haiku-5.5", apiKey: key("OPENROUTER_API_KEY"))
}

let cases: [EvalCase], tools: [EvalToolDef]
var system = ""
do {
    cases = try Eval.loadCases(URL(fileURLWithPath: casesPath))
    tools = try Eval.loadTools(URL(fileURLWithPath: toolsPath))
    if let path = values["--system"] { system = try String(contentsOfFile: path, encoding: .utf8) }
} catch {
    fail("\(error)")
}

guard !cases.isEmpty else { fail("no cases in \(casesPath)") }

let exaBase = urlOption("--exa-base-url", values) ?? URL(string: "https://api.exa.ai")!
let live: [String: AnyTool]
do {
    live = try Eval.liveTools(for: tools, sources: ["exa": { AnyTool(WebSearchTool(apiKey: key("EXA_API_KEY"), baseURL: exaBase)) }])
} catch {
    fail("\(error)")
}

let report = await Eval.run(
    cases: cases, tools: tools, system: system, provider: provider, live: live, concurrency: concurrency)

for r in report.results {
    print(r.passed ? "PASS \(r.id) \(r.ms)ms" : "FAIL \(r.id) \(r.ms)ms: \(r.failures.joined(separator: "; "))")
}
let used = report.results.map(\.usage)
let tokensIn = used.reduce(0) { $0 + $1.input }, tokensOut = used.reduce(0) { $0 + $1.output }
let cacheRead = used.reduce(0) { $0 + $1.cacheRead }
var total =
    "Total \(report.passed)/\(report.results.count) · p50 \(String(format: "%.1f", Double(report.p50ms) / 1000))s"
    + " · tokens \(tokensIn)/\(tokensOut) (cache read \(cacheRead))"
if priceIn != nil || priceOut != nil {
    let cost = (Double(tokensIn) * (priceIn ?? 0) + Double(tokensOut) * (priceOut ?? 0)) / 1_000_000
    total += " · cost $\(String(format: "%.4f", cost))"
}
print(total)
if let path = values["--out"] {
    do {
        let lines = try report.results.map { try $0.jsonLine() + "\n" }
        try lines.joined().write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fail("--out \(path): \(error)")
    }
}
exit(report.passed == report.results.count ? 0 : 1)
