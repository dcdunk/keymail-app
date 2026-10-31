import SwiftUI
import EmailCore

/// Settings → Packages: your own tracking server (karrio) for live carrier status. Off unless filled in.
struct PackagesSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("trackingServer") private var server = ""
    @State private var key = ""
    @State private var saved = Keychain.get(AppStore.trackingKeyAccount) != nil
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Server", text: $server, prompt: Text("https://your-server.ts.net")).settingAnchor("Tracking server")
                SecureField("API key", text: $key, prompt: Text(saved ? "Saved in the Keychain" : "From karrio: Developers → API keys"))
                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Save and test") { saveAndTest() }.disabled(testing || server.isEmpty || (key.isEmpty && !saved))
                    if saved { Button("Remove key") { Keychain.delete(AppStore.trackingKeyAccount); saved = false; result = nil } }
                    Spacer()
                }
                if let result { Text(result).font(.scaled(.caption)).foregroundStyle(.secondary) }
            } header: { Text("Live tracking") } footer: {
                Text("Optional. With your own karrio server, Keymail asks it for the carrier's live status of packages on the way, about every 30 minutes. Only the carrier and tracking number are sent, and only to this server. Amazon packages keep using Amazon's emails.").settingsFooter()
            }
            if let note = store.trackingServerNote {
                Section("Last check") { Text(note).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
    }

    func saveAndTest() {
        if !key.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.set(key.trimmingCharacters(in: .whitespaces), for: AppStore.trackingKeyAccount); saved = true; key = ""
        }
        testing = true
        Task {
            result = await store.testTrackingServer()
            testing = false
            await store.refreshLiveTracking(force: true)
        }
    }
}
