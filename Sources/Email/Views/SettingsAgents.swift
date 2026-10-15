import AppKit
import SwiftUI
import EmailCore

/// Settings → MCP: lets Claude Desktop, Claude Code, Codex, Gemini and other MCP apps use Keymail.
struct AgentSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("agentsEnabled") private var enabled = false
    @AppStorage("agentsTriage") private var triage = false
    @State private var note: String?

    var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keymail-mcp").path }
    var serverName: String { AppFlavor.isDemo ? "keymail-demo" : "keymail" }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Allow AI agents")
                    Text("Agents can read and search your mail, see your calendar, and write drafts for you to review.")
                }.settingAnchor("Allow AI agents")
                Toggle(isOn: $triage) {
                    Text("Let agents triage")
                    Text("Mark done, star, mark read, mute and set reminders.")
                }.disabled(!enabled).settingAnchor("Let agents triage")
                LabeledContent {
                    Text("Always asks you").foregroundStyle(.secondary)
                } label: { Text("Sending"); Text("Agents can only ask. You approve every email in Keymail before it sends.") }
            } header: { Text("Access") } footer: {
                Text("Everything stays on this Mac: agents talk to Keymail directly, and Keymail never shares your passwords or sign-ins. Emails can contain instructions meant to trick AI, so agents are told to treat email text as untrusted.").settingsFooter()
            }

            Section("Connect") {
                setupRow("Claude Desktop", brand: "claude", action: "Add to Claude Desktop") { addToClaudeDesktop() }
                setupRow("Claude Code", brand: "claude", action: "Copy command") { copy("claude mcp add --scope user \(serverName) -- \"\(helper)\"") }
                setupRow("Codex", brand: "codex", action: "Copy command") { copy("codex mcp add \(serverName) -- \"\(helper)\"") }
                setupRow("Gemini CLI", brand: "gemini", action: "Copy command") { copy("gemini mcp add \(serverName) \"\(helper)\"") }
                setupRow("Other MCP apps", brand: nil, action: "Copy path") { copy(helper) }
                if let note { Text(note).font(.scaled(.caption)).foregroundStyle(.secondary) }
            }
            .disabled(!enabled)

            Section {
                if store.agentLog.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(store.agentLog.prefix(30)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(e.ok ? Color.secondary : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.tool.replacingOccurrences(of: "_", with: " ")).font(.scaled(.callout))
                            if !e.detail.isEmpty { Text(e.detail).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Text(e.date.formatted(date: .omitted, time: .shortened)).font(.scaled(.caption)).foregroundStyle(.tertiary)
                    }
                }
            } header: { Text("Activity") } footer: { Text("What agents asked Keymail to do since it opened.").settingsFooter() }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .onChange(of: enabled) { store.updateAgentBridge() }
    }

    func setupRow(_ name: String, brand: String?, action: String, _ run: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(action, action: run).quiet()
        } label: {
            HStack(spacing: 8) {
                if let brand { BrandLogo(brand: brand, size: 16) } else { Image(systemName: "puzzlepiece.extension").frame(width: 16) }
                Text(name)
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        note = "Copied. Paste it into Terminal and press Return."
    }

    /// Adds Keymail to Claude Desktop's MCP servers, keeping every other server and setting in that file.
    func addToClaudeDesktop() {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
        guard let data = claudeDesktopConfig(existing: try? Data(contentsOf: file), name: serverName, command: helper) else {
            note = "Claude Desktop's settings file couldn't be read, so Keymail left it alone. Use Copy path and add it in Claude Desktop → Settings → Developer."
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: file, options: .atomic)) != nil { note = "Added. Quit and reopen Claude Desktop, then ask it about your email." }
        else { note = "Couldn't save Claude Desktop's settings file." }
    }
}
