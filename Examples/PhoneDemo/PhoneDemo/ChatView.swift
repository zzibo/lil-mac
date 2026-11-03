import LilMac
import LilMacRuntime
import SwiftUI

@MainActor @Observable
final class ChatModel {
    struct Item: Identifiable {
        enum Kind { case user, assistant, card }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    var items: [Item] = []
    var busy = false
    private var history: [Message] = []
    private var lastText = ""

    func send(_ text: String, runner: PhoneRunner) {
        items.append(Item(kind: .user, text: text))
        history.append(.user(text))
        busy = true
        let run = runner.protect(history, toolset: "chat") { [self] in handle($0) }
        Task { await run.value; busy = false }
    }

    /// Also receives the events of a chat resumed after iOS cut it off.
    func handle(_ event: AgentEvent) {
        switch event {
        case .text, .action, .done: DeviceLog.write("chat \(DeviceLog.describe(event))")
        default: break
        }
        switch event {
        case .text(let text):
            items.append(Item(kind: .assistant, text: text))
            lastText = text
        case .action(let call): items.append(Item(kind: .card, text: "\(call.name)  \(call.argumentsJSON)"))
        case .checkpoint: lastText = ""  // a step that called tools was not the answer
        case .done: history.append(.assistant(lastText))
        default: break
        }
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @AppStorage(DemoBrain.key) private var brain = DemoBrain.fake

    var body: some View {
        let chat = model.chat
        let needsKey = brain == .openRouter && model.apiKey == nil
        VStack(spacing: 0) {
            Picker("Brain", selection: $brain) {
                ForEach(DemoBrain.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            if brain == .apple {
                Text(appleModelLine()).font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
            }
            if needsKey {
                ContentUnavailableView(
                    "Set OPENROUTER_API_KEY", systemImage: "key",
                    description: Text("Add it to the scheme's environment variables, then run again."))
            } else {
                List(chat.items) { item in
                    switch item.kind {
                    case .user: Text(item.text).frame(maxWidth: .infinity, alignment: .trailing)
                    case .assistant: Text(item.text)
                    case .card:
                        Label(item.text, systemImage: "note.text")
                            .padding(10)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                    }
                }
                .listStyle(.plain)
            }
            HStack {
                TextField("Message", text: $draft).textFieldStyle(.roundedBorder)
                Button("Send") {
                    chat.send(draft, runner: model.runner)
                    draft = ""
                }
                .disabled(needsKey || chat.busy || draft.isEmpty)
            }
            .padding()
        }
    }
}
