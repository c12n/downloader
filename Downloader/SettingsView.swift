import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.connectionsKey) private var connections: Int = 4
    @AppStorage(AppSettings.maxSimultaneousKey) private var maxSimultaneous: Int = 3
    @AppStorage(AppSettings.keepAwakeKey) private var keepAwake: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $connections, in: 1...16) {
                        LabeledContent("Connections per download", value: "\(connections)")
                    }
                    Stepper(value: $maxSimultaneous, in: 1...5) {
                        LabeledContent("Simultaneous downloads", value: "\(maxSimultaneous)")
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    Text("More connections can speed up large files from servers that support range requests. Changes apply to downloads started after the change.")
                }
                Section {
                    Toggle("Keep screen awake while downloading", isOn: $keepAwake)
                } header: {
                    Text("Screen")
                }
                Section {
                    LabeledContent("Version", value: "1.0.0 (1)")
                    Text("Files are saved in the app's Downloads folder and are visible in the Files app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
