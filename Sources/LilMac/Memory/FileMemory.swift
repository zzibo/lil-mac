import Foundation

public enum MemoryError: Error, Equatable {
    case full(MemoryFile)
    case notFound
    case empty
    case unsupported
}

extension String {
    /// Removes NUL, which SQLite and C strings treat as end-of-text.
    var withoutNUL: String { String(String.UnicodeScalarView(unicodeScalars.filter { $0 != "\0" })) }

    /// One line, no NUL, no leading or trailing whitespace.
    var memoryLine: String {
        String(String.UnicodeScalarView(withoutNUL.unicodeScalars.map { $0 == "\n" || $0 == "\r" ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `MEMORY.md` and `USER.md`, each capped in characters so the prompt snapshot stays small.
public actor FileMemory {
    private let directory: URL
    private let caps: [MemoryFile: Int]

    public init(directory: URL, memoryCap: Int = 2200, userCap: Int = 1375) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        caps = [.memory: memoryCap, .user: userCap]
    }

    /// For display; an unreadable file reads as empty. Writers use `load`, which throws.
    public func read(_ file: MemoryFile) -> String { (try? load(file)) ?? "" }

    public func remember(_ text: String, in file: MemoryFile) throws {
        let line = text.memoryLine
        guard !line.isEmpty else { throw MemoryError.empty }
        try write(load(file) + "- \(line)\n", to: file)
    }

    /// Replaces every occurrence of `old` with `new` (empty `new` deletes, taking the "- " bullet with it).
    /// Throws `.notFound` without writing when `old` is absent.
    public func replace(_ old: String, with new: String, in file: MemoryFile) throws {
        let content = try load(file)
        guard !old.isEmpty, content.contains(old) else { throw MemoryError.notFound }
        let new = new.memoryLine
        let updated = new.isEmpty && content.contains("- \(old)\n")
            ? content.replacingOccurrences(of: "- \(old)\n", with: "")
            : content.replacingOccurrences(of: old, with: new)
        try write(updated, to: file)
    }

    /// A missing file is empty; any other read failure throws so a writer never clobbers what it could not read.
    private func load(_ file: MemoryFile) throws -> String {
        do {
            return try String(contentsOf: url(file), encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        }
    }

    private func write(_ content: String, to file: MemoryFile) throws {
        guard content.count <= caps[file]! else { throw MemoryError.full(file) }
        try Data(content.utf8).write(to: url(file), options: .atomic)
    }

    private func url(_ file: MemoryFile) -> URL {
        directory.appendingPathComponent(file == .memory ? "MEMORY.md" : "USER.md")
    }
}
