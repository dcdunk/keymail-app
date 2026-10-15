import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: iCloud sign-in

struct ICloudSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var aliases = ""
    @State private var error: String?
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add iCloud Mail").font(.title2.weight(.semibold))
            Text("iCloud needs an **app-specific password**, not your Apple Account password. It's saved only in your Mac's Keychain.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Go to account.apple.com → Sign-In and Security → App-Specific Passwords.")
                Text("2. Create one named \"Keymail\" and paste it below.")
            }.font(.callout)
            Button("Open account.apple.com") { NSWorkspace.shared.open(URL(string: "https://account.apple.com/account/manage")!) }
            TextField("Primary iCloud email (you@icloud.com)", text: $email).textFieldStyle(.roundedBorder)
            SecureField("App-specific password (xxxx-xxxx-xxxx-xxxx)", text: $password).textFieldStyle(.roundedBorder)
            TextField("Aliases to send as (optional, comma-separated)", text: $aliases).textFieldStyle(.roundedBorder)
            Text("Sign in with your **primary** iCloud address; aliases can't sign in. Add aliases here to send from them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Checking…" : "Add account") {
                    working = true; error = nil
                    Task {
                        do { try await store.addICloudAccount(email: email, password: password, aliases: aliases); dismiss() }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction).prominentGlassButton()
                .disabled(working || !email.contains("@") || password.count < 8)
            }
        }
        .padding(28).frame(width: 520)
    }
}
