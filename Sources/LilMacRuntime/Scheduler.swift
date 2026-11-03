import Foundation
import LilMac

public struct Scheduler: Sendable {
    private enum Outcome: Sendable { case done(String), failed, timeout, cutoff }

    let store: JobStore
    let notifier: any Notifier
    let timeZone: TimeZone
    /// Hosts build the agent with the default `approve`, which declines: unattended runs cannot ask the user.
    let makeAgent: @Sendable (Job) -> Agent

    public init(
        store: JobStore, notifier: any Notifier, timeZone: TimeZone = .current,
        makeAgent: @escaping @Sendable (Job) -> Agent
    ) {
        self.store = store
        self.notifier = notifier
        self.timeZone = timeZone
        self.makeAgent = makeAgent
    }

    /// Claims due jobs and runs them together. Returns when each is done, timed out or cut off by `deadline`.
    public func tick(now: Date, deadline: Date) async {
        guard let claimed = try? await store.claimDue(now: now, timeZone: timeZone) else { return }
        await withTaskGroup(of: Void.self) { group in
            for (job, slot) in claimed { group.addTask { await run(job, slot: slot, now: now, deadline: deadline) } }
        }
    }

    private func run(_ job: Job, slot: Date, now: Date, deadline: Date) async {
        let untilDeadline = deadline.timeIntervalSince(now)
        let cutoff = untilDeadline <= job.timeout  // whichever limit comes first names the outcome
        let limit = max(0, cutoff ? untilDeadline : job.timeout)
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(limit))
                    return cutoff ? .cutoff : .timeout
                } catch { return .cutoff }  // the tick itself was cancelled
            }
            if limit > 0 { group.addTask { await collect(job) } }
            let first = await group.next() ?? .failed
            group.cancelAll()
            if Task.isCancelled {  // the sleep and the run both notice a cancel; they race, so decide here
                if case .done = first { return first }
                return .cutoff
            }
            return first
        }

        let status: String, text: String?
        switch outcome {
        case .done(let t): (status, text) = ("done", t.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failed: (status, text) = ("failed", nil)
        case .timeout: (status, text) = ("timeout", nil)
        case .cutoff: (status, text) = ("cutoff", nil)
        }
        try? await store.recordRun(job.id, started: now, status: status)
        var isOnce = false
        if case .once = job.schedule { isOnce = true }
        let restore: Bool
        switch outcome {
        case .cutoff: restore = true  // runs again later
        case .done: restore = false
        case .failed, .timeout:  // a reminder must not vanish on a blip
            let tried = isOnce ? await failures(of: job.id) : Self.attempts
            restore = tried < Self.attempts
        }
        if restore { try? await store.reschedule(job.id, to: slot) } else if isOnce { try? await store.delete(job.id) }
        if let text, !isHold(text) { await notifier.deliver(text, at: slot > now ? slot : nil) }
    }

    private static let attempts = 3

    private func failures(of id: String) async -> Int {
        (try? await store.runs(id))?.filter { $0 == "failed" || $0 == "timeout" }.count ?? 0
    }

    /// The last text of the final step. Running out of steps is a failed run: it produced no answer.
    private func collect(_ job: Job) async -> Outcome {
        var text = ""
        do {
            for try await event in makeAgent(job).run(job.messages ?? [.user(job.prompt)]) {
                switch event {
                case .text(let t): text = t
                case .checkpoint: text = ""  // a step that called tools was not the answer
                case .done: return .done(text)
                case .budgetExhausted: return .failed
                default: break
                }
            }
        } catch {}
        return .failed
    }
}

/// Empty, a bare "hold" in any case ("**HOLD**", "Hold."), or uppercase HOLD with a note ("HOLD - nothing new").
/// "Hold the meeting at 3" and "Holding ..." are messages.
func isHold(_ text: String) -> Bool {
    let word = text.drop { !$0.isLetter }
    let bare = word.reversed().drop { !$0.isLetter }.reversed()
    if bare.isEmpty || String(bare).uppercased() == "HOLD" { return true }
    return word.hasPrefix("HOLD") && !(word.dropFirst(4).first?.isLetter ?? false)
}
