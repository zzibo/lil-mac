/// Caps how many top-level helpers run at once; the rest wait in order. A cancelled waiter leaves the queue.
public actor DelegateSlots {
    public static let shared = DelegateSlots()
    /// Helpers started by helpers get their own pool: sharing the top pool would deadlock it.
    public static let sharedNested = DelegateSlots()

    private var free: Int
    private var waiting: [(id: Int, resume: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0

    public init(limit: Int = 3) { free = max(1, limit) }

    /// Holds a slot for the duration of `body`, or returns "Error: cancelled" if cancelled while waiting.
    /// The body never throws, so the slot is always released.
    func run(_ body: @Sendable () async -> String) async -> String {
        guard await acquire() else { return "Error: cancelled" }
        let result = await body()
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume.resume(returning: true) }   // hand the slot on
        return result
    }

    private func acquire() async -> Bool {
        if free > 0 {
            free -= 1
            return true
        }
        let id = nextID
        nextID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        if let i = waiting.firstIndex(where: { $0.id == id }) { waiting.remove(at: i).resume.resume(returning: false) }
    }
}

/// Runs a fresh helper agent for one task and returns only its final text.
public struct DelegateTool: Tool {
    public struct Args: Codable, Sendable {
        public var task: String
        public var toolset: String?

        public init(task: String, toolset: String? = nil) {
            self.task = task
            self.toolset = toolset
        }
    }

    public let name = "delegate"
    public let description = "Hand a self-contained task to a helper and get back its final answer. Give it everything it needs: it cannot see this chat."
    public let schema = JSONSchema.object(
        ["task": .string(description: "What the helper should do, with all the context it needs."),
         "toolset": .string(description: "Optional name of the toolset the helper gets.")],
        required: ["task"])
    public let kind = ToolKind.read

    let depth: Int
    let slots: DelegateSlots
    let nestedSlots: DelegateSlots
    let makeAgent: @Sendable (_ toolset: String?, _ depth: Int) -> Agent

    public init(
        depth: Int = 0, slots: DelegateSlots = .shared, nestedSlots: DelegateSlots = .sharedNested,
        makeAgent: @escaping @Sendable (_ toolset: String?, _ depth: Int) -> Agent
    ) {
        self.depth = depth
        self.slots = slots
        self.nestedSlots = nestedSlots
        self.makeAgent = makeAgent
    }

    public func call(_ args: Args) async throws -> String {
        guard depth < 2 else { return "Error: too deep: helpers can't start more helpers here." }
        // At most 3 at once per level. A helper's own helpers use the nested pool; they can't delegate further
        // (depth 2), so neither pool can deadlock.
        let body: @Sendable () async -> String = {
            var last: String?
            do {
                for try await event in makeAgent(args.toolset, depth + 1).run([.user(args.task)]) {
                    switch event {
                    case .text(let text): last = text
                    case .done: return last ?? "Done."
                    case .budgetExhausted: return "Helper ran out of steps. Last note: \(last ?? "")"
                    default: break
                    }
                }
                return last ?? "Done."
            } catch {
                return "Error: \(error)"
            }
        }
        return await (depth == 0 ? slots : nestedSlots).run(body)
    }
}
