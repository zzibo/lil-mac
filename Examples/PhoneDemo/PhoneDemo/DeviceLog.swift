import Foundation
import LilMac

/// Append-only `Documents/lilmac-device.log`: one ISO timestamp and message per line.
enum DeviceLog {
    static let url = URL.documentsDirectory.appending(path: "lilmac-device.log")
    private static let lock = NSLock()

    static func write(_ message: String) {
        let line = Data("\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(message)\n".utf8)
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    static func describe(_ event: AgentEvent) -> String {
        switch event {
        case .text(let text): "text \(text.prefix(80))"
        case .action(let call): "action \(call.name) \(call.argumentsJSON)"
        case .toolStarted(let call): "toolStarted \(call.name)"
        case .toolResult(let call, _): "toolResult \(call.name)"
        case .checkpoint: "checkpoint"
        case .done: "done"
        case .budgetExhausted: "budgetExhausted"
        }
    }
}
