import Foundation
import Testing
@testable import LilMac

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lilmac-\(UUID().uuidString)")
}

private func run(_ id: String, _ daysAgo: Double, _ texts: [String]) -> RunRecord {
    RunRecord(
        id: id,
        date: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
        messages: texts.map { .user($0) },
        usage: .zero
    )
}

@Test func rememberAppendsUnderCap() async throws {
    let memory = try FileMemory(directory: tempDir())
    try await memory.remember("likes tea", in: .memory)
    try await memory.remember("lives in Singapore", in: .memory)
    #expect(await memory.read(.memory) == "- likes tea\n- lives in Singapore\n")
    #expect(await memory.read(.user) == "")
}

@Test func overCapThrowsFullAndLeavesFileUnchanged() async throws {
    let dir = tempDir()
    let memory = try FileMemory(directory: dir, memoryCap: 20, userCap: 20)
    try await memory.remember("abcdefgh", in: .memory)  // "- abcdefgh\n" = 11 characters
    let url = dir.appendingPathComponent("MEMORY.md")
    let before = try Data(contentsOf: url)
    await #expect(throws: MemoryError.full(.memory)) {
        try await memory.remember("abcdefgh", in: .memory)  // 22 > 20
    }
    #expect(try Data(contentsOf: url) == before)
}

@Test func replaceSwapsTextAndHonorsCap() async throws {
    let memory = try FileMemory(directory: tempDir(), memoryCap: 20, userCap: 20)
    try await memory.remember("abcdefgh", in: .user)
    try await memory.replace("abcdefgh", with: "xy", in: .user)
    #expect(await memory.read(.user) == "- xy\n")
    await #expect(throws: MemoryError.full(.user)) {
        try await memory.replace("xy", with: String(repeating: "z", count: 30), in: .user)
    }
    #expect(await memory.read(.user) == "- xy\n")
}

@Test func rememberToolReportsFullInsteadOfThrowing() async throws {
    let dir = tempDir()
    let files = try FileMemory(directory: dir, memoryCap: 10, userCap: 10)
    let tool = RememberTool(memory: DefaultMemory(files: files, log: try SessionLog(path: dir.appendingPathComponent("t.sqlite"))))
    #expect(try await tool.call(.init(text: "ok", file: "memory")) == "Saved.")
    #expect(try await tool.call(.init(text: "way too long to fit", file: "memory"))
        == "Memory full: replace something before adding.")
    #expect(try await tool.call(.init(text: "x", file: "nope")) == "Error: file must be memory or user.")
    #expect(tool.name == "remember")
    #expect(tool.kind == .read)
}

@Test func snapshotIncludesNonEmptySectionsOnly() async throws {
    let memory = try DefaultMemory.standard(in: tempDir())
    #expect(await memory.snapshot() == "")
    try await memory.remember("a", in: .memory)
    #expect(await memory.snapshot() == "## Memory\n- a")
    try await memory.remember("b", in: .user)
    #expect(await memory.snapshot() == "## Memory\n- a\n\n## User\n- b")
}

@Test func snapshotUserOnly() async throws {
    let memory = try DefaultMemory.standard(in: tempDir())
    try await memory.remember("b", in: .user)
    #expect(await memory.snapshot() == "## User\n- b")
}

@Test func loggedRunIsFoundBySearch() async throws {
    let memory = try DefaultMemory.standard(in: tempDir())
    try await memory.log(run("r1", 0, ["My manager Boris wants the report", "unrelated"]))
    let hits = try await memory.search("Boris", limit: 5)
    #expect(hits.count == 1)
    #expect(hits[0].runId == "r1")
    #expect(hits[0].text == "My manager Boris wants the report")
    #expect(hits[0].date == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func hostileQueriesDoNotThrow() async throws {
    let log = try SessionLog(path: tempDir().appendingPathExtension("sqlite"))
    try await log.log(run("r1", 0, ["Boris said hi"]))
    for query in [#"Boris "OR ("#, "AND", "NEAR(", "*", "", "   ", #"""#] {
        _ = try await log.search(query, limit: 5)
    }
    #expect(try await log.search(#"Boris "OR ("#, limit: 5).isEmpty)
}

@Test func searchRespectsLimitAndOrdersNewestFirst() async throws {
    let log = try SessionLog(path: tempDir().appendingPathExtension("sqlite"))
    try await log.log(run("old", 10, ["Boris old"]))
    try await log.log(run("new", 0, ["Boris new"]))
    try await log.log(run("mid", 5, ["Boris mid"]))
    #expect(try await log.search("Boris", limit: 10).map(\.runId) == ["new", "mid", "old"])
    #expect(try await log.search("Boris", limit: 2).map(\.runId) == ["new", "mid"])
}

@Test func searchToolFormatsHits() async throws {
    let log = try SessionLog(path: tempDir().appendingPathExtension("sqlite"))
    let tool = SearchSessionsTool(memory: DefaultMemory(files: try FileMemory(directory: tempDir()), log: log))
    #expect(try await tool.call(.init(query: "Boris", limit: nil)) == "No matches.")
    try await log.log(run("r1", 0, ["Boris one"]))
    try await log.log(run("r2", 1, ["Boris two"]))
    try await log.log(run("r3", 2, ["Boris three"]))
    let out = try await tool.call(.init(query: "Boris", limit: 2))
    #expect(out == "2023-11-14 Boris one\n2023-11-13 Boris two")
    #expect(tool.name == "search_sessions")
    #expect(tool.kind == .read)
}

