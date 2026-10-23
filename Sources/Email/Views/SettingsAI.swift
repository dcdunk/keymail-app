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
    @State private var customizing: Set<String> = []       // providers showing the "Other…" model field
    @AppStorage("readyDrafts") private var readyDrafts = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI providers").font(.scaled(.headline))
            Text("Keymail uses an AI command-line tool that's already signed in on this Mac, billed to that tool's own plan. It runs read-only: email content can only produce text, never run commands or change files.")
                .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { readyDrafts }, set: { on in
                // Turning it on asks once before any email goes to the AI tool, like the other AI features.
                readyDrafts = on && store.aiConsent(store.ai)
                if readyDrafts, !store.state.splits.contains(where: { $0.name == "Needs reply" }),
                   let s = splitLibrary.first(where: { $0.name == "Needs reply" }) { store.state.splits.append(s) }
                if readyDrafts { Task { await store.writeReadyDrafts() } }
            })) {
                Text("Write drafts ahead of time")
                Text("When an email needs your reply, \(store.ai.name) writes one in your style before you open it. It waits under the email with a Draft tag; nothing sends until you press Send. To write it, \(store.ai.name) gets that email, a few of your sent emails from the same account and your busy times. Uses your AI plan for each email that needs a reply.")
            }
            .toggleStyle(.switch).padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04))).settingAnchor("Write drafts ahead of time")
            List {
                ForEach(AIProvider.all) { p in
                    let isOn = store.state.aiProvider == p.id
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isOn ? Theme.accent : .secondary).font(.scaled(.title3))
                            .onTapGesture { store.state.aiProvider = p.id }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                BrandLogo(brand: p.id, size: 18)
                                Text(p.name).font(.scaled(.headline))
                                Text(p.maker).font(.scaled(.caption)).foregroundStyle(.secondary)
                                if isOn { Text("In use").font(.scaled(.caption).weight(.semibold)).foregroundStyle(Theme.accent) }
                            }
                            statusLine(p)
                            if path(p) != nil {
                                modelPicker(p)
                            }
                        }
                        Spacer()
                        if path(p) == nil {
                            Button("Get it") { NSWorkspace.shared.open(URL(string: p.installURL)!) }.quiet()
                        } else {
                            Button(testing == p.id ? "Testing…" : "Test") { test(p) }.quiet().disabled(testing != nil)
                            if !isOn { Button("Use") { store.state.aiProvider = p.id }.quiet() }
                        }
                    }.padding(.vertical, 6)
                }
            }
            Text("Used for: Write with AI (⌘J), Instant reply (Shift R), Summarize (I) and split suggestions.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
        }
        .padding(24)
        .task {
            for p in AIProvider.all where path(p) == nil {
                let path = await Task.detached { AI.binary(p.binary) }.value
                if let path { installed[p.id] = path }
            }
        }
    }

    /// Where the tool is: the usual install folders are checked right here (instant), a login-shell lookup fills in the rest.
    func path(_ p: AIProvider) -> String? { installed[p.id] ?? AI.knownBinary(p.binary) }

    @ViewBuilder func statusLine(_ p: AIProvider) -> some View {
        if let s = status[p.id] {
            Label(s, systemImage: s == "Connected" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.scaled(.caption)).foregroundStyle(s == "Connected" ? .green : .orange).fixedSize(horizontal: false, vertical: true)
        } else if let path = path(p) {
            Text("Installed at \(path) · press Test to check sign-in").font(.scaled(.caption)).foregroundStyle(.secondary)
        } else {
            Text("Not installed").font(.scaled(.caption)).foregroundStyle(.secondary)
        }
    }

    /// Picking a model saves its CLI ID (passed as --model / -m) and runs Test, so a model your plan
    /// doesn't include shows its error right away. "Other…" takes any ID the tool accepts.
    @ViewBuilder func modelPicker(_ p: AIProvider) -> some View {
        let current = store.state.aiModels[p.id] ?? ""
        let known = current.isEmpty || p.models.contains { $0.id == current }
        HStack(spacing: 8) {
            Picker("Model", selection: Binding(
                get: { known && !customizing.contains(p.id) ? current : "other" },
                set: { v in
                    if v == "other" { customizing.insert(p.id); return }
                    customizing.remove(p.id); store.state.aiModels[p.id] = v; test(p)
                })) {
                Text("Default (the tool decides)").tag("")
                ForEach(p.models, id: \.id) { Text($0.name).tag($0.id) }
                Divider()
                Text("Other…").tag("other")
            }
            .font(.scaled(.caption)).fixedSize()
            if !known || customizing.contains(p.id) {
                TextField("Model ID", text: Binding(get: { current }, set: { store.state.aiModels[p.id] = $0 }))
                    .textFieldStyle(.roundedBorder).font(.scaled(.caption)).frame(maxWidth: 200)
                    .onSubmit { test(p) }
            }
        }
    }

    func test(_ p: AIProvider) {
        testing = p.id
        Task {
            let model = store.state.aiModels[p.id]
            let result: String
            do { _ = try await AI.run("Reply with the single word OK.", with: p, model: model); result = "Connected" }
            catch { result = "\(error.localizedDescription) \(p.signInHint)" }
            if store.state.aiModels[p.id] == model { status[p.id] = result } // ignore a test of a model since switched away from
            testing = nil
        }
    }
}
