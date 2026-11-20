<p align="center">
  <picture>
    <source media="(prefers-reduced-motion: reduce)" srcset="assets/lil-mac.png">
    <img src="assets/lil-mac.gif" width="192" alt="Lil Mac, a tiny beige Mac in green boxing gloves, throwing a jab">
  </picture>
</p>

<h1 align="center">Lil Mac</h1>

<p align="center"><em>Small frame. Long reach. An agent that lives inside your iPhone app.</em></p>

<p align="center">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift Package Manager" src="https://img.shields.io/badge/SPM-compatible-2b7489">
  <img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-blue">
</p>

Lil Mac runs a model in a loop with your tools, keeps memory between chats, and runs scheduled jobs and a heartbeat on the phone itself. It's a small Swift package with no required dependencies.

## Why Lil Mac

iOS has no always-on process, and most agent frameworks assume a server. Lil Mac runs inside your app instead. It works whenever iOS gives your app time: when the user opens it, while it's open, and during background refresh.

| Without Lil Mac | With Lil Mac |
|---|---|
| Write the model loop, tool dispatch and retries | `Agent(provider:system:toolset:)` |
| Store memory and search old chats | `DefaultMemory.standard(in:)` |
| Wire up `BGTaskScheduler`, timers and notifications | `PhoneRunner` |
| Save a chat when the user leaves mid-reply | `runner.protect(...)` |

## Install

In Xcode, choose **File › Add Package Dependencies…** and enter `https://github.com/zzibo/lil-mac`. Or add it to `Package.swift`:

```swift
.package(url: "https://github.com/zzibo/lil-mac", from: "0.1.0")
```

| Product | Contains |
|---|---|
| `LilMac` | Loop, tools, providers, memory, long-chat compaction, helpers, eval. No dependencies. |
| `LilMacRuntime` | Jobs, heartbeat, sensors, notifications, `PhoneRunner`. |
| `LilMacMCP` | Tools from MCP servers over HTTP. |
| `LilMacTools` | `http_get` and `web_search`. |

| Requirement | Version |
|---|---|
| iOS | 17+ (Apple's on-device model needs 26+) |
| macOS | 14+, for tests and the eval tool |
| Swift / Xcode | 6.2 / 26 |

## Quick start

```swift
import LilMac

let agent = Agent(
    provider: OpenAICompatible(model: "anthropic/claude-haiku-5.5", apiKey: devKey),
    system: "You are a helpful assistant.",
    toolset: Toolset(name: "chat", tools: [])
)
for try await event in agent.run([.user("Say hi in five words.")]) {
    if case .text(let text) = event { print(text) }
}
```

`devKey` is for trying it out on your Mac. Don't ship API keys in an app: put them behind a gateway ([recipe](docs/gateway.md)).

## Tools

```swift
struct Lookup: Tool {
    struct Args: Codable, Sendable { var topic: String }
    let name = "lookup"
    let description = "Look up a fact about a topic."
    let kind = ToolKind.read
    let schema = JSONSchema.object(["topic": .string()], required: ["topic"])
    func call(_ args: Args) async throws -> String { "…" }
}
```

Add it with `Toolset(name: "chat", tools: [AnyTool(Lookup())])`. The `kind` decides what the loop does:

| Kind | The loop | Use for |
|---|---|---|
| `.read` | Runs it, several at once | Lookups and searches |
| `.action` | Hands the call to your app as `.action(call)` | Anything the user should confirm, shown as a card |
| `.approval` | Runs it only if your `approve` closure says yes | Risky calls |

To stop a run, cancel the task that reads the stream.

## Providers

| Provider | Use for |
|---|---|
| `OpenAICompatible` | OpenRouter (default), any OpenAI-style endpoint, your gateway. Set `cacheControl: true` for Claude models to cache the prompt. |
| `Anthropic` | Claude direct, with prompt caching |
| `AppleOnDevice` | Apple's on-device model, text only |
| `Fallback([a, b])` | Tries `b` when `a` returns 429, 5xx or times out |

## Memory

`DefaultMemory.standard(in:)` keeps two short notes, about the world and about the user, and sends them at the start of each run. It also logs every run to SQLite with full-text search. Give the model `RememberTool` and `SearchSessionsTool` to use them, or conform to `MemoryStore` to use your own storage. For long chats, add a `Compactor`.

## Jobs and heartbeat

- **Jobs:** a task on a schedule: cron, every N seconds, or once. With a `lead`, a job runs early and its result appears as a notification at the exact time.
- **Heartbeat:** cheap checks, such as "a meeting is coming up", run without the model. The model wakes only when something changed, and stays quiet by default.

`PhoneRunner` runs both on app open, every 30 seconds while the app is open, and on background refresh. See [`Examples/PhoneDemo`](Examples/PhoneDemo) for the full setup and the `Info.plist` keys.

## FAQ

**Does it run when the app is closed?** Only when iOS grants background time, and iOS decides when that is. Notifications prepared in advance still arrive on time.

**Why not run the agent on a server?** You can. Lil Mac is for when the user's data should stay on the phone.

**Can I use my own storage?** Yes. Conform to `MemoryStore`.

**Why boxing gloves?** iOS gives your app a few short rounds of background time. Lil Mac makes each one count.

## Develop

```bash
swift test
```

The eval tool, `lilmac-eval`, runs test chats through the real loop. Run `swift run lilmac-eval` to see its options.

---

<p align="center">MIT licence · Lil Mac is small, but he's still swinging.</p>
