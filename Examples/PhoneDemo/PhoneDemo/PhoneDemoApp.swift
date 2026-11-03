import EventKit
import LilMac
import LilMacRuntime
import SwiftUI
import UserNotifications

/// Shows notifications as banners while the app is open.
final class Presenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

struct Lookup: Tool {
    struct Args: Codable, Sendable { var topic: String }
    let name = "lookup"
    let description = "Look up a fact about a topic."
    let kind = ToolKind.read
    let schema = JSONSchema.object(["topic": .string(description: "What to look up.")], required: ["topic"])
    func call(_ args: Args) async throws -> String { "Fact about \(args.topic): Lil Mac runs agents inside an iPhone app." }
}

struct SaveNote: Tool {
    struct Args: Codable, Sendable { var title: String }
    let name = "save_note"
    let description = "Offer to save a note. The user taps to confirm."
    let kind = ToolKind.action
    let schema = JSONSchema.object(["title": .string(description: "The note.")], required: ["title"])
    func call(_ args: Args) async throws -> String { "" }
}

@MainActor @Observable
final class AppModel {
    let apiKey: String?
    let runner: PhoneRunner
    let store: JobStore
    let sensors: [any Sensor]
    let chat = ChatModel()
    let deviceTest: DeviceTest
    private let presenter = Presenter()

    init() {
        let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
        let key = env?.isEmpty == false ? env : nil
        apiKey = key
        let arguments = ProcessInfo.processInfo.arguments
        DeviceLog.write("app launch arguments: \(arguments.dropFirst().joined(separator: " "))")
        if arguments.contains("-LilMacLeaveTest") { DemoBrain.current = .fake }  // saved, so a later resume uses it too
        // Read at call time: the picker applies to agents the scheduler, heartbeat and chat build later.
        @Sendable func provider() -> any Provider { DemoBrain.current.provider(apiKey: key) }
        // The Apple model is text only and rejects tools.
        @Sendable func tools(_ tools: [AnyTool]) -> [AnyTool] { DemoBrain.current == .apple ? [] : tools }

        let directory = URL.applicationSupportDirectory.appending(path: "LilMac", directoryHint: .isDirectory)
        let path = directory.appending(path: "lilmac.sqlite")
        let installed = (try? FileManager.default.attributesOfItem(atPath: URL.documentsDirectory.path))?[.creationDate] as? Date
        sensors = [EventSoon(), TimeSince(label: "Installed", date: { installed })]
        let notifier = LocalNotifier()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try JobStore(path: path)
            let scheduler = Scheduler(store: store, notifier: notifier) { job in
                Agent(
                    provider: provider(), system: "You write short briefs for the user.",
                    toolset: Toolset(name: job.toolset, tools: []), budget: job.budget)
            }
            let heartbeat = try Heartbeat(path: path, sensors: sensors, notifier: notifier) {
                Agent(
                    provider: provider(), system: "You watch the user's context. Reply HOLD unless something needs them.",
                    toolset: Toolset(name: "heartbeat", tools: tools([AnyTool(NotifyTool())])), budget: 4)
            }
            var settings = PhoneRunner.Settings()
            let saved = UserDefaults.standard.integer(forKey: "foregroundSeconds")
            if saved > 0 { settings.foregroundInterval = .seconds(saved) }
            runner = PhoneRunner(
                refreshID: "dev.lilmac.demo.refresh", store: store, scheduler: scheduler, heartbeat: heartbeat,
                settings: settings
            ) { toolset in
                Agent(
                    provider: provider(), system: "You are a brief assistant. Use lookup for facts and save_note to offer a note.",
                    toolset: Toolset(name: toolset, tools: tools([AnyTool(Lookup()), AnyTool(SaveNote())])))
            }
        } catch {
            fatalError("Storage failed: \(error)")
        }
        runner.register()  // before launch finishes
        UNUserNotificationCenter.current().delegate = presenter
        let chat = chat
        runner.onResumed = {
            DeviceLog.write("resumed: \(DeviceLog.describe($0))")
            chat.handle($0)
        }
        deviceTest = DeviceTest(runner: runner, store: store)
    }

    /// Asks for permissions, then runs the launch modes from the launch arguments.
    func start() async {
        let arguments = ProcessInfo.processInfo.arguments
        // An unanswered permission alert keeps the scene inactive, so unattended runs skip the prompts.
        let asking = Task { if !arguments.contains("-LilMacNoPrompts") { await requestPermissions() } }
        if let i = arguments.firstIndex(of: "-LilMacLeaveTest"), arguments.indices.contains(i + 1) {
            try? await Task.sleep(for: .seconds(1))
            chat.send(arguments[i + 1] == "veryslow" ? "very slow test" : "slow test", runner: runner)
        }
        guard arguments.contains("-LilMacSelfTest") else { return await asking.value }
        // Wait for the prompts to be answered, but not forever: nobody may tap them.
        for _ in 0..<60 {
            let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if notifications != .notDetermined && EKEventStore.authorizationStatus(for: .event) != .notDetermined { break }
            try? await Task.sleep(for: .seconds(1))
        }
        await deviceTest.run()
    }

    func requestPermissions() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        _ = try? await EKEventStore().requestFullAccessToEvents()
    }
}

@main
struct PhoneDemoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView().tabItem { Label("Chat", systemImage: "bubble.left") }
                JobsView().tabItem { Label("Jobs", systemImage: "clock") }
                HeartbeatView().tabItem { Label("Heartbeat", systemImage: "waveform.path.ecg") }
                DeviceTestView().tabItem { Label("Device Test", systemImage: "checklist") }
            }
            .environment(model)
            .task { await model.start() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                DeviceLog.write("scenePhase \(phase)")
                // .inactive also fires for Control Center and alerts; only .background means the app left.
                if phase == .active { model.runner.onAppActive() } else if phase == .background { model.runner.onAppInactive() }
            }
        }
    }
}
