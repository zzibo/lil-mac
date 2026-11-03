import BackgroundTasks
import EventKit
import LilMac
import LilMacRuntime
import SwiftUI
import UserNotifications

struct TestResult: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case PASS, FAIL, SKIP }
    var name: String
    var status: Status
    var detail: String
    var ms: Int
    var id: String { name }
}

private struct Report: Codable {
    var device: String, os: String, startedAt: Date, finishedAt: Date, results: [TestResult]
}

private struct Skip: Error { var reason: String }
private struct Fail: Error, CustomStringConvertible { var description: String }

private func check(_ ok: Bool, _ message: @autoclosure () -> String) throws {
    if !ok { throw Fail(description: message()) }
}

private actor Counter {
    private(set) var n = 0
    func bump() { n += 1 }
}

/// Counts runs the model was woken for: sends that start from a user message.
private struct CountingProvider: Provider {
    let inner: any Provider
    let wakes: Counter
    func send(_ request: ModelRequest) async throws -> ModelReply {
        if request.messages.last?.role == .user { await wakes.bump() }
        return try await inner.send(request)
    }
}

private actor RecordingNotifier: Notifier {
    let inner: (any Notifier)?
    private(set) var delivered: [(text: String, at: Date?, called: Date)] = []
    init(inner: (any Notifier)? = nil) { self.inner = inner }
    func deliver(_ text: String, at: Date?) async {
        delivered.append((text, at, Date()))
        await inner?.deliver(text, at: at)
    }
}

private struct StubSensor: Sensor {
    let name = "stub"
    let value: String
    func read() async -> String? { value }
}

@MainActor private final class Events {
    var all: [AgentEvent] = []
}

@MainActor @Observable
final class DeviceTest {
    var results: [TestResult] = []
    var running = false
    let header: String
    private let runner: PhoneRunner
    private let store: JobStore

