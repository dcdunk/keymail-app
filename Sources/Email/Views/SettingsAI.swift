import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Settings → AI Providers

struct AIProviderSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var installed: [String: String] = [:]   // id → path
    @State private var status: [String: String] = [:]      // id → last test result
    @State private var testing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI providers").font(.headline)
            Text("Keymail uses an AI command-line tool that's already signed in on this Mac, billed to that tool's own plan. It runs read-only: email content can only produce text, never run commands or change files.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(AIProvider.all) { p in
                    let isOn = store.state.aiProvider == p.id
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isOn ? Theme.accent : .secondary).font(.title3)
                            .onTapGesture { store.state.aiProvider = p.id }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(p.name).font(.headline)
                                Text(p.maker).font(.caption).foregroundStyle(.secondary)
                                if isOn { Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                            }
                            statusLine(p)
                            if installed[p.id] != nil {
                                TextField("Model (blank = the tool's default)", text: Binding(
                                    get: { store.state.aiModels[p.id] ?? "" },
                                    set: { store.state.aiModels[p.id] = $0 }))
                                    .textFieldStyle(.roundedBorder).font(.caption).frame(maxWidth: 280)
                            }
                        }
                        Spacer()
                        if installed[p.id] == nil {
                            Button("Get it") { NSWorkspace.shared.open(URL(string: p.installURL)!) }
                        } else {
                            Button(testing == p.id ? "Testing…" : "Test") { test(p) }.disabled(testing != nil)
                            if !isOn { Button("Use") { store.state.aiProvider = p.id } }
                        }
                    }.padding(.vertical, 6)
                }
            }
            Text("Used for: Write with AI (⌘J), Instant reply (⇧R), Summarize (I) and split suggestions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .task {
            for p in AIProvider.all {
                let path = await Task.detached { AI.binary(p.binary) }.value
                if let path { installed[p.id] = path }
            }
        }
    }

    @ViewBuilder func statusLine(_ p: AIProvider) -> some View {
        if let s = status[p.id] {
            Label(s, systemImage: s == "Connected" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(s == "Connected" ? .green : .orange).fixedSize(horizontal: false, vertical: true)
        } else if let path = installed[p.id] {
            Text("Installed at \(path) · press Test to check sign-in").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not installed").font(.caption).foregroundStyle(.secondary)
        }
    }

    func test(_ p: AIProvider) {
        testing = p.id
        Task {
            do { _ = try await AI.run("Reply with the single word OK.", with: p, model: store.state.aiModels[p.id]); status[p.id] = "Connected" }
            catch { status[p.id] = "\(error.localizedDescription) \(p.signInHint)" }
            testing = nil
        }
    }
}
