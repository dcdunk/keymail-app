import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Settings window (⌘,)

/// Settings, sliding in from the right over the inbox (option C). Always in the view tree and driven by live
/// state, so it glides out and back in instead of popping, and never blocks the inbox's hover once closed.
struct SettingsPanel: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("settingsTab") private var tab = "general"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var showContent = false   // the settings themselves exist only while open or sliding out

    struct Section: Identifiable { let id: String, title: String, icon: String, keywords: String }
    static let sections: [Section] = [
        .init(id: "general", title: "General", icon: "gearshape", keywords: "thread order undo send notifications badge opacity remote images privacy spelling grammar writing auto archive"),
        .init(id: "appearance", title: "Appearance", icon: "textformat.size", keywords: "appearance text font size bigger larger zoom dark light email content opacity glass window card"),
        .init(id: "accounts", title: "Accounts", icon: "person.crop.circle", keywords: "add remove google icloud alias send as nickname default from"),
        .init(id: "gmail", title: "Gmail", icon: "envelope.badge", keywords: "out of office vacation auto reply labels signature sync"),
        .init(id: "ai", title: "AI providers", icon: "sparkles", keywords: "claude codex gemini write summarize instant reply"),
        .init(id: "splits", title: "Split inbox", icon: "rectangle.split.3x1", keywords: "tabs splits important other rules"),
        .init(id: "signatures", title: "Signatures", icon: "signature", keywords: "signature html logo"),
        .init(id: "hotkeys", title: "Hotkeys", icon: "keyboard", keywords: "keyboard shortcuts keys commands customize remap"),
        .init(id: "snippets", title: "Snippets", icon: "text.quote", keywords: "templates snippets canned"),
        .init(id: "about", title: "About", icon: "info.circle", keywords: "version updates privacy help"),
    ]

    var matches: [Section] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Self.sections : Self.sections.filter { ($0.title + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        let open = store.settingsOpen
        // A soft, unhurried glide: critically damped (no bounce), slower out of the gate than the inbox panels.
        let motion: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 1)
        GeometryReader { geo in
            let width = min(760, max(560, geo.size.width * 0.62))
            ZStack(alignment: .trailing) {
                Color.black.opacity(open ? 0.18 : 0).ignoresSafeArea()
                    .onTapGesture { store.settingsOpen = false }
                    .allowsHitTesting(open)
                Group { if showContent { panel } else { Color.clear } }
                    // Closed settings must never hold keyboard focus (an invisible search box would swallow
                    // arrows and Return meant for the inbox).
                    .disabled(!open)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .solidPanel(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18))
                    .shadow(color: .black.opacity(open ? 0.25 : 0), radius: 30, x: -8)
                    .offset(x: open || reduceMotion ? 0 : width + 40)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)
            }
            .animation(motion, value: open)
        }
        .onAppear { showContent = open } // the tree is rebuilt when the text size changes
        .onChange(of: open) { _, isOpen in
            if isOpen { showContent = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if !store.settingsOpen { showContent = false } } }
        }
    }

    var panel: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.scaled(size: 12)).foregroundStyle(.tertiary)
                    TextField("Search settings", text: $query).textFieldStyle(.plain).font(.scaled(size: 13))
                        .onSubmit { if let first = matches.first { tab = first.id } }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .padding(.bottom, 10)
                ForEach(matches) { s in
                    Button { tab = s.id } label: {
                        Label(s.title, systemImage: s.icon).font(.scaled(size: 13, weight: tab == s.id ? .medium : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(tab == s.id ? Theme.selection : .clear))
                            .foregroundStyle(tab == s.id ? Theme.accent : .primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).handCursor()
                }
                if matches.isEmpty { Text("No matches").font(.scaled(.caption)).foregroundStyle(.secondary).padding(.horizontal, 10) }
                Spacer()
                Text("Esc to close").font(.scaled(.caption2)).foregroundStyle(.tertiary).padding(.horizontal, 10)
            }
            .padding(14).padding(.top, 30)
            .frame(width: 190)
            .background(Color.primary.opacity(0.03))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(Self.sections.first { $0.id == tab }?.title ?? "Settings").font(.scaled(size: 20, weight: .semibold))
                    Spacer()
                    Button { store.settingsOpen = false } label: {
                        Image(systemName: "xmark").font(.scaled(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help("Close (Esc)")
                }
                .padding(.horizontal, 24).padding(.top, 38).padding(.bottom, 6)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(tab)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.15), value: tab)
        }
        .glassButtons()
    }

    @ViewBuilder var content: some View {
        switch tab {
        case "appearance": AppearanceSettings()
        case "accounts": AccountsSettings()
        case "gmail": GmailSettings()
        case "ai": AIProviderSettings()
        case "splits": SplitSettingsView(embedded: true)
        case "signatures": SignatureSettings()
        case "hotkeys": HotkeySettings()
        case "snippets": SnippetSettings()
        case "about": AboutSettings()
        default: GeneralSettings()
        }
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("windowOpacity") private var windowOpacity = 0.7
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("emailContentTheme") private var contentTheme = "auto"
    var body: some View {
        Form {
            Picker("Text size", selection: $textScale) {
                ForEach(Font.textSizes, id: \.scale) { Text($0.label).tag($0.scale) }
            }.pickerStyle(.segmented)
            Text("Applies to the whole app and to email bodies. ⌘+ and ⌘− also change it.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
            Picker("Appearance", selection: Binding(get: { store.state.appearance }, set: { store.setAppearance($0) })) {
                Text("Match system").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark")
            }.pickerStyle(.segmented)
            Picker("Email content", selection: $contentTheme) {
                Text("Match app").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
            LabeledContent("Window opacity") {
                HStack {
                    Slider(value: $windowOpacity, in: 0.2...1.0, step: 0.05) { EmptyView() }
                        minimumValueLabel: { Image(systemName: "circle.dotted") } maximumValueLabel: { Image(systemName: "circle.fill") }
                        .frame(maxWidth: 260)
                    Text("\(Int(windowOpacity * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            LabeledContent("Email card opacity") {
                HStack {
                    Slider(value: $cardOpacity, in: 0.2...1.0, step: 0.05) { EmptyView() }
                        minimumValueLabel: { Image(systemName: "circle.dotted") } maximumValueLabel: { Image(systemName: "circle.fill") }
                        .frame(maxWidth: 260)
                    Text("\(Int(cardOpacity * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            Text("Lower values let the glass show through emails. Emails that paint their own white backgrounds stay white in those areas.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("grammar") private var grammar = true
    @AppStorage("autocorrect") private var autocorrect = true
    @AppStorage("smartQuotes") private var smartQuotes = false
    @AppStorage("writingToolsButton") private var writingToolsButton = false
    @AppStorage("threadNewestFirst") private var newestFirst = false
    @AppStorage("notifyMode") private var notifyMode = "important"
    @AppStorage("badgeMode") private var badgeMode = "important"
    @ObservedObject private var notifier = Notifier.shared
    var body: some View {
        Form {
            Picker("Messages in a thread", selection: $newestFirst) {
                Text("Oldest first").tag(false); Text("Newest first").tag(true)
            }.pickerStyle(.segmented)
            Picker("Undo send", selection: $store.state.undoSendSeconds) {
                Text("Off").tag(0); Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("20 seconds").tag(20); Text("30 seconds").tag(30)
            }
            Section("Auto Archive") {
                ForEach(AutoArchiveCategory.allCases) { cat in
                    Toggle(cat.rawValue, isOn: Binding(
                        get: { store.state.autoArchive.contains(cat) },
                        set: { on in
                            if on { store.state.autoArchive.append(cat); if store.state.autoArchiveSince == nil { store.state.autoArchiveSince = Date() } }
                            else { store.state.autoArchive.removeAll { $0 == cat } }
                        }))
                }
                Text("Applies to new mail from when you turn it on. Starred mail and returned reminders are never auto-archived. Find them under ☰ → Auto Archived.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            LabeledContent("Calendar") {
                if store.calendar.authorized { Text("Connected to the Calendar app").foregroundStyle(.secondary) }
                else { Button("Allow calendar access") { Task { _ = await store.calendar.requestAccess() } } }
            }
            Section("Notifications") {
                Picker("Notify me about", selection: $notifyMode) {
                    Text("Important mail").tag("important"); Text("All new mail").tag("all"); Text("Nothing").tag("off")
                }
                .onChange(of: notifyMode) { _, v in if v != "off" { notifier.requestPermission() } }
                Picker("Dock badge counts", selection: $badgeMode) {
                    Text("Unread important").tag("important"); Text("All unread").tag("all"); Text("Nothing").tag("off")
                }
                .onChange(of: badgeMode) { _, v in if v != "off" { notifier.requestPermission() }; notifier.updateBadge() }
                if (notifier.denied && notifyMode != "off") || (notifier.badgeBlocked && badgeMode != "off") {
                    HStack {
                        Text(notifier.denied ? "Notifications are turned off for Keymail in System Settings."
                                             : "Turn on \"Badge app icon\" for Keymail in System Settings → Notifications to see the Dock count.")
                            .font(.scaled(.caption)).foregroundStyle(.orange)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }.controlSize(.small)
                    }
                }
                Button("Send a test notification") { notifier.sendTest() }.controlSize(.small)
                Text("Banners show only while you're in another app. Muted threads never notify. Click a notification to open the email.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            .onAppear { notifier.refreshStatus() }
            Section("Privacy") {
                Toggle("Load remote images", isOn: $loadRemoteImages)
                Text("Senders can use remote images to see when, where and on what device you opened an email. Turning this off blocks all outside content in emails; images attached to the email still show.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Check spelling while typing", isOn: $spellcheck)
                Toggle("Check grammar", isOn: $grammar)
                Toggle("Correct spelling automatically", isOn: $autocorrect)
                Toggle("Smart quotes and dashes", isOn: $smartQuotes)
                Toggle("Show Apple's Writing Tools button while typing", isOn: $writingToolsButton)
                Text("Uses macOS's built-in spelling and grammar checker, in your system language. Right-click an underlined word for suggestions.")
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            LabeledContent("Tips") {
                Button("Show the getting-started tips again") { UserDefaults.standard.set(0, forKey: "coachStep") }
            }
            Toggle("Show folders sidebar", isOn: $store.sidebarOpen)
            Toggle("Show context panel", isOn: $store.contextOpen)
            LabeledContent("Fetch mail") {
                HStack {
                    Text("Every 30 seconds, or ⌘R").foregroundStyle(.secondary)
                    Button("Fetch now") { Task { await store.tick() } }.disabled(store.syncing)
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).padding()
    }
}

struct AccountsSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    @State private var showGoogleSetup = false
    @State private var removing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connected accounts").font(.scaled(.headline))
            if store.state.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(store.state.accounts.enumerated()), id: \.element) { i, acct in
                    let cloud = store.isICloud(acct)
                    HStack(spacing: 12) {
                        BrandLogo(brand: cloud ? "icloud" : "gmail", size: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name (e.g. Work, Personal)", text: Binding(
                                get: { store.state.accountNames[acct] ?? "" },
                                set: { store.state.accountNames[acct] = $0 }))
                                .textFieldStyle(.plain).font(.scaled(.headline))
                            Text("\(acct) · \(cloud ? "iCloud Mail" : "Gmail")").font(.scaled(.caption)).foregroundStyle(.secondary)
                            TextField("Send-as aliases, comma-separated", text: Binding(
                                get: { (store.state.aliases[acct] ?? []).joined(separator: ", ") },
                                set: { store.setAliases($0, for: acct) }))
                                .textFieldStyle(.roundedBorder).font(.scaled(.caption))
                                .help(cloud ? "Aliases from icloud.com → Mail settings → Accounts" : "Must already be set up under Gmail → Settings → Accounts → Send mail as")
                            if !(store.state.aliases[acct] ?? []).isEmpty {
                                Picker("Send from by default", selection: Binding(
                                    get: { store.sendAddress(acct) },
                                    set: { store.state.defaultFrom[acct] = $0 })) {
                                    ForEach([acct] + (store.state.aliases[acct] ?? []), id: \.self) { Text($0).tag($0) }
                                }
                                .font(.scaled(.caption)).fixedSize()
                            }
                        }
                        Spacer()
                        KeyHint("⌘\(i + 1)")
                        Button("Remove") { removing = acct }
                    }.padding(.vertical, 4)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Button { store.addAccount() } label: { Label { Text("Add Google account") } icon: { BrandLogo(brand: "google", size: 14) } }
                    .disabled(!store.hasClient)

                Button { showICloud = true } label: { Label { Text("Add iCloud account") } icon: { BrandLogo(brand: "icloud", size: 14) } }
            }
            if let b = store.busy { Text(b).font(.scaled(.callout)).foregroundStyle(.secondary) }
            if !GoogleClient.isBuiltIn { // developer builds only; customers never see Google Cloud
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GoogleClient.isBuiltIn ? "Google sign-in uses the client built into this app." :
                         store.hasClient ? "Google sign-in uses your own Google Cloud client." : "This build has no Google client.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    Button("Use my own Google Cloud client…") { showGoogleSetup = true }.controlSize(.small)
                }.padding(.top, 4)
            }.font(.scaled(.callout))
            }
            Text("iCloud uses an app-specific password stored in your Keychain.")
                .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .card(isPresented: $showICloud) { ICloudSheet() }
        .card(isPresented: $showGoogleSetup, closeButton: true) { SetupView().frame(width: 520, height: 500) }
        .confirmCard(removing.map { "Remove \($0)?" }, message: "This signs Keymail out of the account and clears its cached mail from this Mac. Nothing is deleted from the server.",
                     confirm: "Remove account", icon: "person.crop.circle.badge.minus", cancel: { removing = nil }) {
            if let r = removing { store.removeAccount(r) }; removing = nil
        }
    }
}

struct SnippetSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: UUID?
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.state.snippets) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.id) }
                }
                HStack {
                    Button { let s = Snippet(name: "New snippet", body: ""); store.state.snippets.append(s); selection = s.id } label: { Image(systemName: "plus") }
                    Button { store.state.snippets.removeAll { $0.id == selection }; selection = nil } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }.controlSize(.small).padding(8)
            }.frame(width: 200)
            Divider()
            if let i = store.state.snippets.firstIndex(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $store.state.snippets[i].name).textFieldStyle(.roundedBorder)
                    TextEditor(text: $store.state.snippets[i].body).font(.scaled(size: 14))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    Text("Use {first_name}, {name} or {email} for the first recipient.").font(.scaled(.callout)).foregroundStyle(.secondary)
                }.padding(16)
            } else {
                Text("Select a snippet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct HotkeySettings: View {
    @State private var overrides = Hotkeys.overrides
    @State private var recording: String?
    @State private var note: String?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                ForEach(Hotkeys.commands, id: \.key) { c in
                    LabeledContent(c.title) {
                        HStack(spacing: 8) {
                            if Hotkeys.key(for: c.key, overrides) != c.key {
                                Button("Reset") { Hotkeys.set(c.key, to: nil); overrides = Hotkeys.overrides }
                                    .buttonStyle(.link).font(.scaled(.caption))
                            }
                            Button { recording == c.key ? stop() : record(c.key) } label: {
                                Text(recording == c.key ? "Press a key…" : Hotkeys.key(for: c.key, overrides).uppercased())
                                    .font(.scaled(size: 14, weight: .semibold, design: .monospaced))
                                    .frame(minWidth: recording == c.key ? 100 : 32, minHeight: 22)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Single-key commands")
                    Spacer()
                    Button("Reset all") { Hotkeys.resetAll(); overrides = [:] }.disabled(overrides.isEmpty)
                }
            } footer: {
                Text(note ?? "Click a key to change it. Esc cancels.").font(.scaled(.caption))
                    .foregroundStyle(note == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            Section("Fixed") {
                ForEach(Hotkeys.fixed, id: \.title) { c in
                    LabeledContent(c.title) {
                        // Same size as the editable keys above, drawn as a flat keycap since these can't be clicked.
                        Text(c.key).font(.scaled(size: 14, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 32, minHeight: 22).padding(.horizontal, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: stop)
    }

    func record(_ command: String) {
        stop()
        recording = command; note = nil; Hotkeys.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Esc cancels
            let key = (e.charactersIgnoringModifiers ?? "").lowercased()
            guard key.count == 1, let ch = key.first, ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol,
                  e.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                note = "Pick a single letter, number or symbol, without ⌘, ⌃ or ⌥."; return nil
            }
            if let other = Hotkeys.owner(of: key, overrides), other != command {
                note = "\(key.uppercased()) is already used by \(Hotkeys.commands.first { $0.key == other }!.title)."; return nil
            }
            Hotkeys.set(command, to: key); overrides = Hotkeys.overrides
            stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; recording = nil; Hotkeys.recording = false
    }
}
