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
    @State private var highlight: String?    // the setting a search jumped to: scrolled into view and briefly tinted
    @FocusState private var searchFocused: Bool
    @State private var showContent = false   // the settings themselves exist only while open or sliding out

    struct Section: Identifiable { let id: String, title: String, icon: String, group: String, keywords: String; var items: [String] = [] }
    /// Sidebar order, which ↑/↓ also follow. `items` are single settings search can jump to; each is a row marked `.settingAnchor`.
    static let sections: [Section] = [
        .init(id: "general", title: "General", icon: "gearshape", group: "Mail", keywords: "thread order newest oldest top quoted history earlier messages undo send notifications badge remote images sender logos privacy spelling grammar writing auto archive calendar fetch sync tips",
              items: ["Messages in a thread", "Earlier messages in each email", "Show folders sidebar", "Show context panel", "Undo send", "Notify me about", "Dock badge counts",
                      "Load remote images", "Show sender logos", "Check spelling while typing", "Check grammar", "Correct spelling automatically", "Smart quotes and dashes", "Fetch mail", "Calendar"]),
        .init(id: "splits", title: "Inbox", icon: "tray", group: "Mail", keywords: "tabs splits split inbox important other single one inbox focused rules", items: ["Important and Other"]),
        .init(id: "signatures", title: "Signatures", icon: "signature", group: "Mail", keywords: "signature html logo"),
        .init(id: "snippets", title: "Snippets", icon: "text.quote", group: "Mail", keywords: "templates snippets canned"),
        .init(id: "accounts", title: "Accounts", icon: "person.crop.circle", group: "Accounts", keywords: "add remove google icloud microsoft outlook hotmail alias send as nickname default from"),
        .init(id: "gmail", title: "Gmail", icon: "envelope.badge", group: "Accounts", keywords: "out of office vacation auto reply labels signature sync"),
        .init(id: "appearance", title: "Appearance", icon: "textformat.size", group: "Personalize", keywords: "draft compose buttons icons links appearance text font size bigger larger zoom dark light email content opacity glass window card",
              items: ["Text size", "Appearance", "Email content", "Draft buttons", "Window opacity", "Email card opacity"]),
        .init(id: "hotkeys", title: "Hotkeys", icon: "keyboard", group: "Personalize", keywords: "keyboard shortcuts keys commands customize remap"),
        .init(id: "ai", title: "AI providers", icon: "sparkles", group: "Personalize", keywords: "claude codex gemini write summarize instant reply"),
        .init(id: "agents", title: "MCP", icon: "point.3.connected.trianglepath.dotted", group: "Personalize", keywords: "mcp claude desktop chatgpt codex gemini agent connect automation"),
        .init(id: "about", title: "About", icon: "info.circle", group: "", keywords: "version updates privacy help"),
    ]
    static var groups: [(name: String, sections: [Section])] {
        sections.reduce(into: []) { r, s in if r.last?.name == s.group { r[r.count - 1].sections.append(s) } else { r.append((s.group, [s])) } }
    }

    struct Hit: Identifiable { let section: Section; let item: String?; var id: String { section.id + "/" + (item ?? "") } }
    /// A page matches on its title or keywords; a single setting matches on its own name.
    static func search(_ query: String) -> [Hit] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return sections.flatMap { s -> [Hit] in
            if q.isEmpty { return [Hit(section: s, item: nil)] }
            let page = (s.title + " " + s.keywords).lowercased().contains(q) ? [Hit(section: s, item: nil)] : []
            return page + s.items.filter { $0.lowercased().contains(q) }.map { Hit(section: s, item: $0) }
        }
    }

    func jump(_ hit: Hit) {
        tab = hit.section.id
        highlight = nil
        if let item = hit.item { DispatchQueue.main.async { highlight = item } }
    }

    var body: some View {
        let open = store.settingsOpen
        // A soft, unhurried glide: critically damped (no bounce), slower out of the gate than the inbox panels.
        let motion: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 1)
        GeometryReader { geo in
            // Narrow windows: Settings takes the whole window instead of squeezing every section.
            let width = geo.size.width < 960 ? geo.size.width : min(760, max(560, geo.size.width * 0.62))
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
                        .focused($searchFocused)
                        .onSubmit { if let first = Self.search(query).first { jump(first) } }
                    if query.isEmpty { KeyHint("⌘K") }
                    else {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.scaled(size: 12)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if query.isEmpty {
                            ForEach(Self.groups, id: \.name) { g in
                                if !g.name.isEmpty {
                                    Text(g.name).font(.scaled(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                                        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
                                } else { Divider().padding(.vertical, 8).padding(.horizontal, 10) }
                                ForEach(g.sections) { s in row(Hit(section: s, item: nil)) }
                            }
                        } else {
                            let hits = Self.search(query)
                            ForEach(hits) { row($0) }
                            if hits.isEmpty { Text("No matches").font(.scaled(.caption)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6) }
                        }
                    }
                }
                .scrollIndicators(.never)
                Text("↑↓ to move · Esc to close").font(.scaled(.caption2)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 6)
            }
            .padding(14).padding(.top, 30)
            .frame(width: 200)
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
                ScrollViewReader { proxy in
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .environment(\.settingsHighlight, highlight)
                        .onChange(of: highlight) { _, h in
                            guard let h else { return }
                            // Let a newly opened page lay out first, then bring the row into view and fade the tint.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation { proxy.scrollTo(h, anchor: .center) } }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if highlight == h { withAnimation(.easeOut(duration: 0.6)) { highlight = nil } } }
                        }
                }
                .id(tab)
                .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.15), value: tab)
        }
        .glassButtons()
        .onChange(of: store.settingsSearchFocus) { searchFocused = true }
    }

    func row(_ hit: Hit) -> some View {
        let on = tab == hit.section.id && hit.item == nil
        return Button { jump(hit) } label: {
            HStack(spacing: 8) {
                Image(systemName: hit.item == nil ? hit.section.icon : "arrow.turn.down.right").frame(width: 18)
                    .foregroundStyle(on ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.item ?? hit.section.title).lineLimit(1)
                    if hit.item != nil { Text(hit.section.title).font(.scaled(.caption)).foregroundStyle(.secondary) }
                }
            }
            .font(.scaled(size: 13, weight: on ? .medium : .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    @ViewBuilder var content: some View {
        switch tab {
        case "appearance": AppearanceSettings()
        case "accounts": AccountsSettings()
        case "gmail": GmailSettings()
        case "ai": AIProviderSettings()
        case "agents": AgentSettings()
        case "splits": SplitSettingsView(embedded: true)
        case "signatures": SignatureSettings()
        case "hotkeys": HotkeySettings()
        case "snippets": SnippetSettings()
        case "about": AboutSettings()
        default: GeneralSettings()
        }
    }
}

private struct SettingsHighlightKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var settingsHighlight: String? { get { self[SettingsHighlightKey.self] } set { self[SettingsHighlightKey.self] = newValue } }
}

extension View {
    /// A row Settings search can jump to. `title` must match an entry in `SettingsPanel.sections[].items`.
    func settingAnchor(_ title: String) -> some View { modifier(SettingAnchor(title: title)) }
}

extension Text {
    /// Note under a settings card, for text that covers the whole card rather than one row.
    func settingsFooter() -> some View { font(.scaled(.caption)).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
}

struct SettingAnchor: ViewModifier {
    let title: String
    @Environment(\.settingsHighlight) private var highlight
    func body(content: Content) -> some View {
        content.id(title)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.selection).padding(-6).opacity(highlight == title ? 1 : 0))
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("draftButtons") private var draftButtons = "icons"
    @AppStorage("emailButtons") private var emailButtons = "text"
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("windowOpacity") private var windowOpacity = 0.7
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("emailContentTheme") private var contentTheme = "auto"
    var body: some View {
        VStack(spacing: 0) {
            AppearancePreview().padding(.horizontal, 20).padding(.top, 8)
            Form {
                Section("Text") {
                    Picker(selection: $textScale) {
                        ForEach(Font.textSizes, id: \.scale) { Text($0.label).tag($0.scale) }
                    } label: { Text("Text size"); Text("The whole app and email bodies. ⌘+ and ⌘− also work.") }
                    .pickerStyle(.segmented).settingAnchor("Text size")
                }
                Section("Theme") {
                    Picker("Appearance", selection: Binding(get: { store.state.appearance }, set: { store.setAppearance($0) })) {
                        Text("Match system").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark")
                    }.pickerStyle(.segmented).settingAnchor("Appearance")
                    Picker("Email content", selection: $contentTheme) {
                        Text("Match app").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.pickerStyle(.segmented).settingAnchor("Email content")
                }
                Section {
                    opacitySlider("Window opacity", $windowOpacity)
                    opacitySlider("Email card opacity", $cardOpacity)
                } header: { Text("Glass") } footer: {
                    Text("Lower values let the glass show through emails. Emails that paint their own white backgrounds stay white in those areas.").settingsFooter()
                }
                Section("Drafts") {
                    Picker(selection: $draftButtons) {
                        Text("Quiet icons").tag("icons"); Text("Text links").tag("text")
                    } label: { Text("Draft buttons"); Text("Attach, Signature, Snippet and Write under a draft. Send stays as it is.") }
                    .pickerStyle(.segmented).settingAnchor("Draft buttons")
                }
                Section("Emails") {
                    Picker(selection: $emailButtons) {
                        Text("Quiet icons").tag("icons"); Text("Text links").tag("text")
                    } label: { Text("Email buttons"); Text("Reply, Forward, Done and the rest under an open email. Shortcut keys always show.") }
                    .pickerStyle(.segmented).settingAnchor("Email buttons")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }

    func opacitySlider(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0.2...1.0, step: 0.05) { EmptyView() }
                    minimumValueLabel: { Image(systemName: "circle.dotted") } maximumValueLabel: { Image(systemName: "circle.fill") }
                    .frame(maxWidth: 260)
                Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }.settingAnchor(title)
    }
}

/// A sample email that redraws as Appearance settings change, so the effect shows before you close Settings.
struct AppearancePreview: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("draftButtons") private var draftButtons = "icons"
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("emailContentTheme") private var contentTheme = "auto"
    static let sample = "<p>Hi there,</p><p>The Q3 plan is attached. Could you look over the <a href=\"#\">budget section</a> before Thursday?</p><p>Thanks,<br>Maya</p>"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(Theme.chip("Maya")).frame(width: 28, height: 28)
                    .overlay(Text("M").font(.scaled(size: 13, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Maya Rodriguez").font(.scaled(.headline))
                    Text("to me").font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("9:41 AM").font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            EmailWebView(html: Self.sample, padding: "12px 16px", cardOpacity: cardOpacity,
                         dark: contentTheme == "dark" || (contentTheme == "auto" && scheme == .dark))
                .frame(maxHeight: 150).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 14) {
                ForEach([("paperclip", "Attach"), ("signature", "Signature"), ("text.quote", "Snippet"), ("sparkles", "Write")], id: \.1) { icon, label in
                    if draftButtons == "icons" { Image(systemName: icon) } else { Text(label) }
                }
                Spacer()
                Text("Preview").font(.scaled(.caption2)).foregroundStyle(.tertiary)
            }
            .font(.scaled(.callout)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain).accessibilityLabel("Appearance preview")
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("loadRemoteImages") private var loadRemoteImages = false
    @AppStorage("loadSenderLogos") private var loadSenderLogos = true
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("grammar") private var grammar = true
    @AppStorage("autocorrect") private var autocorrect = true
    @AppStorage("smartQuotes") private var smartQuotes = false
    @AppStorage("writingToolsButton") private var writingToolsButton = false
    @AppStorage("threadNewestFirst") private var newestFirst = false
    @AppStorage("showQuotedHistory") private var showQuoted = false
    @AppStorage("notifyMode") private var notifyMode = "important"
    @AppStorage("badgeMode") private var badgeMode = "important"
    @ObservedObject private var notifier = Notifier.shared
    var body: some View {
        Form {
            Section("Reading") {
                Picker(selection: $newestFirst) {
                    Text("Oldest first").tag(false); Text("Newest first").tag(true)
                } label: { Text("Messages in a thread"); Text("How a conversation stacks") }
                .pickerStyle(.segmented).settingAnchor("Messages in a thread")
                Picker(selection: $showQuoted) {
                    Text("Hide").tag(false); Text("Show").tag(true)
                } label: { Text("Earlier messages in each email"); Text("Replies repeat the conversation below them. Hidden shows only what each email added, with ••• to expand.") }
                .pickerStyle(.segmented).settingAnchor("Earlier messages in each email")
                Toggle("Show folders sidebar", isOn: $store.sidebarOpen).settingAnchor("Show folders sidebar")
                Toggle("Show context panel", isOn: $store.contextOpen).settingAnchor("Show context panel")
            }
            Section("Sending") {
                Picker(selection: $store.state.undoSendSeconds) {
                    Text("Off").tag(0); Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("20 seconds").tag(20); Text("30 seconds").tag(30)
                } label: { Text("Undo send"); Text("Holds mail this long before it leaves") }.settingAnchor("Undo send")
            }
            Section {
                ForEach(AutoArchiveCategory.allCases) { cat in
                    Toggle(cat.rawValue, isOn: Binding(
                        get: { store.state.autoArchive.contains(cat) },
                        set: { on in
                            if on { store.state.autoArchive.append(cat); if store.state.autoArchiveSince == nil { store.state.autoArchiveSince = Date() } }
                            else { store.state.autoArchive.removeAll { $0 == cat } }
                        }))
                }
            } header: { Text("Auto Archive") } footer: {
                Text("Applies to new mail from when you turn it on. Starred mail and returned reminders are never auto-archived. Find them under ☰ → Auto Archived.").settingsFooter()
            }
            Section {
                Picker("Notify me about", selection: $notifyMode) {
                    Text("Important mail").tag("important"); Text("All new mail").tag("all"); Text("Nothing").tag("off")
                }
                .settingAnchor("Notify me about")
                .onChange(of: notifyMode) { _, v in if v != "off" { notifier.requestPermission() } }
                Picker("Dock badge counts", selection: $badgeMode) {
                    Text("Unread important").tag("important"); Text("All unread").tag("all"); Text("Nothing").tag("off")
                }
                .settingAnchor("Dock badge counts")
                .onChange(of: badgeMode) { _, v in if v != "off" { notifier.requestPermission() }; notifier.updateBadge() }
                if (notifier.denied && notifyMode != "off") || (notifier.badgeBlocked && badgeMode != "off") {
                    HStack {
                        Text(notifier.denied ? "Notifications are turned off for Keymail in System Settings."
                                             : "Turn on \"Badge app icon\" for Keymail in System Settings → Notifications to see the Dock count.")
                            .font(.scaled(.caption)).foregroundStyle(.orange)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }.quiet()
                    }
                }
                LabeledContent("Try it") { Button("Send a test notification") { notifier.sendTest() }.quiet() }
            } header: { Text("Notifications") } footer: {
                Text("Banners show only while you're in another app. Muted threads never notify. Click a notification to open the email.").settingsFooter()
            }
            .onAppear { notifier.refreshStatus() }
            Section("Privacy") {
                Toggle(isOn: $loadRemoteImages) {
                    Text("Load remote images")
                    Text("Senders can use them to see when, where and on what device you opened an email. Off blocks all outside content; attached images still show, and each email offers Load images.")
                }.settingAnchor("Load remote images")
                Toggle(isOn: $loadSenderLogos) {
                    Text("Show sender logos")
                    Text("Fetches each company's logo from its own website, using only the sender's domain. That site sees your IP address, not the email.")
                }.settingAnchor("Show sender logos")
            }
            Section {
                Toggle("Check spelling while typing", isOn: $spellcheck).settingAnchor("Check spelling while typing")
                Toggle("Check grammar", isOn: $grammar).settingAnchor("Check grammar")
                Toggle("Correct spelling automatically", isOn: $autocorrect).settingAnchor("Correct spelling automatically")
                Toggle("Smart quotes and dashes", isOn: $smartQuotes).settingAnchor("Smart quotes and dashes")
                Toggle("Show Apple's Writing Tools button while typing", isOn: $writingToolsButton)
            } header: { Text("Writing") } footer: {
                Text("Uses macOS's built-in spelling and grammar checker, in your system language. Right-click an underlined word for suggestions.").settingsFooter()
            }
            Section("Sync") {
                LabeledContent {
                    Button("Fetch now") { Task { await store.tick() } }.quiet().disabled(store.syncing)
                } label: { Text("Fetch mail"); Text("Gmail every 15 seconds, other accounts every 30, or ⌘R") }.settingAnchor("Fetch mail")
                LabeledContent {
                    if store.calendar.authorized { Text("Connected to the Calendar app").foregroundStyle(.secondary) }
                    else { Button("Allow calendar access") { Task { _ = await store.calendar.requestAccess() } }.quiet() }
                } label: { Text("Calendar"); Text("For invites and adding events") }.settingAnchor("Calendar")
            }
            Section("Help") {
                LabeledContent("Tips") {
                    Button("Show the getting-started tips again") { UserDefaults.standard.set(0, forKey: "coachStep") }.quiet()
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).padding()
    }
}

struct AccountsSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    @State private var showYahoo = false
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
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                        BrandLogo(brand: store.brand(acct), size: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name (e.g. Work, Personal)", text: Binding(
                                get: { store.state.accountNames[acct] ?? "" },
                                set: { store.state.accountNames[acct] = $0 }))
                                .textFieldStyle(.plain).font(.scaled(.headline))
                            Text("\(acct) · \(store.providerName(acct))").font(.scaled(.caption)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            TextField("Send-as aliases, comma-separated", text: Binding(
                                get: { (store.state.aliases[acct] ?? []).joined(separator: ", ") },
                                set: { store.setAliases($0, for: acct) }))
                                .textFieldStyle(.roundedBorder).font(.scaled(.caption))
                                .help(store.brand(acct) == "yahoo" ? "Must already be set up in Yahoo Mail → Settings → Mailboxes" : cloud ? "Aliases from icloud.com → Mail settings → Accounts" : store.isMicrosoft(acct) ? "Must already be set up in Outlook on the web" : "Must already be set up under Gmail → Settings → Accounts → Send mail as")
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
                        // Icons keep the row usable at any width; the names show on hover.
                        Button { if store.brand(acct) == "yahoo" { showYahoo = true } else if cloud { showICloud = true } else { store.reauthenticate(acct) } } label: {
                            Image(systemName: "arrow.clockwise.circle").font(.scaled(size: 15)).frame(width: 28, height: 28)
                        }.buttonStyle(ToolStyle()).accessibilityLabel("Sign in again")
                            .help(cloud ? "Sign in again: enter a new app-specific password" : "Sign in again: refresh this account's sign-in and permissions. Your mail stays as it is.")
                        Button { removing = acct } label: { Image(systemName: "trash").font(.scaled(size: 14)).frame(width: 28, height: 28) }
                            .buttonStyle(ToolStyle()).foregroundStyle(.red).accessibilityLabel("Remove").help("Remove this account")
                    }.padding(.vertical, 4)
                }
                // Order sets ⌘1, ⌘2… and the account switcher.
                .onMove { store.state.accounts.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 200)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                Button { store.addAccount() } label: { Label { Text("Add Google account") } icon: { BrandLogo(brand: "google", size: 14) } }
                    .disabled(!store.hasClient)

                Button { showICloud = true } label: { Label { Text("Add iCloud account") } icon: { BrandLogo(brand: "icloud", size: 14) } }
                Button { store.connectMicrosoft() } label: { Label { Text("Add Outlook account") } icon: { BrandLogo(brand: "outlook", size: 14) } }
                Button { showYahoo = true } label: { Label { Text("Add Yahoo account") } icon: { BrandLogo(brand: "yahoo", size: 14) } }
            }
            .buttonStyle(ToolStyle(padded: true)).fixedSize(horizontal: false, vertical: true)
            if let b = store.busy { Text(b).font(.scaled(.callout)).foregroundStyle(.secondary) }
            if !GoogleClient.isBuiltIn { // developer builds only; customers never see Google Cloud
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GoogleClient.isBuiltIn ? "Google sign-in uses the client built into this app." :
                         store.hasClient ? "Google sign-in uses your own Google Cloud client." : "This build has no Google client.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    Button("Use my own Google Cloud client…") { showGoogleSetup = true }.quiet().font(.scaled(.callout))
                }.padding(.top, 4)
            }.font(.scaled(.callout))
            }
            Text("iCloud uses an app-specific password stored in your Keychain.")
                .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .card(isPresented: $showICloud) { ICloudSheet() }
        .card(isPresented: $showYahoo) { ICloudSheet(yahoo: true) }
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
            }.frame(width: 160)
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
                                    .quiet().font(.scaled(.caption))
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
                    Button("Reset all") { Hotkeys.resetAll(); overrides = [:] }.quiet().disabled(overrides.isEmpty)
                }
            } footer: {
                Text(note ?? "Click a key to change it. Esc cancels.").font(.scaled(.caption))
                    .foregroundStyle(note == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            Section("Fixed") {
                ForEach(Hotkeys.fixed, id: \.title) { c in
                    LabeledContent(c.title) {
                        // Same size as the editable keys above, drawn as a flat keycap since these can't be clicked.
                        Text(KeyHint.display(c.key)).font(.scaled(size: 14, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 32, minHeight: 22).padding(.horizontal, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    }
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
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

