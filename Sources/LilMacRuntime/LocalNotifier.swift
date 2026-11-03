import Foundation
import UserNotifications

/// Shows a local notification: at `at` through a time-interval trigger (exact across DST), or now when `at` is nil or past.
/// The host asks for notification permission.
public struct LocalNotifier: Notifier {
    private let add: @Sendable (UNNotificationRequest) async throws -> Void

    public init(
        add: @escaping @Sendable (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }
    ) {
        self.add = add
    }

    public func deliver(_ text: String, at: Date?) async {
        let content = UNMutableNotificationContent()
        content.body = text
        var trigger: UNTimeIntervalNotificationTrigger?
        if let at, at > Date() {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        }
        try? await add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
    }
}
