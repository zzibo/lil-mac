import LilMacRuntime
import SwiftUI

struct HeartbeatView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("foregroundSeconds") private var seconds = 30
    @State private var readings: [(name: String, value: String?)] = []

    var body: some View {
        List {
            Section("Sensors") {
                ForEach(readings, id: \.name) { reading in
                    LabeledContent(reading.name, value: reading.value ?? "none")
                }
            }
            Section("Settings") {
                Stepper("Foreground interval: \(seconds) s", value: $seconds, in: 10...120, step: 10)
            }
        }
        .onChange(of: seconds) { model.runner.settings.foregroundInterval = .seconds(seconds) }
        .task {
            while !Task.isCancelled {
                var next: [(name: String, value: String?)] = []
                for sensor in model.sensors { next.append((sensor.name, await sensor.read())) }
                readings = next
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
