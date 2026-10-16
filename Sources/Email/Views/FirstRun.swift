import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: First run

struct SetupView: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Keymail to Google").font(.scaled(size: 26, weight: .semibold))
            Text("One-time setup, about 5 minutes. Keymail talks to Gmail directly from your Mac; nothing goes through a server.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open console.cloud.google.com, create a project (any name), and select it.")
                step(2, "Search the top bar for **Gmail API** → Enable.")
                step(3, "Search for **Google Auth Platform** → **Get started**. App name: Keymail. Audience: **External**. Add your email as contact → Create.")
                step(4, "Google Auth Platform → **Audience** → Test users → **Add users** → add every Gmail address you'll use.")
                step(5, "Google Auth Platform → **Clients** → **Create client** → type **Desktop app** → Create.")
                step(6, "In the popup, click **Download JSON** and choose it below. Missed it? Paste the Client ID and secret instead.")
            }
            HStack {
                Button("Open Google Cloud Console") { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/auth/overview")!) }.quiet()
                Button("Choose client JSON…") { pick() }.primaryAction()
                Button("Use iCloud Mail instead…") { showICloud = true }.quiet()
            }
            HStack {
                TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder)
                SecureField("Client secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                Button("Save") { save() }.quiet().disabled(clientId.isEmpty || clientSecret.isEmpty)
            }
            if let b = store.banner { Text(b).foregroundStyle(.red) }
        }
        .padding(48).frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(isPresented: $showICloud) { ICloudSheet() }
    }
    func step(_ n: Int, _ s: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.scaled(.callout).monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
            Text(s)
        }
    }
    func save() {
        let json = ["installed": ["client_id": clientId.trimmingCharacters(in: .whitespaces), "client_secret": clientSecret.trimmingCharacters(in: .whitespaces)]]
        try? JSONSerialization.data(withJSONObject: json).write(to: GoogleClient.file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: GoogleClient.file.path)
        store.hasClient = GoogleClient.load() != nil
    }

    func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? FileManager.default.removeItem(at: GoogleClient.file)
        try? FileManager.default.copyItem(at: url, to: GoogleClient.file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: GoogleClient.file.path)
        store.hasClient = GoogleClient.load() != nil
        if !store.hasClient { store.banner = "That file doesn't look like a Google OAuth client JSON." }
    }
}

struct SignInView: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    var body: some View {
        VStack(spacing: 16) {
            Text("Keymail").font(.scaled(size: 34, weight: .semibold))
            Text("Fast, keyboard-first Gmail.").foregroundStyle(.secondary)
            Button { store.addAccount() } label: { Text("Sign in with Google").padding(.horizontal, 12).padding(.vertical, 4) }
                .primaryAction().keyboardShortcut(.defaultAction)
            Button("Add iCloud Mail instead…") { showICloud = true }.quiet()
            if let b = store.busy { Text(b).foregroundStyle(.secondary) }
            if let b = store.banner { Text(b).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(isPresented: $showICloud) { ICloudSheet() }
    }
}
