import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Paper") {
                    Picker("Default paper", selection: $settings.defaultPaper) {
                        ForEach(PaperType.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Writing") {
                    Toggle("Left-handed", isOn: $settings.leftHanded)
                }
                Section {
                    LabeledContent("Recognition", value: "MyScript · Apple Vision · Claude (spike-gated)")
                    LabeledContent("Privacy", value: "On-device first; cloud only with consent")
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
