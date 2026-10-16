import AppKit
import SwiftUI

struct ClaudeTask: Equatable { var prompt, folder, model, effort: String }

/// Send to Claude Code: pick the project, edit the prompt, choose model and effort, then open a new session.
struct ClaudeTaskCard: View {
    @EnvironmentObject var store: AppStore
    @State var task: ClaudeTask
    @Environment(\.closeCard) private var dismiss
    static let models = [("", "Project default"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
                         ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1")]
    static let efforts = [("", "Default"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandLogo(brand: "claude", size: 20)
                Text("Send to Claude Code").font(.scaled(.title3).weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.scaled(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(ToolStyle()).keyboardShortcut(.cancelAction).help("Close (Esc)")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Button { chooseFolder() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.scaled(size: 13))
                    Text(task.folder.isEmpty ? "Choose a project folder" : (task.folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.scaled(size: 9, weight: .semibold))
                }
                .font(.scaled(.callout)).padding(.horizontal, 8).frame(height: 28)
            }
            .buttonStyle(ToolStyle()).help("The project Claude Code works in (⌘O)").keyboardShortcut("o", modifiers: .command)
            .padding(.horizontal, 12)

            TextEditor(text: $task.prompt).font(.scaled(size: 13)).lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .frame(height: 280)

            HStack(spacing: 4) {
                chip("cpu", Self.models.first { $0.0 == task.model }?.1 ?? "Project default", help: "Model") {
                    Self.models.map { id, name in MenuEntry(title: name, checked: task.model == id) { task.model = id } }
                }
                chip("gauge.with.dots.needle.50percent", task.effort.isEmpty ? "Default effort" : "\(Self.efforts.first { $0.0 == task.effort }?.1 ?? task.effort) effort", help: "Effort") {
                    Self.efforts.map { id, name in MenuEntry(title: name, checked: task.effort == id) { task.effort = id } }
                }
                Spacer(minLength: 12)
                Text("Nothing runs until you press Enter in Claude").font(.scaled(.caption)).foregroundStyle(.tertiary).lineLimit(1)
                Button { store.launchClaudeTask(task) } label: {
                    HStack(spacing: 8) { Text("Open in Claude").fontWeight(.semibold); KeyHint("⌘↵") }.padding(.horizontal, 4)
                }
                .prominentGlassButton().buttonBorderShape(.capsule).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(task.folder.isEmpty || task.prompt.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 640)
        .onAppear { if task.folder.isEmpty { chooseFolder() } }
    }

    /// A quiet menu button, like the draft tools under Compose.
    func chip(_ symbol: String, _ title: String, help: String, _ entries: @escaping () -> [MenuEntry]) -> some View {
        MenuButton(width: 220, entries: entries) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.scaled(size: 12)); Text(title)
                Image(systemName: "chevron.down").font(.scaled(size: 9, weight: .semibold))
            }.font(.scaled(.callout)).padding(.horizontal, 8).frame(height: 28)
        }
        .buttonStyle(ToolStyle()).fixedSize()
        .help("\(help). Saved as this project's default in .claude/settings.local.json, which only you use.")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Pick the project Claude Code should work in."
        if !task.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: task.folder) }
        if panel.runModal() == .OK, let url = panel.url { task.folder = url.path }
    }
}
