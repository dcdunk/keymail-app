import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Compose

struct ComposeView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: ComposeModel
    @Environment(\.closeCard) private var dismiss
    @FocusState private var bodyFocused: Bool
    @FocusState private var focus: Field?
    @State private var showQuote = false
    @State private var showCc = false
    @State private var showBcc = false
    enum Field { case to, cc, bcc }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // From + close
            row("From") {
                MenuButton(width: 320, entries: { fromEntries }) {
                    HStack(spacing: 5) {
                        Text(store.fullLabel(model.draft.from)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor().fixedSize()
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Circle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction).help("Close and keep draft (Esc)")
            }
            row("To") {
                RecipientChips(text: $model.draft.to, placeholder: "Recipients", focus: $focus, field: .to, complete: complete)
                if !showCc { linkButton("Cc") { showCc = true; focus = .cc } }
                if !showBcc { linkButton("Bcc") { showBcc = true; focus = .bcc } }
            }
            suggestions(for: model.draft.to, .to) { model.draft.to = $0 }
            if showCc {
                row("Cc") { RecipientChips(text: $model.draft.cc, placeholder: "", focus: $focus, field: .cc, complete: complete) }
                suggestions(for: model.draft.cc, .cc) { model.draft.cc = $0 }
            }
            if showBcc {
                row("Bcc") { RecipientChips(text: $model.draft.bcc, placeholder: "", focus: $focus, field: .bcc, complete: complete) }
                suggestions(for: model.draft.bcc, .bcc) { model.draft.bcc = $0 }
            }
            TextField("Subject", text: $model.draft.subject)
                .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)

            TextEditor(text: $model.draft.body)
                .font(.system(size: 15)).lineSpacing(3).scrollContentBackground(.hidden)
                .focused($bodyFocused).padding(.horizontal, 19).padding(.vertical, 6)
                .frame(minHeight: 140)
                .onAppear {
                    showCc = !model.draft.cc.isEmpty; showBcc = !model.draft.bcc.isEmpty
                    // New email: start in To. Reply or forward with recipients filled in: start in the message.
                    // Next run loop, so the card's fields exist before focus moves (it opens as an overlay now).
                    let empty = model.draft.to.trimmingCharacters(in: .whitespaces).isEmpty
                    DispatchQueue.main.async { if empty { focus = .to } else { bodyFocused = true } }
                }

            VStack(alignment: .leading, spacing: 10) {
                ComposeSignature(model: model)
                if let q = model.draft.quoted, !q.isEmpty {
                    Button { showQuote.toggle() } label: {
                        Text("•••").font(.system(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }.buttonStyle(.plain).handCursor().help(showQuote ? "Hide quoted text" : "Show quoted text")
                    if showQuote {
                        ScrollView { Text(q.trimmingCharacters(in: .newlines)).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 140)
                    }
                }
                if !model.draft.files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.draft.files) { f in
                                HStack(spacing: 6) {
                                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                                    Text(f.name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(f.data.count), countStyle: .file)).foregroundStyle(.tertiary)
                                    Button { model.draft.files.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                                }
                                .font(.callout).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            toolbar
        }
        .frame(minWidth: 620, idealWidth: 820, maxWidth: 1100, minHeight: 460, idealHeight: 640, maxHeight: 1000)
        .background(TextChecking())
        .onChange(of: model.draft) { _, _ in store.scheduleDraftSave(model) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { attach([url]) } }
                }
            }
            return true
        }
    }

    var toolbar: some View {
        HStack(spacing: 6) {
            Button { send(at: nil) } label: {
                HStack(spacing: 8) { Text("Send").fontWeight(.semibold); Text("⌘↵").font(.caption).opacity(0.7) }
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.return, modifiers: .command).prominentGlassButton().controlSize(.large).buttonBorderShape(.capsule)
            .disabled(model.busy || model.draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.trailing, 8)

            pillMenu("clock", "Later", help: "Send later") {
                [.header("Send later")] + snoozePresets().map { name, date in
                    MenuEntry(title: name, subtitle: date.formatted(.dateTime.weekday(.abbreviated).hour().minute()), icon: "paperplane") { send(at: date) }
                }
            }
            pillMenu(model.remindDays == nil ? "bell" : "bell.fill", model.remindDays.map { $0 == 7 ? "1 week" : "\($0)d" } ?? "Remind",
                     help: remindLabel, on: model.remindDays != nil) {
                [.header("Remind me if no reply")] + [(nil, "No reminder"), (1, "In 1 day"), (3, "In 3 days"), (7, "In 1 week")].map { (d: Int?, t: String) in
                    MenuEntry(title: t, icon: d == nil ? "bell.slash" : "bell", checked: model.remindDays == d) { model.remindDays = d }
                }
            }
            pill("paperclip", model.draft.files.isEmpty ? "Attach" : "\(model.draft.files.count)", help: "Attach files (⇧⌘A), or drag them in",
                 on: !model.draft.files.isEmpty) { pickFiles() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            pillMenu("signature", "Signature", help: "Signature", on: model.draft.signaturePlain != nil) {
                [.header("Signature"),
                 MenuEntry(title: "No signature", icon: "minus.circle", checked: model.draft.signaturePlain == nil) { store.applySignature(&model.draft, from: nil) }]
                + store.addressesWithSignatures.map { a in
                    MenuEntry(title: store.label(store.account(for: a)), subtitle: a, letter: store.account(for: a),
                              checked: model.draft.signaturePlain != nil && store.plainSignature(for: a) == model.draft.signaturePlain) {
                        store.applySignature(&model.draft, from: a)
                    }
                }
                + [.divider, MenuEntry(title: "Edit signatures", icon: "pencil") { store.openSettings() }]
            }
            pillMenu("text.badge.plus", "Snippet", help: "Insert snippet") {
                [.header("Insert snippet")] + (store.state.snippets.isEmpty
                    ? [MenuEntry(title: "No snippets yet", subtitle: "Add them in Settings → Snippets", icon: "text.badge.plus", disabled: true)]
                    : store.state.snippets.map { s in
                        MenuEntry(title: s.name, subtitle: String(s.body.prefix(40)), icon: "text.quote") {
                            model.draft.body = expand(s.body, recipient: parseAddresses(model.draft.to).first) + model.draft.body
                        }
                    })
            }
            Button { store.aiDraft(model) } label: {
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    Text(model.busy ? "Writing…" : "Write")
                }.font(.callout).padding(.horizontal, 4)
            }
            .buttonBorderShape(.capsule)
            .keyboardShortcut("j", modifiers: .command).disabled(model.busy)
            .help("Write with \(store.ai.name) (⌘J). Type a few notes first, e.g. \"yes to Thursday, ask about budget\".")

            Spacer(minLength: 12)
            if let n = model.savedNote { Text(n).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            iconButton("trash", help: "Discard draft") { discard() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }

    var remindLabel: String {
        guard let d = model.remindDays else { return "Remind me if no reply" }
        return "Remind me if no reply in \(d == 7 ? "1 week" : "\(d) day\(d == 1 ? "" : "s")")"
    }

    func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }.buttonBorderShape(.circle).help(help)
    }

    /// A capsule button with icon + short label. `on` tints it when a setting is active (reminder set, files attached).
    func pill(_ symbol: String, _ title: String, help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(symbol, title, on: on) }.buttonBorderShape(.capsule).help(help)
    }

    func pillMenu(_ symbol: String, _ title: String, help: String, on: Bool = false, _ entries: @escaping () -> [MenuEntry]) -> some View {
        MenuButton(width: 280, entries: entries) { pillLabel(symbol, title, on: on) }
            .buttonBorderShape(.capsule).fixedSize().help(help)
    }

    /// Accounts with their send-as aliases grouped underneath.
    var fromEntries: [MenuEntry] {
        var e: [MenuEntry] = [.header("Send from")]
        for a in store.state.accounts {
            e.append(MenuEntry(title: store.label(a), subtitle: store.label(a) == a ? nil : a, letter: a,
                               checked: model.draft.from.lowercased() == a.lowercased()) { store.changeFrom(model, to: a) })
            for al in store.state.aliases[a] ?? [] {
                e.append(MenuEntry(title: al, subtitle: "Alias", icon: "arrow.turn.down.right",
                                   checked: model.draft.from.lowercased() == al.lowercased()) { store.changeFrom(model, to: al) })
            }
        }
        return e
    }

    func pillLabel(_ symbol: String, _ title: String, on: Bool) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol); Text(title) }
            .font(.callout).padding(.horizontal, 4)
            .foregroundStyle(on ? Theme.accent : .primary)
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                content()
            }
            .font(.system(size: 14)).padding(.horizontal, 24).padding(.vertical, 6).frame(minHeight: 40)
            Divider().padding(.leading, 24).opacity(0.6)
        }
    }

    func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).handCursor()
    }

    func close() {
        // Closing keeps the draft: it's saved to Drafts and reopens from there.
        model.saveTask?.cancel()
        let m = model
        Task { await store.saveDraft(m) }
        dismiss()
    }

    func discard() {
        model.saveTask?.cancel()
        let d = model.draft
        Task { await store.deleteDraft(d) }
        dismiss()
    }

    func pickFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { attach(p.urls) }
    }

    func attach(_ urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { model.error = "Couldn't read \(url.lastPathComponent)."; continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let next = model.draft.files + [OutgoingFile(name: url.lastPathComponent, mimeType: mime, data: data)]
            if attachmentsTooLarge(next) { model.error = "Attachments are over Gmail's 25 MB limit."; return }
            model.draft.files = next
        }
    }

    /// Keeps the window open until Gmail confirms, so a failed send never loses the draft.
    func send(at date: Date?) {
        model.saveTask?.cancel()
        if let date { store.schedule(model.draft, at: date, remindDays: model.remindDays); dismiss(); return }
        store.sendWithUndo(model.draft, remindDays: model.remindDays) // closes compose; ⌘Z brings it back
    }

    /// Tab: first suggestion for what's being typed, if any.
    func complete(_ text: String) -> String? { matches(text).first.map { completeField(text, with: $0) } }

    func matches(_ text: String) -> [Address] {
        contactSuggestions(currentToken(text), messages: Array(store.messages.values), me: store.me)
    }

    /// People you've emailed, matching what you're typing. Tab takes the first one.
    @ViewBuilder func suggestions(for text: String, _ f: Field, set: @escaping (String) -> Void) -> some View {
        let list = focus == f ? matches(text) : []
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.element.email) { i, a in
                        Button { set(completeField(text, with: a)) } label: {
                            HStack(spacing: 6) {
                                Avatar(address: a, size: 18)
                                Text(a.name.isEmpty ? a.email : a.name).fontWeight(.medium)
                                if !a.name.isEmpty { Text(a.email).foregroundStyle(.secondary) }
                                if i == 0 { Text("⇥").foregroundStyle(.tertiary) }
                            }
                            .font(.callout).padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                            .background(Capsule().fill(i == 0 ? Theme.selection : Color.primary.opacity(0.06)))
                            .contentShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.leading, 78).padding(.trailing, 24).padding(.vertical, 6)
            }
        }
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var store: AppStore
    @State var snippet: Snippet
    @Environment(\.closeCard) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippet").font(.title2.weight(.semibold))
            TextField("Name", text: $snippet.name)
            TextEditor(text: $snippet.body).font(.system(size: 14)).frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            Text("Use {first_name}, {name} or {email} for the first recipient.").font(.callout).foregroundStyle(.secondary)
            HStack {
                if store.state.snippets.contains(where: { $0.id == snippet.id }) {
                    Button("Delete", role: .destructive) { store.state.snippets.removeAll { $0.id == snippet.id }; dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = store.state.snippets.firstIndex(where: { $0.id == snippet.id }) { store.state.snippets[i] = snippet }
                    else { store.state.snippets.append(snippet) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(snippet.name.isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
}
