import Foundation
import LilMac

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

let resumePrefix = "resume-"
private let tickBudget: TimeInterval = 25  // iOS gives about 30 s; stop 5 s early

/// One heartbeat of the phone: due jobs, then the sensors. Cancelling the task cuts running jobs off.
func runTick(_ scheduler: Scheduler, _ heartbeat: Heartbeat?, deadline: Date) async {
    await scheduler.tick(now: Date(), deadline: deadline)
    await heartbeat?.tick(now: Date())
}

/// Saves (or replaces) a chat as a job `Scheduler` never claims (it is due at `.distantFuture`); `ChatRuns` resumes it.
func saveResumeJob(_ messages: [Message], toolset: String, id: String? = nil, to store: JobStore) async throws {
    try await store.upsert(
        Job(
            id: id ?? resumePrefix + UUID().uuidString, schedule: .once(.distantFuture), prompt: "", toolset: toolset,
            nextRun: .distantFuture, messages: messages))
}

/// Forwards one run's events and calls `onCheckpoint` before forwarding each checkpoint. Returns true when the task
/// was cancelled before the run finished. A failed run reports `.text("Error: …")`.
private func drive(
    _ agent: Agent, _ messages: [Message], onCheckpoint: @Sendable ([Message]) async -> Void,
    _ onEvent: @Sendable (AgentEvent) async -> Void
) async -> Bool {
    var finished = false
    do {
        for try await event in agent.run(messages) {
            switch event {
            case .checkpoint(let all): await onCheckpoint(all)
            case .done, .budgetExhausted: finished = true
            default: break
            }
            await onEvent(event)
        }
    } catch {
        if !Task.isCancelled { await onEvent(.text("Error: \(error)")) }
    }
    return !finished && Task.isCancelled
}

