import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Split Inbox settings

struct SplitSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    var embedded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if embedded {
                Toggle(isOn: Binding(get: { store.splitImportance }, set: { store.setSplitImportance($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Important and Other").font(.scaled(.headline))
                        Text("Sort the inbox into two tabs. Off shows one inbox with everything, newest first.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).settingAnchor("Important and Other")
                Divider()
            }
            HStack {
                Text("Split Inbox").font(.scaled(.title2).weight(.semibold))
                Spacer()
                Button("Build your own") { store.state.splits.append(Split(name: "New split", query: "")) }.quiet()
                Button { store.suggestSplits() } label: { Label("Suggest with \(store.ai.name)", systemImage: "sparkles") }.quiet()
            }
            Text("Define each split with a search, e.g. `from:hubspot.com OR subject:\"new lead\"`. Also works: to:, cc:, label:, has:attachment, is:unread, is:starred, -term to exclude. Drag to reorder. Aim for 3 to 7.")
                .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($store.state.splits) { $split in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            TextField("Name", text: $split.name).font(.scaled(.headline)).textFieldStyle(.plain)
                            Spacer()
                            Toggle("On", isOn: $split.enabled).toggleStyle(.switch).controlSize(.small)
                            Button(role: .destructive) { store.state.splits.removeAll { $0.id == split.id } } label: { Image(systemName: "trash").frame(width: 26, height: 26) }
                                .buttonStyle(ToolStyle())
                        }
                        TextField(split.query.hasPrefix("is:") ? "" : "Definition, e.g. from:boss@company.com", text: $split.query)
                            .textFieldStyle(.roundedBorder).font(.scaled(.callout, design: .monospaced))
                            .disabled(split.query == "is:reminder" || split.query == "is:team")
                        HStack(spacing: 18) {
                            Toggle("Also show in Important / Other", isOn: $split.alsoInMain)
                            Toggle("Hide when empty", isOn: $split.hideWhenEmpty)
                        }.font(.scaled(.callout)).toggleStyle(.checkbox)
                    }.padding(.vertical, 6)
                }
                .onMove { store.state.splits.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 220)
            let library = splitLibrary.filter { lib in !store.state.splits.contains { $0.name == lib.name } }
            if !library.isEmpty || !store.splitSuggestions.isEmpty {
                Text("Add a split").font(.scaled(.headline))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(library) { lib in Button(lib.name) { store.state.splits.append(lib) } }
                        ForEach(store.splitSuggestions) { sug in
                            Button { store.state.splits.append(sug); store.splitSuggestions.removeAll { $0.id == sug.id } } label: {
                                Label(sug.name, systemImage: "sparkles")
                            }.help(sug.query)
                        }
                    }
                }
            }
            HStack {
                Text("Important and Other are always last.").font(.scaled(.callout)).foregroundStyle(.secondary)
                Spacer()
                if !embedded { Button { dismiss() } label: { HStack(spacing: 8) { Text("Done").fontWeight(.semibold); KeyHint("↩") } }.primaryAction().keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24).frame(width: embedded ? nil : 680, height: embedded ? nil : 620)
        .frame(maxWidth: embedded ? .infinity : nil)
    }
}

/// The selected split tab floats on glass; the rest stay flat text.
struct SelectedGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glass(Capsule(), interactive: true) } else { content }
    }
}
