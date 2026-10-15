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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) { BrandLogo(brand: "claude", size: 20); Text("Send to Claude Code") }.font(.scaled(.title3).weight(.semibold))
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(task.folder.isEmpty ? "No project folder" : (task.folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(task.folder.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            TextEditor(text: $task.prompt).font(.scaled(size: 13)).frame(height: 240)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: 16) {
                Picker("Model", selection: $task.model) { ForEach(Self.models, id: \.0) { Text($0.1).tag($0.0) } }.fixedSize()
                Picker("Effort", selection: $task.effort) { ForEach(Self.efforts, id: \.0) { Text($0.1).tag($0.0) } }.fixedSize()
            }
            if !task.model.isEmpty || !task.effort.isEmpty {
                Text("Saved as this project's default in .claude/settings.local.json, which only you use.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Claude opens with this prompt filled in. Nothing runs until you press Enter there.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open in Claude") { store.launchClaudeTask(task) }
                    .keyboardShortcut(.defaultAction).disabled(task.folder.isEmpty || task.prompt.isEmpty)
            }
        }
        .padding(24).frame(width: 620)
        .onAppear { if task.folder.isEmpty { chooseFolder() } }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Pick the project Claude Code should work in."
        if !task.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: task.folder) }
        if panel.runModal() == .OK, let url = panel.url { task.folder = url.path }
    }
}
