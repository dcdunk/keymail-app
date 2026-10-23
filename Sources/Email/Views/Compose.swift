import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Compose

struct ComposeView: View {
    @AppStorage("draftButtons") private var draftButtons = "icons"   // "icons" or "text"
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
                        if store.state.accounts.count > 1 {
                            Circle().fill(store.accountColor(store.account(of: model.draft))).frame(width: 7, height: 7)
                        }
                        Text(store.fullLabel(model.draft.from, account: store.account(of: model.draft))).lineLimit(1)
                        Image(systemName: "chevron.down").font(.scaled(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor().fixedSize()
                .keyboardShortcut("f", modifiers: [.command, .shift]).help("Send from (⇧⌘F)")
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.scaled(size: 12, weight: .semibold)).frame(width: 30, height: 26).contentShape(Circle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(model.askClose ? nil : .cancelAction).help("Close (Esc)")
            }
            row("To") {
                RecipientChips(text: $model.draft.to, placeholder: "Recipients", focus: $focus, field: .to, complete: complete)
                if !showCc { linkButton("Cc") { showCc = true; focus = .cc }.help("Add Cc (⇧⌘C)") }
                if !showBcc { linkButton("Bcc") { showBcc = true; focus = .bcc }.help("Add Bcc (⇧⌘B)") }
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
                .textFieldStyle(.plain).font(.scaled(size: 19, weight: .semibold))
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)

            TextEditor(text: $model.draft.body)
                .font(.scaled(size: 15)).lineSpacing(3).scrollContentBackground(.hidden)
                .focused($bodyFocused).padding(.horizontal, 19).padding(.vertical, 6)
                .frame(minHeight: 140)
                .onAppear {
                    showCc = !model.draft.cc.isEmpty; showBcc = !model.draft.bcc.isEmpty
                    // New email: start in To. Reply or forward with recipients filled in: start in the message.
                    // Next run loop, so the card's fields exist before focus moves (it opens as an overlay now).
                    let empty = model.draft.to.trimmingCharacters(in: .whitespaces).isEmpty
                    DispatchQueue.main.async { if empty { focus = .to } else { bodyFocused = true } }
                }

            // Keyboard-only shortcuts with no visible button of their own (each mirrors a click target below).
            Group {
                Button("") { showCc = true; focus = .cc }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { showBcc = true; focus = .bcc }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("") { showQuote.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("") { if !model.draft.files.isEmpty { model.draft.files.removeLast() } }.keyboardShortcut(.delete, modifiers: [.command, .option])
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                ComposeSignature(model: model)
                if let q = model.draft.quoted, !q.isEmpty {
                    Button { showQuote.toggle() } label: {
                        Text("•••").font(.scaled(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }.buttonStyle(.plain).handCursor().help(showQuote ? "Hide quoted text (⇧⌘.)" : "Show quoted text (⇧⌘.)")
                    if showQuote {
                        ScrollView { Text(q.trimmingCharacters(in: .newlines)).font(.scaled(.callout)).foregroundStyle(.secondary)
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
                                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove (⌥⌘⌫ removes the last one)")
                                }
                                .font(.scaled(.callout)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.scaled(.callout)).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            toolbar
        }
        // Inside a conversation the card is as tall as what's in it (a big signature, an error line); a fixed height cut
        // off the From row and the Send bar. Its own window keeps the usual size.
        .frame(minWidth: model.inline ? nil : 620, idealWidth: 820, maxWidth: 1100,
               minHeight: model.inline ? nil : 460, idealHeight: model.inline ? nil : 640, maxHeight: model.inline ? nil : 1000)
        // A real macOS dialog on the draft's window: a SwiftUI overlay sat above the text editor, and clicks fell through to it.
        .alert("Save this draft?", isPresented: $model.askClose) {
            Button("Save draft") { saveAndClose() }.keyboardShortcut(.defaultAction)
            Button("Discard", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saved drafts stay in Drafts so you can finish them later.") }
        .background(TextChecking())
        // Save when what you wrote changes. The server's own IDs coming back don't count: for Outlook each save gets a
        // new ID, which re-triggered a save every 2 seconds for as long as the draft was open.
        .onChange(of: model.draft) { old, new in
            var o = old; o.draftId = new.draftId; o.messageId = new.messageId
            if o != new { store.scheduleDraftSave(model) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { attach([url]) } }
                }
            }
            return true
        }
    }

    /// Send with a ▾ for the other ways to send (later, with a reminder); the rest as quiet icons or text links
    /// (Settings → Appearance → Draft buttons).
    var toolbar: some View {
        HStack(spacing: 6) {
            sendButton
            if let d = model.remindDays {
                Button { model.remindDays = nil } label: {
                    Label(d == 7 ? "Remind in 1 week" : "Remind in \(d)d", systemImage: "bell.fill").font(.scaled(.caption))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).help("\(remindLabel). Click to remove.")
            }
            Spacer().frame(width: 10)
            tool("paperclip", model.draft.files.isEmpty ? "Attach" : "Attach (\(model.draft.files.count))", help: "Attach files (⇧⌘A), or drag them in") { pickFiles() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            toolMenu("signature", "Signature", help: "Signature (⇧⌘S)", key: KeyboardShortcut("s", modifiers: [.command, .shift])) {
                [.header("Signature"),
                 MenuEntry(title: "No signature", icon: "minus.circle", checked: model.draft.signaturePlain == nil) { store.applySignature(&model.draft, from: nil) }]
                + store.addressesWithSignatures.map { a in
                    MenuEntry(title: store.label(store.account(for: a)), subtitle: a, letter: store.account(for: a),
                              checked: model.draft.signaturePlain != nil && store.plainSignature(for: a) == model.draft.signaturePlain) {
                        store.applySignature(&model.draft, from: a)
                    }
                }
                + [.divider, MenuEntry(title: "Edit signatures", icon: "pencil") { editSignature() }]
            }
            toolMenu("text.badge.plus", "Snippet", help: "Insert snippet (⇧⌘I)", key: KeyboardShortcut("i", modifiers: [.command, .shift])) {
                [.header("Insert snippet")] + (store.state.snippets.isEmpty
                    ? [MenuEntry(title: "No snippets yet", subtitle: "Add them in Settings → Snippets", icon: "text.badge.plus", disabled: true)]
                    : store.state.snippets.map { s in
                        MenuEntry(title: s.name, subtitle: String(s.body.prefix(40)), icon: "text.quote") {
                            model.draft.body = expand(s.body, recipient: parseAddresses(model.draft.to).first) + model.draft.body
                        }
                    })
            }
            tool(model.busy ? "hourglass" : "sparkles", model.busy ? "Writing…" : "Write",
                 help: "Write with \(store.ai.name) (⌘J). Type a few notes first, e.g. \"yes to Thursday, ask about budget\".") { store.aiDraft(model) }
                .keyboardShortcut("j", modifiers: .command).disabled(model.busy)

            Spacer(minLength: 12)
            if let n = model.savedNote { Text(n).font(.scaled(.caption)).foregroundStyle(.tertiary).lineLimit(1) }
            tool("trash", "Discard", help: "Discard draft (⇧⌘⌫)", iconOnly: true) { discard() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        // Same 24pt inset as the From/To rows: Send lines up with "From", the trash can with the close button.
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }

    /// Send, joined to a ▾ menu with Send later and Remind me if no reply.
    var sendButton: some View {
        HStack(spacing: 1) {
            Button { trySend(at: nil) } label: {
                HStack(spacing: 8) { Text("Send").fontWeight(.semibold); KeyHint("⌘↵") }.padding(.leading, 4)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20))
            MenuButton(width: 280, entries: { sendMenu }) {
                Image(systemName: "chevron.down").font(.scaled(size: 11, weight: .bold)).frame(height: 16)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 20, topTrailingRadius: 20))
            .help("Send later, or remind me if there's no reply (⇧⌘↵)")
        }
        .prominentGlassButton().buttonBorderShape(.roundedRectangle(radius: 0)).controlSize(.large)
        .disabled(model.busy)
    }

    var sendMenu: [MenuEntry] {
        [.header("Send later")] + snoozePresets().map { name, date in
            MenuEntry(title: name, subtitle: date.formatted(.dateTime.weekday(.abbreviated).hour().minute()), icon: "paperplane") { trySend(at: date) }
        }
        + [.divider, .header("Remind me if no reply")]
        + [(nil, "No reminder"), (1, "In 1 day"), (3, "In 3 days"), (7, "In 1 week")].map { (d: Int?, t: String) in
            MenuEntry(title: t, icon: d == nil ? "bell.slash" : "bell", checked: model.remindDays == d) { model.remindDays = d }
        }
    }

    /// Opens Settings → Signatures on the address this draft's signature comes from, over the draft. Closing Settings
    /// returns to the draft with the edited signature in place.
    func editSignature() {
        let fromEmail = parseAddresses(model.draft.from).first?.email ?? model.draft.from
        let address = store.addressesWithSignatures.first { model.draft.signaturePlain != nil && store.plainSignature(for: $0) == model.draft.signaturePlain }
            ?? store.fromAddresses.first { $0.lowercased() == fromEmail.lowercased() } ?? fromEmail
        store.resumeSignature = model.draft.signaturePlain == nil ? nil : (model, address)
        store.signatureFocus = address
        store.openSettings(tab: "signatures")
    }

    /// Send stays clickable: with no recipient it says so instead of looking broken.
    func trySend(at date: Date?) {
        let d = model.draft   // Cc or Bcc alone is a valid email (a Bcc-only announcement)
        guard !(d.to + d.cc + d.bcc).trimmingCharacters(in: .whitespaces).isEmpty else { store.banner = "Add a recipient first."; return }
        if let bad = invalidRecipients(model.draft).first { model.error = "\"\(bad)\" isn't a complete email address."; return }
        send(at: date)
    }

    /// A draft tool in the chosen style: a quiet icon (name and shortcut on hover) or a text link.
    func tool(_ symbol: String, _ title: String, help: String, iconOnly: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(symbol, title, iconOnly: iconOnly) }.buttonStyle(ToolStyle()).help(help)
    }
    func toolMenu(_ symbol: String, _ title: String, help: String, key: KeyboardShortcut? = nil, _ entries: @escaping () -> [MenuEntry]) -> some View {
        MenuButton(width: 280, entries: entries) { toolLabel(symbol, title, iconOnly: false) }.buttonStyle(ToolStyle()).fixedSize().help(help)
            .keyboardShortcut(key)
    }
    @ViewBuilder func toolLabel(_ symbol: String, _ title: String, iconOnly: Bool) -> some View {
        if iconOnly || draftButtons == "icons" {
            Image(systemName: symbol).font(.scaled(size: 15)).frame(width: 30, height: 28).accessibilityLabel(title)
        } else {
            HStack(spacing: 5) { Image(systemName: symbol).font(.scaled(size: 12)); Text(title) }
                .font(.scaled(.callout)).padding(.horizontal, 8).frame(height: 28)
        }
    }

    var remindLabel: String {
        guard let d = model.remindDays else { return "Remind me if no reply" }
        return "Remind me if no reply in \(d == 7 ? "1 week" : "\(d) day\(d == 1 ? "" : "s")")"
    }

    /// Accounts with their send-as aliases grouped underneath.
    var fromEntries: [MenuEntry] {
        var e: [MenuEntry] = [.header("Send from")]
        for a in store.state.accounts {
            e.append(MenuEntry(title: store.label(a), subtitle: store.label(a) == a ? nil : a, letter: a,
                               checked: model.draft.from.lowercased() == a.lowercased() && store.account(of: model.draft) == a) { store.changeFrom(model, to: a, account: a) })
            for al in store.state.aliases[a] ?? [] {
                e.append(MenuEntry(title: al, subtitle: "Alias", icon: "arrow.turn.down.right",
                                   checked: model.draft.from.lowercased() == al.lowercased() && store.account(of: model.draft) == a) { store.changeFrom(model, to: al, account: a) })
            }
        }
        return e
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                content()
            }
            .font(.scaled(size: 14)).padding(.horizontal, 24).padding(.vertical, 6).frame(minHeight: 40)
            Divider().padding(.leading, 24).opacity(0.6)
        }
    }

    func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(.scaled(.callout)).foregroundStyle(.secondary).handCursor()
    }

    /// Closing asks whether to keep the draft. An empty draft just closes.
    func close() {
        if model.draft.isBlank { discard(quietly: true) } else { model.askClose = true }
    }

    /// Saved to Drafts; it reopens from there.
    func saveAndClose() {
        model.saveTask?.cancel()
        let m = model
        Task { await store.saveDraft(m) }
        dismiss()
    }

    func discard(quietly: Bool) {
        if quietly && model.draft.draftId == nil && model.draftMessage == nil { model.saveTask?.cancel(); dismiss(); return }
        discard()
    }


    func discard() {
        store.discardCompose(model)
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
            let acct = store.account(of: model.draft)
            let cap = attachmentLimit(provider: store.isMicrosoft(acct) ? "outlook" : store.isICloud(acct) ? "icloud" : "gmail")
            if attachmentsTooLarge(next, limit: cap.bytes) { model.error = "Attachments are over \(cap.label)."; return }
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
                            .font(.scaled(.callout)).padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
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
            Text("Snippet").font(.scaled(.title2).weight(.semibold))
            TextField("Name", text: $snippet.name)
            TextEditor(text: $snippet.body).font(.scaled(size: 14)).frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            Text("Use {first_name}, {name} or {email} for the first recipient.").font(.scaled(.callout)).foregroundStyle(.secondary)
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

/// Draft tools: no border, a soft wash on hover, so Send is the only filled button in the bar.
struct ToolStyle: ButtonStyle {
    var padded = false   // plain-text buttons need the padding the draft tools build into their labels
    func makeBody(configuration: Configuration) -> some View { ToolBody(configuration: configuration, padded: padded) }
    struct ToolBody: View {
        let configuration: ButtonStyleConfiguration
        let padded: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .padding(.horizontal, padded ? 8 : 0).frame(minHeight: padded ? 28 : nil)
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.07 : 0)))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.5)
                .onHover { hover = $0 }.handCursor()
        }
    }
}