    init(runner: PhoneRunner, store: JobStore) {
        self.runner = runner
        self.store = store
        var machine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        if machine == nil {
            var info = utsname()
            uname(&info)
            machine = withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        header = "\(UIDevice.current.model) (\(machine ?? "?")), iOS \(UIDevice.current.systemVersion)"
    }

    func run() async {
        guard !running else { return }
        running = true
        results = []
        let started = Date()
        let brain = DemoBrain.current
        DemoBrain.current = .fake  // the real runner, scheduler and heartbeat build their agents from the current brain
        DeviceLog.write("selftest started")
        let tests: [(String, () async throws -> String)] = [
            ("chat_read_and_action", chatReadAndAction), ("protect_finishes", protectFinishes),
            ("memory_on_device", memoryOnDevice), ("job_lead_time", jobLeadTime),
            ("heartbeat_silent_then_notifies", heartbeatSilentThenNotifies), ("calendar_sensor", calendarSensor),
            ("background_refresh_accepted", backgroundRefreshAccepted),
            ("run_background_refresh_path", runBackgroundRefreshPath), ("apple_model", appleModel),
            ("apple_model_rejects_tools", appleModelRejectsTools),
        ]
        for (name, body) in tests {
            let clock = ContinuousClock()
            let t0 = clock.now
            var result = TestResult(name: name, status: .PASS, detail: "", ms: 0)
            do {
                result.detail = try await body()
            } catch let skip as Skip {
                (result.status, result.detail) = (.SKIP, skip.reason)
            } catch {
                (result.status, result.detail) = (.FAIL, String(describing: error))
            }
            let (s, a) = (clock.now - t0).components
            result.ms = Int(s * 1000 + a / 1_000_000_000_000_000)
            results.append(result)
            DeviceLog.write("selftest \(name) \(result.status.rawValue) \(result.detail)")
        }
        DemoBrain.current = brain
        let report = Report(device: header, os: UIDevice.current.systemVersion, startedAt: started, finishedAt: Date(), results: results)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: URL.documentsDirectory.appending(path: "lilmac-selftest.json"))
        }
        DeviceLog.write("selftest finished")
        running = false
    }

    // MARK: tests

    private func chatReadAndAction() async throws -> String {
        let agent = Agent(
            provider: FakeProvider(), system: "test", toolset: Toolset(name: "chat", tools: [AnyTool(Lookup()), AnyTool(SaveNote())]))
        var actions: [ToolCall] = [], text = "", done = false
        for try await event in agent.run([.user("coffee")]) {
            switch event {
            case .action(let call): actions.append(call)
            case .text(let t): text = t
            case .checkpoint: text = ""
            case .done: done = true
            default: break
            }
        }
        try check(actions.map(\.name) == ["save_note"], "actions: \(actions.map(\.name))")
        try check(text.contains("Lil Mac runs agents inside an iPhone app"), "text: \(text)")
        try check(done, "no .done")
        return text
    }

    private func protectFinishes() async throws -> String {
        let before = Set(try await store.list().map(\.id).filter { $0.hasPrefix("resume-") })
        let events = Events()
        await runner.protect([.user("protect test")], toolset: "chat") { events.all.append($0) }.value
        let left = Set(try await store.list().map(\.id).filter { $0.hasPrefix("resume-") }).subtracting(before)
        try check(events.all.contains { if case .done = $0 { true } else { false } }, "no .done in \(events.all.count) events")
        try check(left.isEmpty, "left resume jobs: \(left)")
        return "\(events.all.count) events, no resume job left"
    }

    private func memoryOnDevice() async throws -> String {
        let memory = try DefaultMemory.standard(in: temp())
        try await memory.remember("The user drinks flat whites", in: .user)
        let snapshot = await memory.snapshot()
        try check(snapshot.contains("flat whites"), "snapshot missed the fact")
        let run = RunRecord(
            id: UUID().uuidString, date: .now, messages: [.user("Who drinks espresso at dawn?"), .assistant("Nobody yet.")],
            usage: Usage(model: "test"))
        try await memory.log(run)
        let hits = try await memory.search("espresso", limit: 5)
        try check(hits.first?.runId == run.id, "search returned \(hits.count) hits")
        return "FTS5 search found the logged run"
    }

    private func jobLeadTime() async throws -> String {
        let jobs = try JobStore(path: temp().appending(path: "jobs.sqlite"))
        let notifier = RecordingNotifier(inner: LocalNotifier())
        let scheduler = Scheduler(store: jobs, notifier: notifier) { job in
            Agent(provider: FakeProvider(), system: "brief", toolset: Toolset(name: job.toolset, tools: []), budget: job.budget)
        }
        let now = Date(), slot = now + 300, id = "lead-test"
        try await jobs.add(Job(id: id, schedule: .once(slot), prompt: "Brief", toolset: "brief", lead: 600, nextRun: slot))
        await scheduler.tick(now: now, deadline: now + 25)
        let delivered = await notifier.delivered
        try check(delivered.count == 1 && abs(delivered[0].at?.timeIntervalSince(slot) ?? 99) < 0.001,  // SQLite stores dates as doubles
             "delivered: \(delivered.map { ($0.text, $0.at as Any) })")
        await scheduler.tick(now: Date(), deadline: Date() + 25)
        let runs = try await jobs.runs(id)
        try check(runs.count == 1, "runs after second tick: \(runs)")

        let (text, called) = (delivered[0].text, delivered[0].called)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.content.body == text }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
        let status = await center.notificationSettings().authorizationStatus
        let auth = "notifications \(["notDetermined", "denied", "authorized", "provisional", "ephemeral"][status.rawValue])"
        guard [.authorized, .provisional, .ephemeral].contains(status) else {
            throw Skip(reason: "delivered at the slot, one run; pending check skipped: \(auth)")
        }
        let expected = slot.timeIntervalSince(called)
        let delay = (pending.first?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        try check(delay.map { abs($0 - expected) <= 5 } ?? false, "pending: \(pending.count), delay \(delay.map { "\($0)" } ?? "none"), expected \(expected)")
        return "pending notification fires in \(Int(delay!)) s (expected \(Int(expected))); \(auth)"
    }

    private func heartbeatSilentThenNotifies() async throws -> String {
        let wakes = Counter()
        let notifier = RecordingNotifier()
        let provider = CountingProvider(inner: FakeProvider(), wakes: wakes)
        let heartbeat = try Heartbeat(
            path: temp().appending(path: "heartbeat.sqlite"), sensors: [StubSensor(value: "A")], notifier: notifier,
            quietHours: nil, cooldown: 0
        ) {
            Agent(provider: provider, system: "heartbeat", toolset: Toolset(name: "heartbeat", tools: [AnyTool(NotifyTool())]), budget: 4)
        }
        await heartbeat.tick(now: Date())
        let first = await notifier.delivered
        let afterFirst = await wakes.n
        try check(afterFirst == 1, "wakes after first tick: \(afterFirst)")
        try check(first.count == 1 && (first[0].at ?? .distantPast) > Date(), "delivered: \(first.map { $0.at as Any })")
        await heartbeat.tick(now: Date())
        let afterSecond = await wakes.n
        try check(afterSecond == 1, "wakes after unchanged tick: \(afterSecond)")
        return "1 wake, 1 notify at a future time, none for an unchanged reading"
    }

    private func calendarSensor() async throws -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        let reading = await EventSoon().read()
        let report = "calendar \(["notDetermined", "restricted", "denied", "fullAccess", "writeOnly"][status.rawValue]), reading: \(reading ?? "none")"
        guard status == .fullAccess else { throw Skip(reason: "calendar access not granted; \(report)") }
        return report
    }

    private func backgroundRefreshAccepted() async throws -> String {
        #if targetEnvironment(simulator)
        throw Skip(reason: "the Simulator never stores background task requests")
        #else
        runner.onAppInactive()
        defer { runner.onAppActive() }
        try await Task.sleep(for: .seconds(1))
        let requests = await BGTaskScheduler.shared.pendingTaskRequests()
        let request = requests.first { $0.identifier == "dev.lilmac.demo.refresh" }
        let ahead = request?.earliestBeginDate?.timeIntervalSinceNow
        try check(ahead.map { abs($0 - 15 * 60) <= 60 } ?? false, "pending: \(requests.map(\.identifier)), ahead: \(ahead.map { "\($0)" } ?? "none")")
        return "refresh request pending, earliest begin in \(Int(ahead!)) s"
        #endif
    }

    private func runBackgroundRefreshPath() async throws -> String {
        let start = Date()
        await runner.runBackgroundRefresh(deadline: start + 25)
        let elapsed = Date().timeIntervalSince(start)
        try check(elapsed < 25, "took \(elapsed) s")
        return String(format: "returned in %.1f s", elapsed)
    }

    private func appleModel() async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else { throw Skip(reason: "needs iOS 26") }
        if let reason = appleModelUnavailableReason() { throw Skip(reason: reason) }
        let agent = Agent(provider: AppleOnDevice(), system: "Answer briefly.", toolset: Toolset(name: "none", tools: []))
        var text = "", done = false
        do {
            for try await event in agent.run([.user("Say hi in five words.")]) {
                if case .text(let t) = event { text = t }
                if case .done = event { done = true }
            }
        } catch {
            #if targetEnvironment(simulator)
            // Observed: availability reads "ready" but the Simulator can't reach the model service (ModelManagerError 1026).
            throw Skip(reason: "Simulator: availability is ready but the model call failed: \(error)")
            #else
            throw error
            #endif
        }
        try check(done && !text.isEmpty, "done: \(done), text: \(text)")
        return text
        #else
        throw Skip(reason: "needs iOS 26")
        #endif
    }

    private func appleModelRejectsTools() async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else { throw Skip(reason: "needs iOS 26") }
        let tool = ToolSpec(name: "t", description: "t", schema: .object([:], required: []))
        do {
            _ = try await AppleOnDevice().send(ModelRequest(system: "", messages: [.user("hi")], tools: [tool]))
        } catch ProviderError.unsupported("tools") {
            return "threw unsupported(\"tools\")"
        }
        throw Fail(description: "send with a tool did not throw unsupported(\"tools\")")
        #else
        throw Skip(reason: "needs iOS 26")
        #endif
    }

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct DeviceTestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let test = model.deviceTest
        List {
            Section {
                Text(test.header).font(.footnote.monospaced())
                Button(test.running ? "Running…" : "Run") { Task { await test.run() } }.disabled(test.running)
            }
            Section("Results") {
                ForEach(test.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.name).font(.footnote.monospaced())
                            Spacer()
                            Text("\(result.status.rawValue)  \(result.ms) ms").font(.caption.bold())
                        }
                        Text(result.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