/// Chats the user started, kept as one saved job each while they run, so a kill or an expired background task
/// loses nothing: the job holds the latest checkpoint and resumes on the next open (at least once). A run that
/// finishes, fails or is stopped deletes its job.
actor ChatRuns {
    private let store: JobStore
    private var active: Set<String> = []  // ids a run in this process owns; `resume` never claims them

    init(store: JobStore) { self.store = store }

    /// A value on `expiry` (iOS ran out of background time) cancels the run and keeps its job. Cancelling the
    /// calling task is the user stopping: the job goes too. A resumed chat passes its saved `id`.
    func run(
        _ agent: Agent, _ messages: [Message], toolset: String, id: String? = nil, expiry: AsyncStream<Void>,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async {
        let id = id ?? resumePrefix + UUID().uuidString
        active.insert(id)
        defer { active.remove(id) }
        await save(id, messages, toolset)
        let work = Task { await drive(agent, messages, onCheckpoint: { await self.save(id, $0, toolset) }, onEvent) }
        let watch = Task { for await _ in expiry { work.cancel(); break } }
        let cut = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        watch.cancel()
        if !cut || Task.isCancelled { try? await store.delete(id) }
    }

    private func save(_ id: String, _ messages: [Message], _ toolset: String) async {
        try? await saveResumeJob(messages, toolset: toolset, id: id, to: store)
    }

    /// Hands each saved chat that no run here owns to `run`, which must pass the `id` to `run(…id:)`. The job stays
    /// saved until that run ends, so a kill at any point resumes it again.
    func resume(run: @escaping @Sendable (_ id: String, _ messages: [Message], _ toolset: String) async -> Void) async {
        // Claim after the await, with no suspension before `insert`: a concurrent call then sees `active` set.
        let claimed = ((try? await store.list()) ?? []).filter { $0.id.hasPrefix(resumePrefix) && !active.contains($0.id) }
        active.formUnion(claimed.map(\.id))
        for job in claimed {
            await run(job.id, job.messages ?? [], job.toolset)
            active.remove(job.id)
        }
    }
}

#if os(iOS)
/// One iOS background task. The expiration handler runs on the main thread and must end the task before it returns,
/// so it only signals the run and ends here; nothing async happens after expiry.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(onExpire: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "lilmac.chat") { [weak self] in
            onExpire()
            self?.end()
        }
    }

    func end() {  // idempotent: the run and the handler may both call it
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Gives jobs and the heartbeat time on iOS: background refresh, app open, and a timer while the app is open.
/// Chats the user starts keep running in the background and resume on the next open if iOS cuts them off.
@MainActor
public final class PhoneRunner {
    public struct Settings: Sendable {
        public var foregroundInterval: Duration = .seconds(30)
        public var backgroundRequest: TimeInterval = 15 * 60
        public init() {}
    }

    /// Changing `foregroundInterval` applies from the ticker's next wait.
    public var settings: Settings {
        didSet {
            guard settings.foregroundInterval != oldValue.foregroundInterval else { return }
            let (ticker, interval) = (ticker, settings.foregroundInterval)
            Task { await ticker.setInterval(interval) }
        }
    }
    /// Receives the events of chats resumed by `onAppActive()`.
    public var onResumed: (@MainActor (AgentEvent) -> Void)?

    private let refreshID: String
    private let scheduler: Scheduler
    private let heartbeat: Heartbeat?
    private let makeChatAgent: @Sendable (String) -> Agent
    private let ticker: ForegroundTicker
    private let runs: ChatRuns

    public init(
        refreshID: String, store: JobStore, scheduler: Scheduler, heartbeat: Heartbeat?, settings: Settings = .init(),
        makeChatAgent: @escaping @Sendable (_ toolset: String) -> Agent
    ) {
        self.refreshID = refreshID
        self.scheduler = scheduler
        self.heartbeat = heartbeat
        self.settings = settings
        self.makeChatAgent = makeChatAgent
        ticker = ForegroundTicker(interval: settings.foregroundInterval) {
            await runTick(scheduler, heartbeat, deadline: Date() + tickBudget)
        }
        runs = ChatRuns(store: store)
    }

    /// Call before the app finishes launching. The handler runs on the main queue, so its isolation is real.
    public func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { @MainActor [weak self] task in
            guard let self else { return task.setTaskCompleted(success: false) }
            scheduleRefresh()  // first: whatever happens next, iOS has a next request
            let work = Task { await runBackgroundRefresh(deadline: Date() + tickBudget) }
            // iOS calls this off the main thread: `@Sendable` keeps it from inheriting MainActor.
            task.expirationHandler = { @Sendable in work.cancel() }  // the scheduler turns a cancel into "cutoff"
            Task {
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    /// What a background refresh does: due jobs, then the heartbeat. Cancelling the caller cuts running jobs off.
    public func runBackgroundRefresh(deadline: Date) async {
        await runTick(scheduler, heartbeat, deadline: deadline)
    }

    public func onAppActive() {
        let runs = runs
        Task {
            await runs.resume { [weak self] id, messages, toolset in
                await self?.start(messages, toolset: toolset, id: id) { [weak self] in self?.onResumed?($0) }.value
            }
        }
        let ticker = ticker
        Task { await ticker.start() }
    }

    public func onAppInactive() {
        let ticker = ticker
        Task { await ticker.stop() }
        scheduleRefresh()
    }

    /// Runs the chat in a background task and keeps its latest checkpoint saved as a job. If iOS ends the background
    /// time, the run stops and the job stays; the next `onAppActive()` resumes it through this same path.
    /// Cancel the returned task to stop the run.
    public func protect(
        _ messages: [Message], toolset: String, onEvent: @escaping @MainActor (AgentEvent) -> Void
    ) -> Task<Void, Never> {
        start(messages, toolset: toolset, id: nil, onEvent: onEvent)
    }

    private func start(
        _ messages: [Message], toolset: String, id: String?, onEvent: @escaping @MainActor (AgentEvent) -> Void
    ) -> Task<Void, Never> {
        let (expiry, expire) = AsyncStream<Void>.makeStream()
        let background = BackgroundTask { expire.yield() }
        let (agent, runs) = (makeChatAgent(toolset), runs)
        return Task {
            await runs.run(agent, messages, toolset: toolset, id: id, expiry: expiry) { await onEvent($0) }
            background.end()
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: settings.backgroundRequest)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
