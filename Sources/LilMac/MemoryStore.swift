import Foundation

public enum MemoryFile: String, Codable, Sendable { case memory, user }

public struct SessionHit: Codable, Sendable, Equatable {
    public var runId: String
    public var text: String
    public var date: Date

    public init(runId: String, text: String, date: Date) {
        self.runId = runId
        self.text = text
        self.date = date
    }
}

public struct RunRecord: Codable, Sendable, Equatable {
    public var id: String
    public var date: Date
    public var messages: [Message]
    public var usage: Usage

    public init(id: String, date: Date, messages: [Message], usage: Usage) {
        self.id = id
        self.date = date
        self.messages = messages
        self.usage = usage
    }
}

public protocol MemoryStore: Sendable {
    func snapshot() async -> String
    func remember(_ text: String, in file: MemoryFile) async throws
    /// Replaces the exact text `old` with `new` (empty `new` deletes it).
    func replace(_ old: String, with new: String, in file: MemoryFile) async throws
    func search(_ query: String, limit: Int) async throws -> [SessionHit]
    func log(_ run: RunRecord) async throws
}

public extension MemoryStore {
    func replace(_ old: String, with new: String, in file: MemoryFile) async throws {
        throw MemoryError.unsupported
    }
}
