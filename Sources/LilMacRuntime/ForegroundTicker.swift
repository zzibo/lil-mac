import Foundation

/// Runs `tick` at once and then every `interval`, one tick at a time: the next wait starts after a tick ends.
/// The first tick is immediate, so 95 s at 30 s gives ticks at 0, 30, 60 and 90.
public actor ForegroundTicker {
    private var interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let tick: @Sendable () async -> Void
    private var loop: Task<Void, Never>?
    private var stopped: Task<Void, Never>?  // a cancelled loop may still be inside its tick

    public init(
        interval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        tick: @escaping @Sendable () async -> Void
    ) {
        self.interval = interval
        self.sleep = sleep
        self.tick = tick
    }

    /// No-op while running. After `stop()`, the new loop waits for the old loop's tick, so ticks never overlap.
    public func start() {
        guard loop == nil else { return }
        let before = stopped
        loop = Task {
            await before?.value
            while !Task.isCancelled {
                await tick()
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    public func stop() {
        guard let loop else { return }  // a second stop must keep `stopped`: that loop may still be in its tick
        loop.cancel()
        stopped = loop
        self.loop = nil
    }

    /// Applies from the next wait; a wait in progress keeps its length.
    public func setInterval(_ interval: Duration) { self.interval = interval }
}
