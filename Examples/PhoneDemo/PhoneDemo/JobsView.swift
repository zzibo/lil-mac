import LilMacRuntime
import SwiftUI
import UserNotifications

struct PendingNotification: Identifiable, Sendable {
    let id: String
    let body: String
    let fires: Date?
}

func pendingNotifications() async -> [PendingNotification] {
    await withCheckedContinuation { continuation in
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            continuation.resume(
                returning: requests.map {
                    PendingNotification(
                        id: $0.identifier, body: $0.content.body,
                        fires: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
                })
        }
    }
}

struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [Job] = []
    @State private var pending: [PendingNotification] = []

    var body: some View {
        List {
            Button("Add brief at next minute (lead 1 min)") { Task { await addBrief() } }
            // The Simulator never stores BG task requests, so this runs the same code the real handler runs.
            Button("Run background refresh now") { Task { await model.runner.runBackgroundRefresh(deadline: .now + 25) } }
            Section("Jobs") {
                ForEach(jobs) { job in
                    VStack(alignment: .leading) {
                        Text(job.id).font(.footnote.monospaced())
                        Text(job.prompt.isEmpty ? "Saved chat" : job.prompt)
                        Text(job.nextRun == .distantFuture ? "Not scheduled" : "Next \(job.nextRun.formatted(.dateTime.hour().minute().second())), lead \(Int(job.lead)) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Pending notifications") {
                ForEach(pending) { request in
                    VStack(alignment: .leading) {
                        Text(request.body).lineLimit(2)
                        Text(request.fires.map { "Fires \($0.formatted(.dateTime.hour().minute().second()))" } ?? "Now")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                jobs = (try? await model.store.list()) ?? []
                pending = await pendingNotifications()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func addBrief() async {
        let calendar = Calendar.current
        guard let next = calendar.nextDate(after: .now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) else { return }
        let time = calendar.dateComponents([.hour, .minute], from: next)
        let job = Job(
            id: "brief-\(UUID().uuidString.prefix(8))", schedule: .cron("\(time.minute!) \(time.hour!) * * *"),
            prompt: "Write a one-line brief for the user's morning.", toolset: "brief", lead: 60, nextRun: next)
        try? await model.store.add(job)
    }
}
