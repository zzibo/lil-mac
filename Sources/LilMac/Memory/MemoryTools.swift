import Foundation

public struct DefaultMemory: MemoryStore {
    private let files: FileMemory
    private let log: SessionLog

    public init(files: FileMemory, log: SessionLog) {
        self.files = files
        self.log = log
    }

    public static func standard(in directory: URL) throws -> DefaultMemory {
        DefaultMemory(
            files: try FileMemory(directory: directory),
            log: try SessionLog(path: directory.appendingPathComponent("lilmac.sqlite"))
        )
    }

    public func snapshot() async -> String {
        var sections: [String] = []
        for (title, file) in [("Memory", MemoryFile.memory), ("User", .user)] {
            let text = await files.read(file).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sections.append("## \(title)\n\(text)") }
        }
        return sections.joined(separator: "\n\n")
    }

    public func remember(_ text: String, in file: MemoryFile) async throws { try await files.remember(text, in: file) }
    public func replace(_ old: String, with new: String, in file: MemoryFile) async throws {
        try await files.replace(old, with: new, in: file)
    }
    public func search(_ query: String, limit: Int) async throws -> [SessionHit] { try await log.search(query, limit: limit) }
    public func log(_ run: RunRecord) async throws { try await log.log(run) }
}

public struct RememberTool: Tool {
    public struct Args: Codable, Sendable {
        public var text: String
        public var file: String  // "memory" | "user"
        public var replace: String?  // exact existing text to swap for `text` ("" deletes it)
        public init(text: String, file: String, replace: String? = nil) {
            self.text = text
            self.file = file
            self.replace = replace
        }
    }

    public let name = "remember"
    public let description = "Save a short durable fact. file: \"memory\" for notes about the world and your work, \"user\" for facts about the user. To change or delete a saved fact, set replace to its exact text; text is the new wording (empty deletes)."
    public let schema = JSONSchema.object(
        [
            "text": .string(description: "One short fact."),
            "file": .enumeration(["memory", "user"]),
            "replace": .string(description: "Exact existing text to replace with `text`."),
        ],
        required: ["text", "file"]
    )
    public let kind = ToolKind.read
    private let memory: any MemoryStore

    public init(memory: any MemoryStore) { self.memory = memory }

    public func call(_ args: Args) async throws -> String {
        guard let file = MemoryFile(rawValue: args.file) else { return "Error: file must be memory or user." }
        do {
            if let old = args.replace {
                try await memory.replace(old, with: args.text, in: file)
            } else {
                try await memory.remember(args.text, in: file)
            }
            return "Saved."
        } catch MemoryError.full {
            return "Memory full: replace something before adding."
        } catch MemoryError.notFound {
            return "Not found: nothing replaced."
        } catch MemoryError.empty {
            return "Error: text is empty."
        }
    }
}

public struct SearchSessionsTool: Tool {
    public struct Args: Codable, Sendable {
        public var query: String
        public var limit: Int?
        public init(query: String, limit: Int? = nil) {
            self.query = query
            self.limit = limit
        }
    }

    public let name = "search_sessions"
    public let description = "Search past conversations. Returns matching messages, newest first."
    public let schema = JSONSchema.object(
        ["query": .string(description: "Words to look for."), "limit": .integer],
        required: ["query"]
    )
    public let kind = ToolKind.read
    private let memory: any MemoryStore

    public init(memory: any MemoryStore) { self.memory = memory }

    public func call(_ args: Args) async throws -> String {
        let hits = try await memory.search(args.query, limit: args.limit ?? 5)
        if hits.isEmpty { return "No matches." }
        return hits.map { "\($0.date.formatted(.iso8601.year().month().day())) \($0.text)" }.joined(separator: "\n")
    }
}
