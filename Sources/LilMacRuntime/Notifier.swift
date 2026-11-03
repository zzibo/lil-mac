import Foundation

/// Delivers a run's result to the user. `at` is when it should appear; nil means now.
public protocol Notifier: Sendable {
    func deliver(_ text: String, at: Date?) async
}