@Test func longMessagesAreTrimmedTo300Characters() async throws {
    let log = try SessionLog(path: tempDir().appendingPathExtension("sqlite"))
    try await log.log(run("r1", 0, ["Boris " + String(repeating: "x", count: 500)]))
    #expect(try await log.search("Boris", limit: 1)[0].text.count == 300)
}

// MARK: - Verifier fixes

private func memoryTool(caps: Int = 2200) throws -> (RememberTool, DefaultMemory, URL) {
    let dir = tempDir()
    let files = try FileMemory(directory: dir, memoryCap: caps, userCap: caps)
    let memory = DefaultMemory(files: files, log: try SessionLog(path: dir.appendingPathComponent("t.sqlite")))
    return (RememberTool(memory: memory), memory, dir)
}

@Test func corruptDatabaseInitThrowsRepeatedlyWithoutCrashing() throws {
    let path = tempDir().appendingPathExtension("sqlite")
    try Data(repeating: 0x41, count: 4096).write(to: path)
    for _ in 0..<200 {
        #expect(throws: (any Error).self) { try SessionLog(path: path) }
    }
}

@Test func twoConnectionsOnOneFileCanWriteConcurrently() async throws {
    let path = tempDir().appendingPathExtension("sqlite")
    let a = try SessionLog(path: path)
    let b = try SessionLog(path: path)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<100 {
            group.addTask { try await (i.isMultiple(of: 2) ? a : b).log(run("r\(i)", Double(i), ["Boris \(i)"])) }
        }
        try await group.waitForAll()
    }
    #expect(try await a.search("Boris", limit: 200).count == 100)
}

@Test func unreadableFileIsNeverOverwritten() async throws {
    let dir = tempDir()
    let memory = try FileMemory(directory: dir)
    let url = dir.appendingPathComponent("MEMORY.md")
    let bad = Data([0xFF, 0xFE, 0x80, 0x41])
    try bad.write(to: url)
    await #expect(throws: (any Error).self) { try await memory.remember("x", in: .memory) }
    await #expect(throws: (any Error).self) { try await memory.replace("A", with: "B", in: .memory) }
    #expect(try Data(contentsOf: url) == bad)
}

@Test func replaceWithMissingTextWritesNothing() async throws {
    let dir = tempDir()
    let memory = try FileMemory(directory: dir)
    await #expect(throws: MemoryError.notFound) { try await memory.replace("nope", with: "x", in: .user) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("USER.md").path))
    try await memory.remember("a", in: .user)
    let before = await memory.read(.user)
    await #expect(throws: MemoryError.notFound) { try await memory.replace("nope", with: "x", in: .user) }
    #expect(await memory.read(.user) == before)
}

@Test func rememberToolReplacesAndDeletes() async throws {
    let (tool, memory, _) = try memoryTool()
    _ = try await tool.call(.init(text: "likes tea", file: "user"))
    _ = try await tool.call(.init(text: "lives in Paris", file: "user"))
    #expect(try await tool.call(.init(text: "likes coffee", file: "user", replace: "likes tea")) == "Saved.")
    #expect(await memory.snapshot() == "## User\n- likes coffee\n- lives in Paris")
    #expect(try await tool.call(.init(text: "", file: "user", replace: "lives in Paris")) == "Saved.")
    #expect(await memory.snapshot() == "## User\n- likes coffee")
    #expect(try await tool.call(.init(text: "x", file: "user", replace: "absent")) == "Not found: nothing replaced.")
}

@Test func rememberToolReplaceHonorsCap() async throws {
    let (tool, memory, _) = try memoryTool(caps: 20)
    _ = try await tool.call(.init(text: "abcdefgh", file: "memory"))
    #expect(try await tool.call(.init(text: String(repeating: "z", count: 30), file: "memory", replace: "abcdefgh"))
        == "Memory full: replace something before adding.")
    #expect(await memory.snapshot() == "## Memory\n- abcdefgh")
}

@Test func storesWithoutReplaceSupportThrow() async throws {
    struct Bare: MemoryStore {
        func snapshot() async -> String { "" }
        func remember(_ text: String, in file: MemoryFile) async throws {}
        func search(_ query: String, limit: Int) async throws -> [SessionHit] { [] }
        func log(_ run: RunRecord) async throws {}
    }
    await #expect(throws: (any Error).self) { try await Bare().replace("a", with: "b", in: .memory) }
}

@Test func rememberCleansText() async throws {
    let (tool, memory, dir) = try memoryTool()
    #expect(try await tool.call(.init(text: " \n ", file: "memory")) == "Error: text is empty.")
    #expect(try await tool.call(.init(text: "\0\0", file: "memory")) == "Error: text is empty.")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("MEMORY.md").path))
    #expect(try await tool.call(.init(text: "line1\nline2\r\nli\0ne3", file: "memory")) == "Saved.")
    #expect(await memory.snapshot() == "## Memory\n- line1 line2  line3")
}

@Test func nulIsStrippedFromLogsAndQueries() async throws {
    let log = try SessionLog(path: tempDir().appendingPathExtension("sqlite"))
    try await log.log(run("r1", 0, ["Bo\0ris said hi"]))
    #expect(try await log.search("Bor\0is", limit: 5).map(\.text) == ["Boris said hi"])
}
