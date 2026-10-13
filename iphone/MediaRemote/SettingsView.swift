import SwiftUI

enum SettingsKey {
    static let autoConnectLastMac = "autoConnectLastMac"
}

struct SettingsView: View {
    @AppStorage(SettingsKey.autoConnectLastMac) private var autoConnectLastMac = true
    @AppStorage(DeviceName.settingsKey) private var deviceName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-connect to last device", isOn: $autoConnectLastMac)
                } footer: {
                    Text("Automatically connect to the last device when available.")
                }

                Section {
                    TextField(String(DeviceName.modelName), text: $deviceName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Display name")
                } footer: {
                    Text("The name shown in the device list on your Mac.")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
