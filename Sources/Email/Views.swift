import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

@main
struct EmailApp: App {
    @StateObject private var store = AppStore()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Lightmail") {
            RootView().environmentObject(store).environmentObject(store.calendar)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear { store.start(); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lightmail") { UserDefaults.standard.set("about", forKey: "settingsTab"); store.openSettings() }
                if Updates.shared.enabled { Button("Check for Updates…") { Updates.shared.check() } }
            }
        }
        Settings { SettingsView().environmentObject(store).environmentObject(store.calendar) }
    }
}

extension View {
    /// Pointing-hand cursor on hover, for anything that behaves like a link.
    func handCursor() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    /// Liquid Glass on macOS 26+, frosted material on older systems.
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background(shape.fill(.regularMaterial))
        }
    }
    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glassProminent).tint(Theme.accent) }
        else { self.buttonStyle(.borderedProminent).tint(Theme.accent) }
    }
    /// Default style for every button and menu inside: Liquid Glass on macOS 26+, bordered before.
    @ViewBuilder func glassButtons() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass).menuStyle(.button).modifier(WindowOpacity()) }
        else { self.buttonStyle(.bordered).menuStyle(.button).modifier(WindowOpacity()) }
    }
    /// For menus and panels that float over the inbox: nearly solid, so the list behind doesn't bleed through.
    func floatingPanel<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
            .background(shape.fill(.ultraThickMaterial))
            .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .clipShape(shape)
    }

    /// Fully opaque panel that ignores the window and card opacity settings, so its text is always readable.
    func solidPanel<S: Shape>(_ shape: S) -> some View {
        let solid = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1) }
        return background(shape.fill(Color(nsColor: solid)))
            .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .clipShape(shape).compositingGroup()
    }

    @ViewBuilder func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

enum Theme {
    static let accent = Color(red: 0.29, green: 0.40, blue: 0.93)
    static let selection = Color(red: 0.29, green: 0.40, blue: 0.93).opacity(0.13)
    static let muted = Color.secondary.opacity(0.75)
    static let chipPalette: [Color] = [.green, .red, .purple, .brown, .blue, .orange, .teal, .pink]
    static func chip(_ name: String) -> Color { chipPalette[paletteIndex(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }, count: chipPalette.count)] }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Group {
            if !store.state.onboarded || store.state.accounts.isEmpty { OnboardingView() }
            else { MainView() }
        }
        .glassButtons()
    }
}

// MARK: First run

struct SetupView: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Lightmail to Google").font(.system(size: 26, weight: .semibold))
            Text("One-time setup, about 5 minutes. Lightmail talks to Gmail directly from your Mac; nothing goes through a server.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open console.cloud.google.com, create a project (any name), and select it.")
                step(2, "Search the top bar for **Gmail API** → Enable.")
                step(3, "Search for **Google Auth Platform** → **Get started**. App name: Lightmail. Audience: **External**. Add your email as contact → Create.")
                step(4, "Google Auth Platform → **Audience** → Test users → **Add users** → add every Gmail address you'll use.")
                step(5, "Google Auth Platform → **Clients** → **Create client** → type **Desktop app** → Create.")
                step(6, "In the popup, click **Download JSON** and choose it below. Missed it? Paste the Client ID and secret instead.")
            }
            HStack {
                Button("Open Google Cloud Console") { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/auth/overview")!) }
                Button("Choose client JSON…") { pick() }.prominentGlassButton()
                Button("Use iCloud Mail instead…") { showICloud = true }
            }
            HStack {
                TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder)
                SecureField("Client secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                Button("Save") { save() }.disabled(clientId.isEmpty || clientSecret.isEmpty)
            }
            if let b = store.banner { Text(b).foregroundStyle(.red) }
        }
        .padding(48).frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(isPresented: $showICloud) { ICloudSheet() }
    }
    func step(_ n: Int, _ s: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
            Text(s)
        }
    }
    func save() {
        let json = ["installed": ["client_id": clientId.trimmingCharacters(in: .whitespaces), "client_secret": clientSecret.trimmingCharacters(in: .whitespaces)]]
        try? JSONSerialization.data(withJSONObject: json).write(to: GoogleClient.file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: GoogleClient.file.path)
        store.hasClient = GoogleClient.load() != nil
    }

    func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? FileManager.default.removeItem(at: GoogleClient.file)
        try? FileManager.default.copyItem(at: url, to: GoogleClient.file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: GoogleClient.file.path)
        store.hasClient = GoogleClient.load() != nil
        if !store.hasClient { store.banner = "That file doesn't look like a Google OAuth client JSON." }
    }
}

struct SignInView: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    var body: some View {
        VStack(spacing: 16) {
            Text("Lightmail").font(.system(size: 34, weight: .semibold))
            Text("Fast, keyboard-first Gmail.").foregroundStyle(.secondary)
            Button { store.addAccount() } label: { Text("Sign in with Google").padding(.horizontal, 12).padding(.vertical, 4) }
                .prominentGlassButton().controlSize(.large)
            Button("Add iCloud Mail instead…") { showICloud = true }.buttonStyle(.link).handCursor()
            if let b = store.busy { Text(b).foregroundStyle(.secondary) }
            if let b = store.banner { Text(b).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(isPresented: $showICloud) { ICloudSheet() }
    }
}

// MARK: Main

/// Window width class: narrow windows tighten up, wide ones keep reading width comfortable.
struct LayoutWidth { var width: CGFloat = 1200
    var compact: Bool { width < 1000 }
    var wide: Bool { width >= 1500 }
    var margin: CGFloat { compact ? 16 : 32 }
}
private struct LayoutWidthKey: EnvironmentKey { static let defaultValue = LayoutWidth() }
extension EnvironmentValues { var layout: LayoutWidth { get { self[LayoutWidthKey.self] } set { self[LayoutWidthKey.self] = newValue } } }

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        GeometryReader { geo in content(LayoutWidth(width: geo.size.width)) }
    }

    func content(_ layout: LayoutWidth) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Header().zIndex(1) // search dropdown must draw above the list below it
                if store.searchFiltersOpen { SearchFilters() }
                if let b = store.banner { BannerView(text: b) { store.banner = nil } }
                if store.threadOpen, let c = store.selected { ThreadView(conversation: c) } else { ListView() }
            }
            // The context panel needs room; narrow windows hide it automatically.
            if store.contextOpen, layout.width >= 1100, let c = store.selected { ContextPanel(conversation: c) }
        }
        .overlay(alignment: .leading) {
            if store.sidebarOpen {
                ZStack(alignment: .leading) {
                    // Click anywhere outside the panel to close it.
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { store.sidebarOpen = false }
                    FolderPanel().transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.sidebarOpen)
        .overlayPreferenceValue(CoachAnchorKey.self) { anchors in
            GeometryReader { proxy in CoachTips(anchors: anchors, proxy: proxy) }
        }
        .environment(\.layout, layout)
        .onAppear { store.openSettingsAction = { openSettings() } }
        .overlay(alignment: .top) { if store.paletteOpen { PaletteView().padding(.top, 90) } }
        .overlay(alignment: .bottom) { StatusBar() }
        .overlay { ModalLayer() }
        .overlay { PopupLayer() }
        .coordinateSpace(name: "main")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.mainFrame = $0 }
        .quickLookPreview($store.previewURL)
    }
}

struct Header: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Button { store.sidebarOpen.toggle() } label: { Image(systemName: "line.3.horizontal").frame(width: 34, height: 34).contentShape(Circle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).glass(Circle(), interactive: true)
                .help("Folders (←)").padding(.trailing, 8)
            if store.searchOpen || (store.folder?.hasPrefix("Search: ") ?? false) {
                TokenSearchBar()
            } else if let f = store.folder {
                HStack(spacing: 10) {
                    Text(f).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("Esc").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .glass(Capsule())
            } else {
                let members = store.tabMembers
                // Narrow windows: tabs scroll sideways instead of squeezing the buttons on the right.
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                ForEach(store.shownTabs, id: \.self) { name in
                    let on = name == store.tabName
                    Button { store.goTab(name) } label: {
                        HStack(spacing: 7) {
                            Text(name).font(.system(size: 15, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.primary : Color.secondary)
                            let n = store.count(name, in: members)
                            if !n.isEmpty { Text(n).font(.system(size: 13)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .modifier(SelectedGlass(on: on))
                        .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Button { store.splitSettingsOpen = true } label: { Image(systemName: "rectangle.split.3x1").frame(width: 34, height: 34).contentShape(Circle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).glass(Circle(), interactive: true)
                    .padding(.leading, 6).help("Edit split inboxes")
                }
                .coachAnchor("tabs")
                }
                .scrollDisabled(!layout.compact)
                .fixedSize(horizontal: !layout.compact, vertical: false)
            }
            Spacer()
            let away = store.vacations.filter { (store.state.activeAccount == nil || $0.key == store.state.activeAccount) && $0.value.isActive() }
            if !away.isEmpty {
                Button { store.openSettings() } label: {
                    Label("Out of office", systemImage: "airplane").font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.orange.opacity(0.12)))
                }.buttonStyle(.plain).handCursor().help("Auto-reply is on for " + away.keys.map(store.label).joined(separator: ", ") + ". Change it in Settings → Gmail.")
            }
            Button { store.compose() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.primary).glass(Circle(), interactive: true)
            .help("New email (C)").coachAnchor("compose")
            // Search button: an entry point for mouse users, and something for the search tip to point at.
            Button { store.searchOpen = true } label: { Image(systemName: "magnifyingglass").frame(width: 34, height: 34).contentShape(Circle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).glass(Circle(), interactive: true)
                .help("Search (/)").coachAnchor("search")
            Button { Task { await store.tick() } } label: {
                Group {
                    if store.syncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 34, height: 34).contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).glass(Circle(), interactive: true)
            .disabled(store.syncing).help("Fetch mail (⌘R)")
            MenuButton(width: 320, trailing: true, entries: { store.accountEntries() }) {
                HStack(spacing: 10) {
                    if store.state.accounts.count > 1 {
                        Circle().fill(Theme.chip(store.state.activeAccount ?? "all")).frame(width: 7, height: 7)
                    }
                    Text(store.state.activeAccount.map(store.label) ?? (store.state.accounts.count > 1 ? "All accounts" : store.state.accounts.first.map(store.label) ?? ""))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .glass(Capsule(), interactive: true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).handCursor().fixedSize()
            .coachAnchor("palette")
        }
        .glassGroup(spacing: 10)
        .padding(.horizontal, layout.margin).padding(.top, 34).padding(.bottom, 12)
    }
}

struct BannerView: View {
    let text: String; let close: () -> Void
    var body: some View {
        HStack {
            Text(text).font(.callout)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glass(RoundedRectangle(cornerRadius: 14), tint: .orange.opacity(0.25))
        .padding(.horizontal, 32).padding(.bottom, 6)
    }
}

struct ListView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    var body: some View {
        let items = store.visible
        let selectedID = store.selected?.id
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.searchResults == nil ? "checkmark.circle" : "magnifyingglass").font(.system(size: 34, weight: .light))
                Text(store.searchResults == nil ? "Inbox zero" : "No results").font(.title3.weight(.medium))
                Text(store.searchResults == nil ? "Nothing left in \(store.tabName)." : "Try a different search.").foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { c in
                            Row(c: c, selected: c.id == selectedID).id(c.id)
                                .coachAnchor(c.id == items.first?.id ? "row" : "")
                                .onTapGesture { store.open(c) }   // one click opens, like Superhuman
                        }
                    }
                    .padding(.horizontal, layout.compact ? 8 : 24).padding(.bottom, 48)
                }
                .onChange(of: store.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }
}

struct Row: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    let c: Conversation
    let selected: Bool
    @State private var hovering = false

    func quick(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button { store.act(on: c, action) } label: {
            Image(systemName: icon).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).handCursor()
    }
    /// Superhuman's dots: blue unread, purple returned reminder, yellow starred.
    var dot: Color {
        if c.isUnread { return Theme.accent }
        if let b = store.state.bumped[c.id], c.latest.date <= b { return .purple }
        if c.isStarred { return .yellow }
        return .clear
    }
    var body: some View {
        let unread = c.isUnread
        let chips = c.labels.compactMap { store.labelNames[$0] }.filter { !$0.hasPrefix("Email/") }.sorted()
        HStack(spacing: 0) {
            Circle().fill(dot).frame(width: 7, height: 7).frame(width: 26)
            HStack(spacing: 6) {
                Text(participantsLabel(c, me: store.me)).lineLimit(1)
                let warnings = senderWarnings(c.latest, known: store.knownContacts)
                if !warnings.isEmpty {
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 11)).foregroundStyle(.orange)
                        .help("Possible phishing: " + warnings.joined(separator: " "))
                }
                if c.messages.count > 1 { Text("\(c.messages.count)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 15, weight: unread ? .semibold : .regular))
            .frame(width: layout.compact ? 170 : 260, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { name in
                    Text(name.lowercased()).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.chip(name))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chip(name).opacity(0.12)))
                }
                Text(c.latest.subject).font(.system(size: 15, weight: unread ? .semibold : .regular)).lineLimit(1).layoutPriority(1)
                Text(c.latest.snippet).font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 16)
            if hovering {
                HStack(spacing: 2) {
                    quick("checkmark", "Done (E)") { store.markDone() }
                    MenuButton(width: 270, trailing: true, entries: { store.remindEntries(c, ifNoReply: false) }) {
                        Image(systemName: "clock").frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).handCursor().fixedSize().help("Remind me (H)")
                    quick(c.isStarred ? "star.fill" : "star", c.isStarred ? "Unstar (S)" : "Star (S)") { store.toggleStar() }
                    quick("trash", "Delete (⌫)") { store.trash() }
                }
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            } else {
                Text(shortDate(c.latest.date)).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .trailing)
            }
        }
        .padding(.vertical, 15).padding(.trailing, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.selection : hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { store.rightClickTarget = c } else if store.rightClickTarget?.id == c.id { store.rightClickTarget = nil }
        }
    }
}

// MARK: Menu contents

extension AppStore {
    func remindEntries(_ c: Conversation, ifNoReply: Bool) -> [MenuEntry] {
        [.header(ifNoReply ? "Remind me if no reply" : "Remind me")] + snoozePresets().map { name, date in
            MenuEntry(title: name, subtitle: date.formatted(.dateTime.weekday(.abbreviated).hour().minute()), icon: "clock") {
                self.act(on: c) { self.remind(until: date, ifNoReply: ifNoReply) }
            }
        }
    }

    /// Right-click menu for an email: everything the keyboard can do.
    func conversationEntries(_ c: Conversation) -> [MenuEntry] {
        var e: [MenuEntry] = [
            MenuEntry(title: "Open", icon: "envelope.open", key: "↵") { self.open(c) },
            .divider,
            MenuEntry(title: "Reply", icon: "arrowshape.turn.up.left", key: "R") { self.act(on: c) { self.reply(all: false) } },
            MenuEntry(title: "Reply all", icon: "arrowshape.turn.up.left.2", key: "A") { self.act(on: c) { self.reply(all: true) } },
            MenuEntry(title: "Forward", icon: "arrowshape.turn.up.right", key: "F") { self.act(on: c) { self.forward() } },
            .divider,
            MenuEntry(title: "Mark done", icon: "checkmark", key: "E") { self.act(on: c) { self.markDone() } },
            MenuEntry(title: c.isStarred ? "Unstar" : "Star", icon: c.isStarred ? "star.slash" : "star", key: "S") { self.act(on: c) { self.toggleStar() } },
            MenuEntry(title: c.isUnread ? "Mark as read" : "Mark as unread", icon: c.isUnread ? "envelope.open" : "envelope.badge", key: "U") { self.act(on: c) { self.toggleUnread() } },
            MenuEntry(title: "Remind me", icon: "clock", key: "H",
                      submenu: remindEntries(c, ifNoReply: true) + [.divider] + remindEntries(c, ifNoReply: false)),
            MenuEntry(title: state.muted.contains(c.id) ? "Unmute" : "Mute", icon: state.muted.contains(c.id) ? "bell" : "bell.slash", key: "⇧M") { self.act(on: c) { self.toggleMute() } },
        ]
        if !isICloud(c.account), let labels = gmailLabels[c.account], !labels.isEmpty {
            e.append(MenuEntry(title: "Label", icon: "tag", key: "L", submenu: labels.map { l in
                MenuEntry(title: l.name, icon: "tag", checked: c.labels.contains(l.id)) { self.setLabel(l.id, on: c, !c.labels.contains(l.id)) }
            }))
        }
        let important = isImportant(c, context(allConversations))
        e += [.divider, MenuEntry(title: "Move to \(important ? "Other" : "Important")", icon: important ? "tray" : "exclamationmark.circle") { self.setImportance(c.id, important: !important) }]
        if !c.latest.listUnsubscribe.isEmpty { e.append(MenuEntry(title: "Unsubscribe", icon: "hand.raised", key: "⇧U") { self.act(on: c) { self.unsubscribe() } }) }
        e += [.divider, MenuEntry(title: "Delete", icon: "trash", key: "⌫", destructive: true) { self.act(on: c) { self.trash() } }]
        return e
    }

    /// Account switcher, shared by the top bar and the folder panel.
    func accountEntries() -> [MenuEntry] {
        var e: [MenuEntry] = [.header("Accounts")]
        for (i, a) in state.accounts.enumerated() {
            e.append(MenuEntry(title: label(a), subtitle: label(a) == a ? nil : a, letter: a, key: i < 9 ? "⌘\(i + 1)" : nil,
                               checked: state.activeAccount == a) { self.switchAccount(a) })
        }
        if state.accounts.count > 1 {
            e.append(MenuEntry(title: "All accounts", icon: "tray.2", key: "⌘0", checked: state.activeAccount == nil) { self.switchAccount(nil) })
        }
        e += [.divider,
              MenuEntry(title: "Add Google account", icon: "plus", disabled: !hasClient) { self.addAccount() },
              MenuEntry(title: "Settings", icon: "gearshape", key: "⌘,") { self.openSettings() }]
        return e
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if let b = store.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(b).font(.callout) }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glass(Capsule()).padding(.bottom, 16)
        }
    }
}

// MARK: Thread

struct ThreadView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    let conversation: Conversation
    @State private var expanded: Set<String> = []
    @AppStorage("threadNewestFirst") private var newestFirst = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.latest.subject).font(.system(size: 22, weight: .semibold)).textSelection(.enabled).lineLimit(2)
                Spacer()
                if conversation.messages.count > 1 {
                    Button { newestFirst.toggle() } label: {
                        Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down").font(.callout).padding(.horizontal, 6)
                    }.buttonBorderShape(.capsule).help("Change the order of messages in this thread")
                }
                Button { store.threadOpen = false } label: {
                    Label("Back", systemImage: "chevron.left").font(.callout).padding(.horizontal, 6)
                }.buttonBorderShape(.capsule).help("Back to the list (Esc)")
            }
            .padding(.horizontal, layout.compact ? 16 : 40).padding(.top, 4).padding(.bottom, 10)
            InstantReplyBar(conversation: conversation)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let older = Array(conversation.messages.dropLast())
                    if newestFirst { MessageCard(message: conversation.latest, collapsible: false) {} }
                    ForEach(newestFirst ? older.reversed() : older) { m in
                        if expanded.contains(m.key) { MessageCard(message: m, collapsible: true) { expanded.remove(m.key) } }
                        else { CollapsedMessage(message: m) { expanded.insert(m.key) } }
                    }
                    if !newestFirst { MessageCard(message: conversation.latest, collapsible: false) {} }
                }
                .frame(maxWidth: 960)               // emails stay readable on big monitors
                .frame(maxWidth: .infinity)
                .padding(.horizontal, layout.compact ? 16 : 40).padding(.top, 6).padding(.bottom, 60)
            }
            HStack(spacing: 22) {
                let actions: [(String, String, String, () -> Void)] = [
                    ("R", "Reply", "arrowshape.turn.up.left", { store.reply(all: false) }),
                    ("A", "Reply all", "arrowshape.turn.up.left.2", { store.reply(all: true) }),
                    ("F", "Forward", "arrowshape.turn.up.right", { store.forward() }),
                    ("E", "Done", "checkmark", { store.markDone() }),
                    ("H", "Remind", "clock", { store.openPalette("remind") }),
                    ("B", "Event", "calendar.badge.plus", { store.createEventFromEmail() }),
                    ("I", "Summarize", "text.append", { store.summarize() }),
                    ("⌫", "Delete", "trash", { store.trash() }),
                ]
                ForEach(actions, id: \.0) { k, l, icon, run in
                    Button(action: run) {
                        HStack(spacing: 6) {
                            Image(systemName: icon)
                            if !layout.compact {
                                Text(l)
                                Text(k).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                        }.font(.callout).padding(.horizontal, 4)
                    }.buttonBorderShape(.capsule).help("\(l) (\(k))")
                }
                Spacer()
                Button { store.move(-1) } label: { Image(systemName: "chevron.up") }.buttonBorderShape(.circle).help("Previous (K)")
                Button { store.move(1) } label: { Image(systemName: "chevron.down") }.buttonBorderShape(.circle).help("Next (J)")
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, layout.compact ? 16 : 40).padding(.vertical, 12)
        }
        .id(conversation.id) // fresh expand state per thread
    }
}

/// One line per older message: who, when, and a preview. Click to expand.
struct CollapsedMessage: View {
    let message: Message
    let expand: () -> Void
    var body: some View {
        Button(action: expand) {
            HStack(spacing: 10) {
                Avatar(address: parseAddresses(message.from).first, size: 26)
                Text(parseAddresses(message.from).first?.display ?? message.from).fontWeight(.medium).lineLimit(1)
                Text(message.snippet).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(shortDate(message.date)).font(.callout).foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct Avatar: View {
    let address: Address?
    var size: CGFloat = 34
    var body: some View {
        let key = address?.email ?? "?"
        Circle().fill(Theme.chip(key).opacity(0.2)).frame(width: size, height: size)
            .overlay(Text(String((address?.display ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Theme.chip(key)))
    }
}

/// Native header + the email body in its own isolated web view + native attachment buttons.
struct MessageCard: View {
    @EnvironmentObject var store: AppStore
    let message: Message
    let collapsible: Bool
    let collapse: () -> Void
    @State private var showQuoted = false
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("emailContentTheme") private var contentTheme = "auto"   // auto (match app), light, dark
    @Environment(\.colorScheme) private var scheme
    var contentDark: Bool { contentTheme == "dark" || (contentTheme == "auto" && scheme == .dark) }

    var body: some View {
        let from = parseAddresses(message.from).first
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(address: from)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(from?.display ?? message.from).font(.system(size: 15, weight: .semibold))
                        if let e = from?.email, from?.name.isEmpty == false { Text(e).font(.callout).foregroundStyle(.secondary) }
                    }
                    Text(recipients).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                PhishingPill(senderReasons: senderWarnings(message, known: store.knownContacts),
                             links: message.html.map(suspiciousLinks) ?? [])
                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                if collapsible {
                    Button(action: collapse) { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            // Clicking the header of an expanded older message collapses it again.
            .contentShape(Rectangle())
            .onTapGesture { if collapsible { collapse() } }
            .help(collapsible ? "Click to collapse" : "")
            bodyView
            let files = message.attachments.filter { !$0.isInline }
            let photos = files.filter { $0.mimeType.hasPrefix("image/") }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos, id: \.id) { a in
                            let img = store.thumbnails[message.key + "|" + a.id]
                            Button { store.preview(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                Group {
                                    if let img, img.size.width > 0 { Image(nsImage: img).resizable().scaledToFill() }
                                    else { ZStack { Color.primary.opacity(0.06); ProgressView().controlSize(.small) } }
                                }
                                .frame(width: 160, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain).handCursor().help(a.name)
                            .onAppear { store.loadThumbnail(message, a) }
                        }
                    }
                }
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files, id: \.id) { a in
                            HStack(spacing: 2) {
                                Button { store.preview(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                    Label {
                                        Text(a.name).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).foregroundStyle(.secondary)
                                    } icon: { Image(systemName: icon(a.mimeType)) }
                                    .font(.callout)
                                }.buttonStyle(.plain).handCursor().help("Click to preview")
                                Divider().frame(height: 16).padding(.horizontal, 6)
                                Button { store.preview(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                    Image(systemName: "eye")
                                }.buttonStyle(.plain).handCursor().help("Preview")
                                Button { store.download(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                    Image(systemName: "arrow.down.circle")
                                }.buttonStyle(.plain).handCursor().padding(.leading, 6).help("Download to your Downloads folder")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
    }

    var recipients: String {
        let to = parseAddresses(message.to).map { store.me.contains($0.email.lowercased()) ? "me" : $0.display }.joined(separator: ", ")
        let cc = parseAddresses(message.cc).map(\.display).joined(separator: ", ")
        return "to \(to.isEmpty ? "undisclosed recipients" : to)" + (cc.isEmpty ? "" : " · cc \(cc)")
    }

    @ViewBuilder var bodyView: some View {
        if let html = message.html {
            // HTML emails are designed for a light page, so they sit on a white "paper" card, like Apple Mail does.
            EmailWebView(html: inlineImages(html, store.inlineData[message.key] ?? [:]), cardOpacity: cardOpacity,
                         dark: contentDark,
                         suspicious: Dictionary(suspiciousLinks(html).map { ($0.href, $0.reason) }, uniquingKeysWith: { a, _ in a }))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            let parts = splitQuoted(message.text ?? message.snippet)
            VStack(alignment: .leading, spacing: 8) {
                // Match app: plain text sits on the card in app colors. Forced light/dark: it gets the same "paper" as HTML emails.
                EmailWebView(html: plainToHTML(parts.body), dark: contentDark, themed: contentTheme == "auto")
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let q = parts.quoted {
                    Button { showQuoted.toggle() } label: {
                        Text("•••").font(.system(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }.buttonStyle(.plain).handCursor().help(showQuoted ? "Hide quoted text" : "Show quoted text")
                    if showQuoted { EmailWebView(html: plainToHTML(q), dark: contentDark, themed: contentTheme == "auto").opacity(0.7) }
                }
            }
        }
    }

    func icon(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime.contains("csv") { return "tablecells" }
        if mime.contains("zip") { return "doc.zipper" }
        if mime == "text/calendar" { return "calendar" }
        return "paperclip"
    }
}

/// One email's HTML in its own web view: its CSS can't leak into the app, JavaScript is off,
/// it sizes itself to the content, and scrolling passes through to the thread.
struct EmailWebView: NSViewRepresentable {
    let html: String
    var padding = "16px 20px"
    var cardOpacity = 1.0   // < 1 lets the window glass show through the email's background
    var dark = false        // HTML emails: invert colors (keeping photos as-is) to read on dark mode
    var themed = false      // plain-text emails: app font and light/dark colors, transparent background
    var suspicious: [String: String] = [:]   // href → why it looks like phishing; clicking asks first
    @State private var height: CGFloat = 120
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PassThroughWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent() // no cookies or storage shared between emails
        if !UserDefaults.standard.bool(forKey: "loadRemoteImages", default: true), let blocker = RemoteContent.blocker {
            config.userContentController.add(blocker)
        }
        config.userContentController.addUserScript(WKUserScript(source: Coordinator.darkScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let v = PassThroughWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        if !themed { v.appearance = NSAppearance(named: .aqua) } // HTML emails render as their senders designed them (light)
        v.setValue(false, forKey: "drawsBackground") // the page's own background (below) decides how see-through it is
        context.coordinator.onHeight = { h in if abs(h - height) > 1 { height = h } }
        return v
    }
    func updateNSView(_ v: PassThroughWebView, context: Context) {
        context.coordinator.suspicious = suspicious
        let page = themed ? Self.wrapThemed(html) : Self.wrap(html, padding: padding, opacity: cardOpacity, dark: dark)
        guard context.coordinator.last != page else { return }
        context.coordinator.last = page
        v.loadHTMLString(page, baseURL: nil)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassThroughWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }

    /// Minimal reset only; never override the sender's layout (forcing image heights broke sprites and banners).
    static func wrap(_ html: String, padding: String = "16px 20px", opacity: Double = 1, dark: Bool = false) -> String {
        // Dark: the page starts dark and darkScript recolors the email element by element (images untouched).
        let darkCSS = dark ? "img.lm-plate { background-color: #fff; border-radius: 3px; }" : ""
        let bg = dark ? "30,30,32" : "255,255,255"
        return """
        <!doctype html><html\(dark ? " class=\"lm-dark\"" : "")><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>
        html, body { margin: 0; padding: 0; background: rgba(\(bg),\(String(format: "%.2f", opacity))); color: \(dark ? "#e8e8ea" : "#1d1d1f"); }
        \(darkCSS)
        body { padding: \(padding); font: 15px -apple-system, Helvetica, sans-serif; line-height: 1.45; overflow-wrap: anywhere; }
        img { max-width: 100%; }
        a, a * { cursor: pointer; }
        table { max-width: 100%; }
        pre { white-space: pre-wrap; }
        </style></head><body>\(html)</body></html>
        """
    }

    /// Plain text styled like the rest of the app, following light/dark mode.
    static func wrapThemed(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; }
        body { font: 15px -apple-system, sans-serif; line-height: 1.55; overflow-wrap: anywhere; }
        a { color: LinkText; cursor: pointer; }
        </style></head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Dark mode: logos with see-through backgrounds (black ink) would vanish on the dark page, so images get a
        /// white backing. Photos cover it completely. Skips tracking pixels and thin spacer images used for layout.
        /// Runs in the app's own script world; the email's scripts stay disabled. The class only has a style in dark mode.
        /// Dark mode rules, applied to every element of the email:
        ///  1. Images are never changed.
        ///  2. Light backgrounds become dark, keeping their hue.
        ///  3. Dark text and borders become light, keeping their hue (links stay blue).
        ///  4. Mid-tone and dark backgrounds (buttons, banners) stay as designed.
        ///  5. Anything drawn on a background image is left alone.
        /// Safe to run more than once: already-dark backgrounds and light text are skipped.
        static let darkScript = """
        (function(){if(!document.documentElement.classList.contains('lm-dark'))return;
        function rgb(c){var m=/rgba?\\(([\\d.]+),\\s*([\\d.]+),\\s*([\\d.]+)(?:,\\s*([\\d.]+))?/.exec(c);return m?[+m[1]/255,+m[2]/255,+m[3]/255,m[4]===undefined?1:+m[4]]:null}
        function lum(c){return .299*c[0]+.587*c[1]+.114*c[2]}
        function setL(c,L){var r=c[0],g=c[1],b=c[2],mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn,l=(mx+mn)/2,h=0,s=0;
        if(d){s=l>.5?d/(2-mx-mn):d/(mx+mn);h=mx==r?(g-b)/d+(g<b?6:0):mx==g?(b-r)/d+2:(r-g)/d+4;h/=6}
        function f(t){t=(t%1+1)%1;var q=L<.5?L*(1+s):L+s-L*s,p=2*L-q;return t<1/6?p+(q-p)*6*t:t<.5?q:t<2/3?p+(q-p)*(2/3-t)*6:p}
        return 'rgba('+Math.round(f(h+1/3)*255)+','+Math.round(f(h)*255)+','+Math.round(f(h-1/3)*255)+','+c[3]+')'}
        var art='[style*="background-image"],[style*="background:url"],[style*="background: url"],[background]';
        document.querySelectorAll('body *').forEach(function(el){
        if(/^(IMG|PICTURE|VIDEO|SVG|svg)$/.test(el.tagName)||el.closest(art))return;
        var cs=getComputedStyle(el),bg=rgb(cs.backgroundColor),fg=rgb(cs.color);
        if(bg&&bg[3]>0&&lum(bg)>.6)el.style.setProperty('background-color',setL(bg,.12+(1-lum(bg))*.5),'important');
        if(fg&&lum(fg)<.5)el.style.setProperty('color',setL(fg,.86-lum(fg)*.4),'important');
        ['top','right','bottom','left'].forEach(function(side){var w=parseFloat(cs['border-'+side+'-width']),bc=rgb(cs['border-'+side+'-color']);
        if(w>0&&bc&&lum(bc)<.35)el.style.setProperty('border-'+side+'-color',setL(bc,.45),'important')})});})();0
        """

        static let plateScript = """
        if(document.documentElement.classList.contains('lm-dark'))document.querySelectorAll('img').forEach(function(i){var w=i.clientWidth,h=i.clientHeight;
        if(!i.complete||!i.naturalWidth||w<=12||h<=12||w/h>=12||h/w>=12)return;
        for(var p=i.parentElement,n=0;p&&n<6;p=p.parentElement,n++){if(getComputedStyle(p).backgroundImage!=='none')return;}
        i.classList.add('lm-plate')});0
        """
        var last = ""
        var suspicious: [String: String] = [:]
        var onHeight: (CGFloat) -> Void = { _ in }
        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            // Images keep loading after "finish", so measure a few times as they arrive.
            for delay in [0.0, 0.4, 1.2, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak w] in
                    if delay == 0 { w?.evaluateJavaScript(Self.darkScript) }
                    w?.evaluateJavaScript(Self.plateScript)
                    w?.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)") { r, _ in
                        if let h = r as? CGFloat { self?.onHeight(h) } else if let h = r as? Double { self?.onHeight(CGFloat(h)) }
                    }
                }
            }
        }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only our own initial page load renders inside the view; every click goes through openChecked.
            guard let url = a.request.url, a.navigationType != .other || a.targetFrame == nil else { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            openChecked(url)
        }

        /// Web links open directly unless flagged; flagged links, and anything that isn't http(s) or mailto,
        /// get one confirmation showing where they really go (linkWarning is an allowlist).
        func openChecked(_ url: URL) {
            let reason = suspicious[url.absoluteString] ?? suspicious.first { URL(string: $0.key) == url }?.value
                ?? linkWarning(href: url.absoluteString, shown: "")
            guard let reason else { NSWorkspace.shared.open(url); return }
            Task { @MainActor in AppStore.current?.linkPrompt = LinkPrompt(url: url, reason: reason) }
        }
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = a.request.url { openChecked(url) }
            return nil
        }
    }
}

/// Sends scroll-wheel events to the thread instead of scrolling inside the email,
/// and shows the pointing hand over links (SwiftUI otherwise keeps resetting it to the arrow).
final class PassThroughWebView: WKWebView {
    private var overLink = false
    private var pending = false

    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self && t.userInfo?["links"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["links": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !pending else { return } // one lookup in flight at a time
        let p = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? p.y : bounds.height - p.y
        pending = true
        // Runs in the app's own script world, which works even though the email's scripts are off.
        evaluateJavaScript("(function(){var e=document.elementFromPoint(\(p.x),\(y));return !!(e&&e.closest('a[href]'));})()") { [weak self] r, _ in
            guard let self else { return }
            self.pending = false
            self.overLink = (r as? Bool) ?? false
            (self.overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        (overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        overLink = false
        NSCursor.arrow.set()
    }
}

// MARK: Command palette

struct PaletteView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool
    var body: some View {
        let list = store.filteredCommands
        VStack(spacing: 0) {
            TextField("Type a command, or \"remind friday 3pm\"…", text: $store.paletteText)
                .textFieldStyle(.plain).font(.system(size: 18)).focused($focused)
                .padding(18)
                .onChange(of: store.paletteText) { _, _ in store.paletteIndex = 0 }
                .onAppear { focused = true }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            HStack {
                                Text(c.title)
                                Spacer()
                                if !c.key.isEmpty { Text(c.key).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(i == store.paletteIndex ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { store.runPalette(i) }
                            .id(i)
                        }
                        if list.isEmpty { Text("No matching command").foregroundStyle(.secondary).padding(20) }
                    }.padding(8)
                }
                .onChange(of: store.paletteIndex) { _, i in proxy.scrollTo(i) }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 600)
        .floatingPanel(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .fixedSize(horizontal: false, vertical: true)
    }
}

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
                .onAppear { bodyFocused = true; showCc = !model.draft.cc.isEmpty; showBcc = !model.draft.bcc.isEmpty }

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

// MARK: Sidebars

/// Slide-out folder panel, modeled on Superhuman's: account at top, folders, then labels.
struct FolderPanel: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let account = store.state.activeAccount
        let inboxCount = store.allConversations.filter(\.inInbox).count
        let labels = store.panelLabels
        VStack(alignment: .leading, spacing: 0) {
            MenuButton(width: 320, entries: { store.accountEntries() }) {
                HStack(spacing: 10) {
                    let name = account.map(store.label) ?? (store.state.accounts.count > 1 ? "All accounts" : store.state.accounts.first.map(store.label) ?? "")
                    Circle().fill(Theme.chip(name).opacity(0.25)).frame(width: 30, height: 30)
                        .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.chip(name)))
                    Text(name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let keys = ["Inbox": "G I", "Starred": "G S", "Drafts": "G D", "Sent": "G T", "Done": "G E", "Reminders": "G H"]
                    ForEach(Array(AppStore.panelFolders.enumerated()), id: \.element) { i, name in
                        row(name, subtitle: name == "Inbox" ? "Important · Other" : nil,
                            count: name == "Inbox" ? inboxCount : name == "Reminders" ? store.state.snoozes.count : name == "Scheduled" ? store.state.scheduled.count : 0,
                            key: keys[name] ?? "", on: name == "Inbox" ? store.folder == nil : store.folder == name,
                            highlighted: store.panelIndex == i) { store.activatePanel(i) }
                    }
                    if !labels.isEmpty {
                        Divider().padding(.vertical, 12).padding(.horizontal, 18)
                        Text("Labels").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 18).padding(.bottom, 6)
                        ForEach(Array(labels.enumerated()), id: \.element) { i, l in
                            let idx = AppStore.panelFolders.count + i
                            row(l, indent: true, on: store.folder == l, highlighted: store.panelIndex == idx) { store.activatePanel(idx) }
                        }
                    }
                }.padding(.bottom, 16)
            }
            .onChange(of: store.panelIndex) { _, i in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(i < AppStore.panelFolders.count ? AppStore.panelFolders[i] : labels[safe: i - AppStore.panelFolders.count] ?? "", anchor: .center)
                }
            }
            }
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .floatingPanel(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.18), radius: 24, x: 6)
        .padding(10)
    }

    func row(_ title: String, subtitle: String? = nil, count: Int = 0, key: String = "", indent: Bool = false, on: Bool,
             highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.tertiary) }
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary) }
                else if !key.isEmpty { Text(key).font(.system(size: 10, weight: .medium)).foregroundStyle(.quaternary) }
            }
            .padding(.leading, indent ? 30 : 18).padding(.trailing, 18).padding(.vertical, 8)
            .background(alignment: .leading) {
                // Keyboard highlight (↑/↓): a soft fill, separate from the current-folder bar.
                if highlighted && !on { RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)).padding(.horizontal, 8) }
                if on {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.selection)
                        Rectangle().fill(Theme.accent).frame(width: 3)
                    }
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Right panel: who you're talking to, your history with them, and recently opened threads.
struct ContextPanel: View {
    @EnvironmentObject var store: AppStore
    let conversation: Conversation
    var body: some View {
        let person = parseAddresses(conversation.messages.last { m in !store.me.contains(parseAddresses(m.from).first?.email.lowercased() ?? "") }?.from
                                    ?? conversation.latest.to).first
        let all = store.allConversations
        let email = person?.email.lowercased() ?? ""
        let history = all.filter { c in c.id != conversation.id && c.messages.contains { parseAddresses($0.from + "," + $0.to).contains { $0.email.lowercased() == email } } }
        let recent = store.recentlyOpened.filter { $0 != conversation.id }.compactMap { id in all.first { $0.id == id } }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let person {
                    VStack(alignment: .leading, spacing: 6) {
                        Circle().fill(Theme.chip(email).opacity(0.18)).frame(width: 44, height: 44)
                            .overlay(Text(String(person.display.prefix(1)).uppercased()).font(.title3.weight(.semibold)).foregroundStyle(Theme.chip(email)))
                        Text(person.display).font(.headline).lineLimit(1)
                        Text(person.email).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                    }
                }
                section("Recent with \(person?.firstName.isEmpty == false ? person!.firstName : "them")", history.prefix(5))
                section("Recently opened", recent.prefix(5))
                CalendarSection(conversation: conversation)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(Date().formatted(date: .complete, time: .omitted)).font(.callout)
                    let due = store.state.snoozes.filter { Calendar.current.isDateInToday($0.until) }.count
                    Text("\(due) reminder\(due == 1 ? "" : "s") returning today · \(store.state.scheduled.count) scheduled").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 270)
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.trailing, 10).padding(.vertical, 10).padding(.top, 24)
    }

    @ViewBuilder func section(_ title: String, _ items: ArraySlice<Conversation>) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items)) { c in
                    Button { store.open(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.latest.subject).font(.callout).lineLimit(1)
                            Text(shortDate(c.latest.date)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Split Inbox settings

struct SplitSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    var embedded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Split Inbox").font(.title2.weight(.semibold))
                Spacer()
                Button("Build your own") { store.state.splits.append(Split(name: "New split", query: "")) }
                Button { store.suggestSplits() } label: { Label("Suggest with \(store.ai.name)", systemImage: "sparkles") }
            }
            Text("Define each split with a search, e.g. `from:hubspot.com OR subject:\"new lead\"`. Also works: to:, cc:, label:, has:attachment, is:unread, is:starred, -term to exclude. Drag to reorder. Aim for 3 to 7.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($store.state.splits) { $split in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            TextField("Name", text: $split.name).font(.headline).textFieldStyle(.plain)
                            Spacer()
                            Toggle("On", isOn: $split.enabled).toggleStyle(.switch).controlSize(.small)
                            Button(role: .destructive) { store.state.splits.removeAll { $0.id == split.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        TextField(split.query.hasPrefix("is:") ? "" : "Definition, e.g. from:boss@company.com", text: $split.query)
                            .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                            .disabled(split.query == "is:reminder" || split.query == "is:team")
                        HStack(spacing: 18) {
                            Toggle("Also show in Important / Other", isOn: $split.alsoInMain)
                            Toggle("Hide when empty", isOn: $split.hideWhenEmpty)
                        }.font(.callout).toggleStyle(.checkbox)
                    }.padding(.vertical, 6)
                }
                .onMove { store.state.splits.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 220)
            let library = splitLibrary.filter { lib in !store.state.splits.contains { $0.name == lib.name } }
            if !library.isEmpty || !store.splitSuggestions.isEmpty {
                Text("Add a split").font(.headline)
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
                Text("Important and Other are always last.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24).frame(width: 680, height: embedded ? nil : 620)
    }
}

/// The selected split tab floats on glass; the rest stay flat text.
struct SelectedGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glass(Capsule(), interactive: true) } else { content }
    }
}

// MARK: iCloud sign-in

struct ICloudSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var aliases = ""
    @State private var error: String?
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add iCloud Mail").font(.title2.weight(.semibold))
            Text("iCloud needs an **app-specific password**, not your Apple Account password. It's saved only in your Mac's Keychain.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Go to account.apple.com → Sign-In and Security → App-Specific Passwords.")
                Text("2. Create one named \"Lightmail\" and paste it below.")
            }.font(.callout)
            Button("Open account.apple.com") { NSWorkspace.shared.open(URL(string: "https://account.apple.com/account/manage")!) }
            TextField("Primary iCloud email (you@icloud.com)", text: $email).textFieldStyle(.roundedBorder)
            SecureField("App-specific password (xxxx-xxxx-xxxx-xxxx)", text: $password).textFieldStyle(.roundedBorder)
            TextField("Aliases to send as (optional, comma-separated)", text: $aliases).textFieldStyle(.roundedBorder)
            Text("Sign in with your **primary** iCloud address; aliases can't sign in. Add aliases here to send from them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Checking…" : "Add account") {
                    working = true; error = nil
                    Task {
                        do { try await store.addICloudAccount(email: email, password: password, aliases: aliases); dismiss() }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction).prominentGlassButton()
                .disabled(working || !email.contains("@") || password.count < 8)
            }
        }
        .padding(28).frame(width: 520)
    }
}

// MARK: Settings window (⌘,)

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag("accounts")
            GmailSettings().tabItem { Label("Gmail", systemImage: "envelope.badge") }.tag("gmail")
            AIProviderSettings().tabItem { Label("AI Providers", systemImage: "sparkles") }.tag("ai")
            SplitSettingsView(embedded: true).tabItem { Label("Split Inbox", systemImage: "rectangle.split.3x1") }.tag("splits")
            SignatureSettings().tabItem { Label("Signatures", systemImage: "signature") }.tag("signatures")
            SnippetSettings().tabItem { Label("Snippets", systemImage: "text.quote") }.tag("snippets")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 700, height: 560)
        .glassButtons()
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("windowOpacity") private var windowOpacity = 0.7
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("grammar") private var grammar = true
    @AppStorage("autocorrect") private var autocorrect = true
    @AppStorage("smartQuotes") private var smartQuotes = false
    @AppStorage("writingToolsButton") private var writingToolsButton = false
    @AppStorage("threadNewestFirst") private var newestFirst = false
    @AppStorage("emailContentTheme") private var contentTheme = "auto"
    var body: some View {
        Form {
            Picker("Email content", selection: $contentTheme) {
                Text("Match app").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
            Picker("Messages in a thread", selection: $newestFirst) {
                Text("Oldest first").tag(false); Text("Newest first").tag(true)
            }.pickerStyle(.segmented)
            Picker("Appearance", selection: Binding(get: { store.state.appearance }, set: { store.setAppearance($0) })) {
                Text("Match system").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark")
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Calendar") {
                if store.calendar.authorized { Text("Connected to the Calendar app").foregroundStyle(.secondary) }
                else { Button("Allow calendar access") { Task { _ = await store.calendar.requestAccess() } } }
            }
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
                .font(.caption).foregroundStyle(.secondary)
            Section("Privacy") {
                Toggle("Load remote images", isOn: $loadRemoteImages)
                Text("Senders can use remote images to see when, where and on what device you opened an email. Turning this off blocks all outside content in emails; images attached to the email still show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Check spelling while typing", isOn: $spellcheck)
                Toggle("Check grammar", isOn: $grammar)
                Toggle("Correct spelling automatically", isOn: $autocorrect)
                Toggle("Smart quotes and dashes", isOn: $smartQuotes)
                Toggle("Show Apple's Writing Tools button while typing", isOn: $writingToolsButton)
                Text("Uses macOS's built-in spelling and grammar checker, in your system language. Right-click an underlined word for suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text("Connected accounts").font(.headline)
            if store.state.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(store.state.accounts.enumerated()), id: \.element) { i, acct in
                    let cloud = store.isICloud(acct)
                    HStack(spacing: 12) {
                        Image(systemName: cloud ? "icloud.fill" : "envelope.fill")
                            .foregroundStyle(cloud ? Color.blue : Color.red).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name (e.g. Work, Personal)", text: Binding(
                                get: { store.state.accountNames[acct] ?? "" },
                                set: { store.state.accountNames[acct] = $0 }))
                                .textFieldStyle(.plain).font(.headline)
                            Text("\(acct) · \(cloud ? "iCloud Mail" : "Gmail")").font(.caption).foregroundStyle(.secondary)
                            TextField("Send-as aliases, comma-separated", text: Binding(
                                get: { (store.state.aliases[acct] ?? []).joined(separator: ", ") },
                                set: { store.setAliases($0, for: acct) }))
                                .textFieldStyle(.roundedBorder).font(.caption)
                                .help(cloud ? "Aliases from icloud.com → Mail settings → Accounts" : "Must already be set up under Gmail → Settings → Accounts → Send mail as")
                            if !(store.state.aliases[acct] ?? []).isEmpty {
                                Picker("Send from by default", selection: Binding(
                                    get: { store.sendAddress(acct) },
                                    set: { store.state.defaultFrom[acct] = $0 })) {
                                    ForEach([acct] + (store.state.aliases[acct] ?? []), id: \.self) { Text($0).tag($0) }
                                }
                                .font(.caption).fixedSize()
                            }
                        }
                        Spacer()
                        Text("⌘\(i + 1)").font(.caption).foregroundStyle(.tertiary)
                        Button("Remove") { removing = acct }
                    }.padding(.vertical, 4)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Button { store.addAccount() } label: { Label("Add Google account", systemImage: "plus") }
                    .disabled(!store.hasClient)

                Button { showICloud = true } label: { Label("Add iCloud account", systemImage: "plus") }
            }
            if let b = store.busy { Text(b).font(.callout).foregroundStyle(.secondary) }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GoogleClient.isBuiltIn ? "Google sign-in uses the client built into this app." :
                         store.hasClient ? "Google sign-in uses your own Google Cloud client." : "This build has no Google client.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Use my own Google Cloud client…") { showGoogleSetup = true }.controlSize(.small)
                }.padding(.top, 4)
            }.font(.callout)
            Text("iCloud uses an app-specific password stored in your Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .card(isPresented: $showICloud) { ICloudSheet() }
        .card(isPresented: $showGoogleSetup, closeButton: true) { SetupView().frame(width: 640, height: 500) }
        .confirmCard(removing.map { "Remove \($0)?" }, message: "This signs Lightmail out of the account and clears its cached mail from this Mac. Nothing is deleted from the server.",
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
                    TextEditor(text: $store.state.snippets[i].body).font(.system(size: 14))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    Text("Use {first_name}, {name} or {email} for the first recipient.").font(.callout).foregroundStyle(.secondary)
                }.padding(16)
            } else {
                Text("Select a snippet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: Instant reply

struct InstantReplyBar: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    let conversation: Conversation
    var body: some View {
        let options = store.instantReplies[conversation.id]
        HStack(spacing: 8) {
            if let options {
                ForEach(Array(options.enumerated()), id: \.offset) { i, text in
                    Button { store.useInstantReply(i) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(i + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(text).lineLimit(2).multilineTextAlignment(.leading)
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if store.instantLoading == conversation.id {
                ProgressView().controlSize(.small)
                Text("\(store.ai.name) is writing replies…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Button { store.instantReply() } label: { Label("Instant reply", systemImage: "sparkles") }
                Text("⇧R, then 1 · 2 · 3").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, layout.compact ? 16 : 40).padding(.bottom, 8)
    }
}

// MARK: Calendar

struct CalendarSection: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cal: CalendarService   // redraws when access is granted
    let conversation: Conversation
    var body: some View {
        let mentioned = parseWhen(String(conversation.latest.plainText.prefix(4000)))
        let day = mentioned ?? Date()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mentioned == nil ? "Today" : "Mentioned: \(day.formatted(.dateTime.weekday(.abbreviated).month().day()))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.createEventFromEmail() } label: { Image(systemName: "calendar.badge.plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Create event (B)")
            }
            if !cal.authorized {
                Button("Show my calendar") { Task { _ = await store.calendar.requestAccess() } }.controlSize(.small)
            } else {
                let events = cal.events(on: day)
                if events.isEmpty { Text("Nothing scheduled").font(.callout).foregroundStyle(.tertiary) }
                ForEach(events.prefix(6), id: \.eventIdentifier) { e in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: e.calendar.cgColor)).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title ?? "Busy").font(.callout).lineLimit(1)
                            Text(e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}


struct EventSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    @State var draft: EventDraft
    @State private var calendarId = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New event").font(.title2.weight(.semibold))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            DatePicker("Starts", selection: $draft.start)
            Picker("Length", selection: $draft.minutes) {
                Text("15 min").tag(15); Text("30 min").tag(30); Text("45 min").tag(45); Text("1 hour").tag(60); Text("2 hours").tag(120)
            }
            Picker("Calendar", selection: $calendarId) {
                ForEach(store.calendar.writableCalendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
            }
            TextField("Location or video link", text: $draft.location).textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.notes).frame(height: 80).font(.callout)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            Text("Invitations to the people on the email aren't sent; they're listed in the notes.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to calendar") {
                    do {
                        let cal = store.calendar.writableCalendars.first { $0.calendarIdentifier == calendarId }
                        try store.calendar.create(title: draft.title, start: draft.start, minutes: draft.minutes,
                                                  notes: draft.notes, location: draft.location, calendar: cal)
                        store.banner = "Added \"\(draft.title)\" to your calendar."
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).prominentGlassButton()
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { calendarId = store.calendar.store.defaultCalendarForNewEvents?.calendarIdentifier ?? "" }
    }
}

// MARK: Settings → AI Providers

struct AIProviderSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var installed: [String: String] = [:]   // id → path
    @State private var status: [String: String] = [:]      // id → last test result
    @State private var testing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI providers").font(.headline)
            Text("Lightmail uses an AI command-line tool that's already signed in on this Mac, billed to that tool's own plan. It runs read-only: email content can only produce text, never run commands or change files.")
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

// MARK: Settings → Signatures

struct SignatureSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: String?
    @State private var htmlMode = false
    @State private var note: String?
    func importFile(into binding: Binding<String>) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.html]
        guard p.runModal() == .OK, let url = p.url, let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        binding.wrappedValue = extractBodyHTML(html); note = nil
    }
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.fromAddresses, id: \.self) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.state.accounts.contains(a) ? store.label(a) : a).lineLimit(1)
                        Text(store.state.accounts.contains(a) ? a : "Alias").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(a)
                }
            }.frame(width: 230)
            Divider()
            if let a = selection {
                let binding = Binding(get: { store.state.signatures[a.lowercased()] ?? "" },
                                      set: { store.state.signatures[a.lowercased()] = $0 })
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Add signature to", selection: $store.state.signatureUse) {
                        Text("All emails").tag("all"); Text("New emails only").tag("new")
                        Text("Replies & forwards only").tag("replies"); Text("Off").tag("off")
                    }.fixedSize()
                    Divider()
                    HStack {
                        Text("Signature for \(a)").font(.headline).lineLimit(1)
                        Spacer()
                        Picker("", selection: $htmlMode) { Text("Visual").tag(false); Text("HTML").tag(true) }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HStack {
                        Button { if let h = SignaturePasteboard.html() { binding.wrappedValue = extractBodyHTML(h) } else { note = "The clipboard has no formatted signature. Copy it from Mail, Gmail or a web page first." } } label: {
                            Label("Paste signature", systemImage: "doc.on.clipboard")
                        }
                        Button { importFile(into: binding) } label: { Label("Import HTML file…", systemImage: "square.and.arrow.down") }
                        Spacer()
                        if !binding.wrappedValue.isEmpty { Button("Clear", role: .destructive) { binding.wrappedValue = "" } }
                    }.controlSize(.small)
                    if htmlMode {
                        TextEditor(text: binding).font(.system(size: 12, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                        Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        EmailWebView(html: binding.wrappedValue).frame(minHeight: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if isComplexHTML(binding.wrappedValue) {
                        // Tables, logos and rounded corners can't go through the rich-text editor unchanged,
                        // so show it exactly as recipients will see it instead.
                        EmailWebView(html: binding.wrappedValue).frame(minHeight: 100).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("This signature has a designed layout (table, logo or rounded corners). It's kept exactly as is. Edit it in HTML, or paste/import a new one.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    } else {
                        RichTextEditor(html: binding)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    }
                    if let note { Text(note).font(.callout).foregroundStyle(.orange) }
                    Text("Type with formatting (⌘B, ⌘I, ⌘K for links), paste a signature from Mail or Gmail (⌘V or Paste signature), or import an .html file. Logos embedded in the signature are sent as inline images so Gmail and Outlook show them.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            } else {
                Text("Select an address").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.fromAddresses.first } }
    }
}

/// A rich-text box whose value is HTML. Pasted formatting (bold, links, colors, fonts) is kept.
struct RichTextEditor: NSViewRepresentable {
    @Binding var html: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = SignatureTextView()
        tv.minSize = .zero; tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        tv.onPasteHTML = { html in context.coordinator.parent.html = extractBodyHTML(html) }
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false   // pasted images can't travel inside a signature; use an <img> link in HTML mode
        tv.usesFontPanel = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.delegate = context.coordinator
        context.coordinator.load(html, into: tv)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        if html != context.coordinator.lastHTML { context.coordinator.load(html, into: tv) } // switched address or edited as HTML
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastHTML = ""
        init(_ p: RichTextEditor) { parent = p }

        func load(_ html: String, into tv: NSTextView) {
            lastHTML = html
            let source = signatureParts(html).html ?? plainToHTML(html)
            let attr = source.isEmpty ? NSAttributedString()
                : (try? NSAttributedString(data: Data(source.utf8),
                                           options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                           documentAttributes: nil)) ?? NSAttributedString(string: html)
            tv.textStorage?.setAttributedString(attr)
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView, let storage = tv.textStorage else { return }
            let html = storage.length == 0 ? "" : Self.bodyHTML(storage)
            lastHTML = html
            parent.html = html
        }

        /// AppKit writes a full HTML document; keep just the body plus its inline styles.
        static func bodyHTML(_ s: NSAttributedString) -> String {
            guard let data = try? s.data(from: NSRange(location: 0, length: s.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                              .excludedElements: ["xml", "doctype", "html", "head", "body", "meta", "title"]]),
                  var out = String(data: data, encoding: .utf8) else { return s.string }
            // AppKit puts styles in a <style> block with class names; email clients strip <style>, so inline them.
            if let styleRange = out.range(of: "<style[^>]*>([\\s\\S]*?)</style>", options: .regularExpression) {
                let css = String(out[styleRange])
                out.removeSubrange(styleRange)
                let re = try! NSRegularExpression(pattern: "([a-z]+)\\.([a-z0-9]+)\\s*\\{([^}]*)\\}")
                let ns = css as NSString
                for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
                    let tag = ns.substring(with: m.range(at: 1)), cls = ns.substring(with: m.range(at: 2))
                    let style = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    out = out.replacingOccurrences(of: "<\(tag) class=\"\(cls)\"", with: "<\(tag) style=\"\(style)\"")
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Reads a formatted signature from the clipboard as HTML, preferring the source's own HTML over a converted copy.
enum SignaturePasteboard {
    static func html(_ pb: NSPasteboard = .general) -> String? {
        if let s = pb.string(forType: .html), !s.isEmpty { return s }
        // Mail and Safari copy as a web archive: the original HTML is inside.
        if let d = pb.data(forType: NSPasteboard.PasteboardType("com.apple.webarchive")),
           let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let main = plist["WebMainResource"] as? [String: Any], let data = main["WebResourceData"] as? Data,
           let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return s
        }
        return nil
    }
}

/// Pasting formatted content stores its HTML as-is instead of flattening it through rich text.
final class SignatureTextView: NSTextView {
    var onPasteHTML: ((String) -> Void)?
    override func paste(_ sender: Any?) {
        if let html = SignaturePasteboard.html(), isComplexHTML(html) || html.contains("<") { onPasteHTML?(html); return }
        super.paste(sender)
    }
}

/// The signature as recipients will see it, below what you type. Not editable here, so it can't be deleted by accident.
struct ComposeSignature: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: ComposeModel
    var body: some View {
        if let plain = model.draft.signaturePlain {
            HStack(alignment: .top, spacing: 8) {
                if let html = model.draft.signatureHTML {
                    EmailWebView(html: html, padding: "10px 14px").frame(maxWidth: 520).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(plain).font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { store.applySignature(&model.draft, from: nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove signature (put it back from the Signature menu)")
            }
        }
    }
}

/// Wraps children onto new lines, for recipient chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            if v == subviews.last { s.width = max(s.width, b.maxX - x) } // the text field takes the rest of the line
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// Recipients as chips. The underlying value stays a normal "a@b.com, Name <c@d.com>, " string.
struct RecipientChips: View {
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<ComposeView.Field?>.Binding
    let field: ComposeView.Field
    let complete: (String) -> String?

    var committed: [Address] {
        var parts = text.components(separatedBy: ",")
        parts.removeLast()
        return parseAddresses(parts.joined(separator: ","))
    }

    var body: some View {
        let token = Binding<String>(
            get: { currentToken(text) },
            set: { new in
                let head = committed.map(\.formatted)
                if new.contains(",") || new.hasSuffix(" ") && new.contains("@") {
                    // Comma (or a space after a full address) turns the typed text into a chip.
                    let typed = new.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                    text = (head + (typed.isEmpty ? [] : [typed])).map { $0 + ", " }.joined()
                } else {
                    text = (head.map { $0 + ", " }.joined()) + new
                }
            })
        FlowLayout(spacing: 6) {
            ForEach(Array(committed.enumerated()), id: \.offset) { i, a in
                HStack(spacing: 5) {
                    Avatar(address: a, size: 18)
                    Text(a.name.isEmpty ? a.email : a.name).lineLimit(1)
                    ChipRemoveButton { remove(i) }
                }
                .font(.callout).padding(.leading, 3).padding(.trailing, 3).padding(.vertical, 2)
                .background(Capsule().fill(a.email.contains("@") ? Color.primary.opacity(0.07) : Color.red.opacity(0.15)))
                .help(a.email)
            }
            TextField(committed.isEmpty ? placeholder : "", text: token)
                .textFieldStyle(.plain).focused(focus, equals: field)
                .frame(minWidth: 120)
                .onSubmit { commit() }
                .onKeyPress(.tab) {
                    if let c = complete(text) { text = c; return .handled }
                    if !currentToken(text).isEmpty { commit(); return .handled }
                    return .ignored
                }
                .onKeyPress(.delete) {
                    guard currentToken(text).isEmpty, !committed.isEmpty else { return .ignored }
                    remove(committed.count - 1); return .handled
                }
        }
    }

    func commit() {
        let t = currentToken(text)
        guard !t.isEmpty else { return }
        text = (committed.map(\.formatted) + [t]).map { $0 + ", " }.joined()
    }

    func remove(_ i: Int) {
        var list = committed.map(\.formatted)
        list.remove(at: i)
        text = list.map { $0 + ", " }.joined() + currentToken(text)
    }
}

// MARK: Window opacity

/// Frosted, see-through window background. Text and email content stay fully opaque; only the backdrop thins out.
struct WindowOpacity: ViewModifier {
    @AppStorage("windowOpacity") private var opacity = 0.7
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // Slider 0.2…1.0 (same scale as email cards) maps to a tint of 0…1 over the blur.
        let tint = max(0, (opacity - 0.2) / 0.8)
        content
            .background {
                ZStack {
                    BehindWindowBlur(dark: scheme == .dark)
                    Color(nsColor: .textBackgroundColor).opacity(tint * tint)
                }
                .ignoresSafeArea()
            }
            .background(ClearWindow(translucent: opacity < 0.999))
    }
}

/// The macOS "behind window" blur, the same material sidebars use.
struct BehindWindowBlur: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        // HUD is the smoky dark glass; popover is its light counterpart. Both let the desktop show through.
        v.material = dark ? .hudWindow : .popover
    }
}

/// Lets the window itself be transparent so the blur shows through.
struct ClearWindow: NSViewRepresentable {
    let translucent: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.acceptsMouseMovedEvents = true
            w.isOpaque = !translucent
            w.backgroundColor = translucent ? .clear : .windowBackgroundColor
        }
    }
}

// MARK: Search filters

struct SearchFilters: View {
    @EnvironmentObject var store: AppStore
    @State private var range = "any"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("From"); personField($store.search.from, "Name or email")
                    label("To"); personField($store.search.to, "Name or email")
                }
                GridRow {
                    label("Subject")
                    TextField("Words in the subject", text: $store.search.subject).textFieldStyle(.roundedBorder).onSubmit { store.runSearch() }
                    label("Date")
                    HStack {
                        Picker("", selection: $range) {
                            Text("Any time").tag("any"); Text("Past week").tag("week"); Text("Past month").tag("month")
                            Text("Past year").tag("year"); Text("Custom…").tag("custom")
                        }.labelsHidden().fixedSize()
                        if range == "custom" {
                            DatePicker("", selection: Binding(get: { store.search.after ?? Date().addingTimeInterval(-30 * 86400) },
                                                              set: { store.search.after = $0 }), displayedComponents: .date).labelsHidden()
                            Text("to").foregroundStyle(.secondary)
                            DatePicker("", selection: Binding(get: { store.search.before ?? Date() }, set: { store.search.before = $0 }),
                                       displayedComponents: .date).labelsHidden()
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                chip("Has attachment", "paperclip", on: $store.search.hasAttachment)
                chip("Unread", "circle.fill", on: $store.search.unreadOnly)
                Spacer()
                Button("Reset") { store.search = SearchQuery(); range = "any" }.buttonBorderShape(.capsule)
                Button("Search") { store.runSearch() }.keyboardShortcut(.defaultAction).prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
        .font(.callout)
        .padding(16)
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 32).padding(.bottom, 10)
        .onChange(of: range) { _, r in
            let days = ["week": 7, "month": 30, "year": 365][r]
            if r == "any" { store.search.after = nil; store.search.before = nil }
            else if let days { store.search.after = Date().addingTimeInterval(Double(-days) * 86400); store.search.before = nil }
        }
    }

    func label(_ t: String) -> some View { Text(t).foregroundStyle(.secondary).gridColumnAlignment(.trailing) }

    /// A text field with contact suggestions as chips underneath.
    func personField(_ text: Binding<String>, _ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).onSubmit { store.runSearch() }
            let people = text.wrappedValue.count >= 2
                ? contactSuggestions(text.wrappedValue, messages: Array(store.messages.values), me: store.me, limit: 4) : []
            if !people.isEmpty, !people.contains(where: { $0.email == text.wrappedValue }) {
                HStack(spacing: 6) {
                    ForEach(people, id: \.email) { a in
                        Button { text.wrappedValue = a.email } label: {
                            HStack(spacing: 5) { Avatar(address: a, size: 16); Text(a.name.isEmpty ? a.email : a.name).lineLimit(1) }
                                .font(.caption).padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }.buttonStyle(.plain).handCursor().help(a.email)
                    }
                }
            }
        }
    }

    func chip(_ title: String, _ icon: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon).font(.callout).padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(on.wrappedValue ? Theme.accent : .primary)
                .background(Capsule().fill(on.wrappedValue ? Theme.selection : Color.primary.opacity(0.06)))
        }.buttonStyle(.plain).handCursor()
    }
}

// MARK: Type-ahead search bar

/// Gmail/Slack-style search: typing predicts people, dates, filters and subjects; picking one locks it in as a chip.
struct TokenSearchBar: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool
    @State private var highlight: Int? = nil

    var suggestions: [SearchSuggestion] {
        EmailCore.searchSuggestions(store.searchText, current: store.search, messages: Array(store.messages.values), me: store.me)
    }

    /// Up to 3 emails matching what's locked in plus what's being typed, to jump straight to.
    var quickMatches: [Conversation] {
        let t = store.searchText.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 || !store.search.isEmpty else { return [] }
        var q = store.search
        if !t.isEmpty, !t.contains(":") { q.words = [q.words, t].filter { !$0.isEmpty }.joined(separator: " ") }
        return Array(store.allConversations.filter { $0.messages.contains { matchesSearch($0, q) } }.prefix(3))
    }

    var body: some View {
        let list = suggestions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                ForEach(tokens, id: \.label) { t in
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(t.label).lineLimit(1)
                        ChipRemoveButton { remove(t.kind) }
                    }
                    .font(.callout).padding(.leading, 9).padding(.trailing, 3).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.selection))
                }
                TextField(tokens.isEmpty ? "Search people, subjects, dates or words" : "Add more…", text: $store.searchText)
                    .textFieldStyle(.plain).focused($focused)
                    .onAppear { focused = true }
                    .onChange(of: store.searchText) { _, _ in highlight = nil }
                    // Keep typing focus here when chips change, so Backspace keeps working on chips.
                    .onChange(of: store.search) { _, _ in if store.searchOpen { focused = true } }
                    .onKeyPress(.downArrow) { highlight = min((highlight ?? -1) + 1, list.count - 1); return .handled }
                    .onKeyPress(.upArrow) { highlight = (highlight ?? 0) > 0 ? highlight! - 1 : nil; return .handled }
                    .onKeyPress(.tab) {
                        guard let s = list.first(where: { if case .words = $0 { return false }; return true }) ?? list.first else { return .ignored }
                        lock(s); return .handled
                    }
                    .onKeyPress(.return) {
                        if let h = highlight, list.indices.contains(h) { lock(list[h]) } else { store.runSearch() }
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard store.searchText.isEmpty, !tokens.isEmpty else { return .ignored }
                        store.removeLastSearchToken(); return .handled
                    }
                Button { store.searchFiltersOpen.toggle() } label: {
                    Image(systemName: "line.3.horizontal.decrease").padding(5)
                        .background(Circle().fill(store.searchFiltersOpen ? Theme.selection : .clear))
                }.buttonStyle(.plain).handCursor().help("More filters")
                Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass(Capsule())
        }
        .frame(maxWidth: 680)
        .overlay(alignment: .topLeading) {
            if focused, !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty, !list.isEmpty {
                dropdown(list).offset(y: 50)
            }
        }
        .zIndex(10)
    }

    func dropdown(_ list: [SearchSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, s in
                Button { lock(s) } label: { row(s, on: i == highlight) }.buttonStyle(.plain).handCursor()
            }
            let matches = quickMatches
            if !matches.isEmpty {
                Text("Emails").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                ForEach(matches) { c in
                    Button { jump(c) } label: {
                        HStack(spacing: 10) {
                            Avatar(address: parseAddresses(c.latest.from).first, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.latest.subject).lineLimit(1)
                                Text(parseAddresses(c.latest.from).first?.display ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(shortDate(c.latest.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).handCursor()
                }
            }
            Text("Tab to pick the top match · ↑↓ to choose · Return to search").font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.top, 6)
        }
        .font(.system(size: 14))
        .padding(8)
        .frame(width: 560, alignment: .leading)
        .solidPanel(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    func row(_ s: SearchSuggestion, on: Bool) -> some View {
        HStack(spacing: 10) {
            switch s {
            case .person(let a, let to):
                Avatar(address: a, size: 22)
                Text(a.name.isEmpty ? a.email : a.name).fontWeight(.medium)
                if !a.name.isEmpty { Text(a.email).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); tag(to ? "To" : "From")
            case .subject(let subj):
                Image(systemName: "text.alignleft").frame(width: 22); Text(subj).lineLimit(1); Spacer(); tag("Subject")
            case .dateRange(let label, _, _):
                Image(systemName: "calendar").frame(width: 22); Text(label); Spacer(); tag("Date")
            case .hasAttachment:
                Image(systemName: "paperclip").frame(width: 22); Text("Has attachment"); Spacer(); tag("Filter")
            case .unread:
                Image(systemName: "circle.fill").font(.system(size: 8)).frame(width: 22); Text("Unread"); Spacer(); tag("Filter")
            case .words(let w):
                Image(systemName: "magnifyingglass").frame(width: 22); Text("Search for “\(w)”"); Spacer(); tag("Words")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.selection : .clear))
        .contentShape(Rectangle())
    }

    func tag(_ t: String) -> some View { Text(t).font(.caption).foregroundStyle(.secondary) }

    // Locked-in filters shown as chips
    enum Kind { case from, to, subject, date, attachment, unread, words }
    struct Token { let kind: Kind; let label: String; let icon: String }
    var tokens: [Token] {
        let q = store.search
        func name(_ e: String) -> String {
            contactSuggestions(e, messages: Array(store.messages.values), me: store.me, limit: 1).first.map { $0.name.isEmpty ? e : $0.name } ?? e
        }
        var out: [Token] = []
        if !q.from.isEmpty { out.append(Token(kind: .from, label: "From: \(name(q.from))", icon: "person")) }
        if !q.to.isEmpty { out.append(Token(kind: .to, label: "To: \(name(q.to))", icon: "person")) }
        if !q.subject.isEmpty { out.append(Token(kind: .subject, label: "Subject: \(q.subject)", icon: "text.alignleft")) }
        if q.after != nil || q.before != nil {
            let f = DateFormatter(); f.dateStyle = .medium
            let label = q.after == q.before ? f.string(from: q.after!) : [q.after.map { "after \(f.string(from: $0))" }, q.before.map { "before \(f.string(from: $0))" }].compactMap { $0 }.joined(separator: ", ")
            out.append(Token(kind: .date, label: label.prefix(1).uppercased() + label.dropFirst(), icon: "calendar"))
        }
        if q.hasAttachment { out.append(Token(kind: .attachment, label: "Has attachment", icon: "paperclip")) }
        if q.unreadOnly { out.append(Token(kind: .unread, label: "Unread", icon: "circle.fill")) }
        if !q.words.isEmpty { out.append(Token(kind: .words, label: "“\(q.words)”", icon: "magnifyingglass")) }
        return out
    }

    func lock(_ s: SearchSuggestion) {
        store.search = apply(s, to: store.search)
        store.searchText = ""
        highlight = nil
        store.runSearch() // results update as soon as something is locked in
        focused = true
    }

    func remove(_ k: Kind) {
        switch k {
        case .from: store.search.from = ""
        case .to: store.search.to = ""
        case .subject: store.search.subject = ""
        case .date: store.search.after = nil; store.search.before = nil
        case .attachment: store.search.hasAttachment = false
        case .unread: store.search.unreadOnly = false
        case .words: store.search.words = ""
        }
        if store.search.isEmpty { store.searchResults = nil; store.folder = nil } else { store.runSearch() }
    }

    func jump(_ c: Conversation) {
        store.searchResults = (store.searchResults ?? []).union([c.id])
        if store.folder == nil { store.folder = "Search: " + (tokens.map(\.label) + [store.searchText]).filter { !$0.isEmpty }.joined(separator: " · ") }
        store.open(c)
    }
}

// MARK: Spelling & grammar

/// Turns on macOS spelling/grammar checking for the compose body (not the To/Subject fields,
/// where autocorrect would mangle addresses). Follows Settings → General → Writing.
struct TextChecking: NSViewRepresentable {
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("grammar") private var grammar = true
    @AppStorage("autocorrect") private var autocorrect = true
    @AppStorage("smartQuotes") private var smartQuotes = false
    @AppStorage("writingToolsButton") private var writingToolsButton = false

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let (s, g, a, q, wt) = (spellcheck, grammar, autocorrect, smartQuotes, writingToolsButton)
        // The editor is created after this view, so apply once the window has laid out.
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let root = v.window?.contentView else { return }
                for tv in Self.textViews(in: root) where !tv.isFieldEditor {
                    tv.isContinuousSpellCheckingEnabled = s
                    tv.isGrammarCheckingEnabled = g
                    tv.isAutomaticSpellingCorrectionEnabled = a
                    tv.isAutomaticQuoteSubstitutionEnabled = q
                    tv.isAutomaticDashSubstitutionEnabled = q
                    // Apple Intelligence's floating Writing Tools button. Off by default: Lightmail has its own Write button.
                    if #available(macOS 15.1, *) { tv.writingToolsBehavior = wt ? .default : .none }
                }
            }
        }
    }
    static func textViews(in v: NSView) -> [NSTextView] {
        (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap { textViews(in: $0) }
    }
}

/// The ✕ on a chip: a 20pt round target (not just the glyph), highlighted on hover.
struct ChipRemoveButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.15 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(hover ? .primary : .secondary)
        .onHover { hover = $0 }
        .handCursor()
        .help("Remove")
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    enum Step { case welcome, connect, google, accounts, ai, done }
    @State private var step: Step = .welcome
    @State private var showICloud = false
    @State private var installedAI: Set<String> = []   // checked once in the background (it can launch a shell)

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 36)
            Spacer(minLength: 20)
            Group {
                switch step {
                case .welcome: welcome
                case .connect: connect
                case .google: googleSetup
                case .accounts: accounts
                case .ai: ai
                case .done: done
                }
            }
            .frame(maxWidth: 560)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 20)
            if let b = store.busy { Label(b, systemImage: "hourglass").font(.callout).foregroundStyle(.secondary).padding(.bottom, 8) }
            if let b = store.banner { Text(b).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 520).padding(.bottom, 12) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: step)
        .card(isPresented: $showICloud) { ICloudSheet() }
        // Each new account moves you to the accounts step.
        .onChange(of: store.state.accounts.count) { old, new in if new > old { store.banner = nil; step = .accounts } }
        .onAppear { if !store.state.accounts.isEmpty { step = .accounts } }
    }

    var progress: some View {
        let order: [Step] = [.welcome, .connect, .accounts, .ai, .done]
        let i = order.firstIndex(of: step == .google ? .connect : step) ?? 0
        return HStack(spacing: 6) {
            ForEach(0..<order.count, id: \.self) { n in
                Capsule().fill(n <= i ? Theme.accent : Color.primary.opacity(0.12)).frame(width: n == i ? 22 : 8, height: 8)
            }
        }
    }

    func title(_ t: String, _ sub: String) -> some View {
        VStack(spacing: 10) {
            Text(t).font(.system(size: 30, weight: .semibold)).multilineTextAlignment(.center)
            Text(sub).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    func primary(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).frame(minWidth: 180).padding(.vertical, 4) }
            .prominentGlassButton().controlSize(.large).buttonBorderShape(.capsule).keyboardShortcut(.defaultAction)
    }

    var welcome: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            title("Welcome to Lightmail", "Fast, keyboard-first email for Gmail and iCloud.")
            VStack(alignment: .leading, spacing: 14) {
                feature("bolt.fill", "Fly through your inbox", "Every action has a shortcut. ⌘K finds any of them.")
                feature("rectangle.split.3x1.fill", "An inbox that sorts itself", "Split Inbox groups people, newsletters and tools apart.")
                feature("sparkles", "Writing help when you want it", "Drafts, replies and summaries from the AI you already use.")
            }
            primary("Get started") { step = .connect }
        }
    }

    func feature(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.headline); Text(d).foregroundStyle(.secondary) }
        }
    }

    var connect: some View {
        VStack(spacing: 24) {
            title("Connect your email", "Your mail goes straight from the provider to this Mac. No servers in between.")
            HStack(spacing: 16) {
                providerCard("envelope.fill", .red, "Gmail", "Google sign-in in your browser") {
                    if store.hasClient { store.addAccount() } else { step = .google }
                }
                providerCard("icloud.fill", .blue, "iCloud Mail", "With an app-specific password") { showICloud = true }
            }
            if !store.state.accounts.isEmpty { Button("Back") { step = .accounts }.buttonBorderShape(.capsule) }
        }
    }

    func providerCard(_ icon: String, _ color: Color, _ name: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(color)
                Text(name).font(.title3.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 220, height: 170)
            .floatingPanel(RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).handCursor()
    }

    var googleSetup: some View {
        VStack(spacing: 16) {
            SetupView().frame(height: 460)
            HStack {
                Button("Back") { step = .connect }.buttonBorderShape(.capsule)
                if store.hasClient { primary("Sign in with Google") { store.addAccount() } }
            }
        }
    }

    var accounts: some View {
        VStack(spacing: 24) {
            title("You're connected", "Add every account you use. You can switch with ⌘1, ⌘2…")
            VStack(spacing: 8) {
                ForEach(store.state.accounts, id: \.self) { a in
                    HStack(spacing: 12) {
                        Image(systemName: store.isICloud(a) ? "icloud.fill" : "envelope.fill").foregroundStyle(store.isICloud(a) ? .blue : .red)
                        Text(a)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .floatingPanel(RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack(spacing: 12) {
                Button { step = .connect } label: { Label("Add another account", systemImage: "plus") }.buttonBorderShape(.capsule).controlSize(.large)
                primary("Continue") { step = .ai }
            }
        }
    }

    var ai: some View {
        VStack(spacing: 24) {
            title("Writing help (optional)", "Lightmail can draft replies, write quick responses and summarize long threads using an AI tool already signed in on this Mac.")
            VStack(spacing: 8) {
                ForEach(AIProvider.all) { p in
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) { Text(p.name).font(.headline); Text(p.maker).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if installedAI.contains(p.id) {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                            if store.state.aiProvider == p.id { Text("Selected").font(.caption).foregroundStyle(Theme.accent) }
                            else { Button("Use") { store.state.aiProvider = p.id }.buttonBorderShape(.capsule) }
                        } else {
                            Button("Get it") { NSWorkspace.shared.open(URL(string: p.installURL)!) }.buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .floatingPanel(RoundedRectangle(cornerRadius: 14))
                }
            }
            Text("AI runs read-only: email content can only produce text. You can change this anytime in Settings → AI Providers.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .task {
                for p in AIProvider.all where await Task.detached(operation: { AI.binary(p.binary) }).value != nil { installedAI.insert(p.id) }
            }
            HStack(spacing: 12) {
                Button("Skip") { step = .done }.buttonBorderShape(.capsule).controlSize(.large)
                primary("Continue") { step = .done }
            }
        }
    }

    var done: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            title("You're all set", "A few keys worth knowing. You'll get short tips inside the app too.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                keyRow("⌘K", "Do anything: search every action")
                keyRow("J  K", "Next and previous email")
                keyRow("E", "Done (archive)")
                keyRow("H", "Remind me later")
                keyRow("/", "Search")
                keyRow("C", "Compose")
            }
            .padding(20).floatingPanel(RoundedRectangle(cornerRadius: 20))
            primary("Open my inbox") {
                UserDefaults.standard.set(0, forKey: "coachStep")
                store.state.onboarded = true
            }
        }
    }

    func keyRow(_ k: String, _ d: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2)))
            Text(d)
        }
    }
}

// MARK: Coach tips

/// Marks a part of the screen a coach tip can point at.
struct CoachAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func coachAnchor(_ id: String) -> some View {
        anchorPreference(key: CoachAnchorKey.self, value: .bounds) { id.isEmpty ? [:] : [id: $0] }
    }
}

/// One tip at a time, floating next to the thing it describes with a spotlight on it.
/// coachStep -1 (the default) means no tips.
struct CoachTips: View {
    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy
    @AppStorage("coachStep") private var step = -1

    static let tips: [(anchor: String, icon: String, title: String, body: String)] = [
        ("palette", "command", "⌘K does everything", "Press ⌘K and type what you want, like \"remind\" or \"forward\". The shortcut shows on the right so you learn it as you go."),
        ("tabs", "rectangle.split.3x1", "Your split inbox", "These tabs group your mail. Press Tab to move between them, or the split button at the end to make your own."),
        ("row", "checkmark.circle", "Inbox zero, fast", "Press E to mark an email done and H to bring it back later. Or hover a row and use the buttons."),
        ("search", "magnifyingglass", "Search like you think", "Press / (or click here) and type a name: pick the person, then add words or a date."),
        ("row", "cursorarrow.click.2", "Prefer the mouse?", "Click to open, right-click any email for every action, and use the buttons under each thread."),
    ]

    var body: some View {
        if Self.tips.indices.contains(step) {
            let tip = Self.tips[step]
            let size = proxy.size
            let target = anchors[tip.anchor].map { proxy[$0] }
            let card = CGSize(width: 340, height: 176)
            // Below the target if it fits, otherwise above; fall back to the bottom-right corner.
            let below = target.map { $0.maxY + 14 + card.height < size.height } ?? true
            let origin: CGPoint = target.map { r in
                CGPoint(x: min(max(r.midX - card.width / 2, 16), size.width - card.width - 16),
                        y: below ? r.maxY + 14 : r.minY - 14 - card.height)
            } ?? CGPoint(x: size.width - card.width - 24, y: size.height - card.height - 40)

            ZStack(alignment: .topLeading) {
                if let r = target {
                    // Soft spotlight: dim everything except the target.
                    Color.black.opacity(0.22)
                        .mask {
                            Rectangle().overlay {
                                RoundedRectangle(cornerRadius: 14).frame(width: r.width + 12, height: r.height + 12)
                                    .position(x: r.midX, y: r.midY).blendMode(.destinationOut)
                            }.compositingGroup()
                        }
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: r.width + 12, height: r.height + 12)
                        .position(x: r.midX, y: r.midY)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                        .allowsHitTesting(false)
                    // Arrow from the card to the target.
                    Image(systemName: below ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 14)).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .position(x: min(max(r.midX, origin.x + 24), origin.x + card.width - 24),
                                  y: below ? origin.y - 6 : origin.y + card.height + 6)
                }
                tipCard(tip).frame(width: card.width).offset(x: origin.x, y: origin.y)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
            .transition(.opacity)
        }
    }

    func tipCard(_ t: (anchor: String, icon: String, title: String, body: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: t.icon).font(.title3).foregroundStyle(Theme.accent)
                Text(t.title).font(.headline)
                Spacer()
                Text("\(step + 1) of \(Self.tips.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text(t.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip tips") { step = -1 }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).handCursor()
                Spacer()
                if step > 0 { Button("Back") { step -= 1 }.buttonBorderShape(.capsule) }
                Button(step == Self.tips.count - 1 ? "Done" : "Next") { step = step == Self.tips.count - 1 ? -1 : step + 1 }
                    .prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
        .padding(18)
        .floatingPanel(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }
}

// MARK: Remote content blocking

enum RemoteContent {
    /// A WebKit rule that blocks every http(s) load inside an email (images, fonts, tracking pixels).
    @MainActor static var blocker: WKContentRuleList?
    @MainActor static func prepare() {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "email-block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#) { list, _ in
            Task { @MainActor in blocker = list }
        }
    }
}

extension UserDefaults {
    func bool(forKey k: String, default d: Bool) -> Bool { object(forKey: k) == nil ? d : bool(forKey: k) }
}

// MARK: Phishing warning

/// A small orange pill in the message header; click it for the reasons. Nothing shows when all looks fine.
struct PhishingPill: View {
    let senderReasons: [String]
    let links: [SuspiciousLink]
    var body: some View {
        if !senderReasons.isEmpty || !links.isEmpty {
            MenuButton(width: 340, entries: { [] }, custom: { AnyView(details) }) {
                Label(senderReasons.isEmpty ? "\(links.count) suspicious link\(links.count == 1 ? "" : "s")" : "Check sender",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
            .buttonStyle(.plain).handCursor()
        }
    }

    var details: some View {
                VStack(alignment: .leading, spacing: 10) {
                    Label("This email might be phishing", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange)
                    ForEach(senderReasons, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
                    ForEach(links.prefix(5), id: \.href) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• " + l.reason).fixedSize(horizontal: false, vertical: true)
                            Text(l.href).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Text("Don't enter passwords or payment details from this email. If unsure, go to the company's site directly.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
    }
}

// MARK: Settings → Gmail (out of office, signature sync, labels)

struct GmailSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var account = ""
    @State private var v = Vacation()
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var vacationNote: String?
    @State private var sendAs: [Gmail.SendAs] = []
    @State private var sigNote: [String: String] = [:]
    @State private var newLabel = ""
    @State private var deleting: Gmail.Label?

    var body: some View {
        Group {
            if store.gmailAccounts.isEmpty {
                Text("Add a Gmail account in Accounts to manage its settings here.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Picker("Account", selection: $account) {
                        ForEach(store.gmailAccounts, id: \.self) { Text(store.fullLabel($0)).tag($0) }
                    }
                    if store.needsSettingsAccess.contains(account) { accessCallout }
                    outOfOffice
                    signatures
                    labels
                }
                .formStyle(.grouped).scrollContentBackground(.hidden)
            }
        }
        .padding()
        .onAppear { if account.isEmpty { account = store.gmailAccounts.first ?? "" } }
        .task(id: account) { await load() }
        .confirmCard(deleting.map { "Delete the label “\($0.name)”?" }, message: "Emails keep everything else; they just lose this label. This can't be undone.",
                     confirm: "Delete label", icon: "tag.slash", cancel: { deleting = nil }) {
            if let l = deleting { let a = account; store.labelAction(a) { try await store.gmail(a).deleteLabel(l.id) } }
            deleting = nil
        }
    }

    func load() async {
        guard !account.isEmpty else { return }
        await store.checkSettingsAccess(account)
        if let vac = await store.settingsCall(account, { try await store.gmail(account).vacation() }) {
            v = vac; hasStart = vac.start != nil; hasEnd = vac.end != nil; store.vacations[account] = vac
        }
        sendAs = await store.settingsCall(account, { try await store.gmail(account).sendAs() }) ?? []
        await store.loadLabels(account)
    }

    var accessCallout: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Lightmail needs one more Google permission for out of office and signatures", systemImage: "lock.shield").font(.headline)
                Text("First, in Google Cloud Console → Google Auth Platform → Data Access → Add or remove scopes, add “…/auth/gmail.settings.basic” and save. Then click below and approve in your browser.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Google Cloud Console") { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/auth/scopes")!) }
                    Button("Grant access") { store.grantSettingsAccess() }.prominentGlassButton().buttonBorderShape(.capsule)
                }
            }
        }
    }

    var outOfOffice: some View {
        Section("Out of office") {
            Toggle("Auto-reply while I'm away", isOn: $v.enabled)
            Toggle("Starts", isOn: $hasStart)
            if hasStart { DatePicker("", selection: Binding(get: { v.start ?? Date() }, set: { v.start = $0 })).labelsHidden() }
            Toggle("Ends", isOn: $hasEnd)
            if hasEnd { DatePicker("", selection: Binding(get: { v.end ?? Date().addingTimeInterval(7 * 86400) }, set: { v.end = $0 })).labelsHidden() }
            TextField("Subject", text: $v.subject, prompt: Text("Out of office"))
            TextEditor(text: $v.message).frame(height: 90).font(.system(size: 13))
                .overlay(alignment: .topLeading) { if v.message.isEmpty { Text("Message").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false) } }
            Toggle("Only reply to people in my contacts", isOn: $v.contactsOnly)
            if !account.hasSuffix("@gmail.com") { Toggle("Only reply to people in my organization", isOn: $v.domainOnly) }
            HStack {
                if let vacationNote { Text(vacationNote).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Save") {
                    var out = v
                    if !hasStart { out.start = nil }
                    if !hasEnd { out.end = nil }
                    let a = account
                    Task { vacationNote = await store.saveVacation(out, for: a) ? "Saved to Gmail." : nil }
                }.prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
    }

    var signatures: some View {
        Section("Signature sync") {
            Text("Gmail keeps its own copy of your signature for gmail.com and the Gmail phone app. Copy one way or the other to make them match.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sendAs.isEmpty { Text("No addresses found for this account.").foregroundStyle(.secondary) }
            ForEach(sendAs) { sa in SignatureSyncRow(sendAs: sa, account: account) { sendAs = $0 } }
        }
    }

    var labels: some View {
        Section("Labels") {
            ForEach(store.gmailLabels[account] ?? []) { l in
                HStack(spacing: 10) {
                    Menu {
                        ForEach(gmailLabelColors, id: \.bg) { c in
                            Button { let a = account; store.labelAction(a) { try await store.gmail(a).updateLabel(l.id, color: c) } } label: {
                                Label(c.bg, systemImage: "circle.fill")
                            }
                        }
                    } label: {
                        Circle().fill(Color(hex: l.bg) ?? Color.secondary.opacity(0.4)).frame(width: 14, height: 14)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Color")
                    LabelNameField(name: l.name) { new in
                        let a = account; store.labelAction(a) { try await store.gmail(a).updateLabel(l.id, name: new) }
                    }
                    Button { deleting = l } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete label")
                }
            }
            HStack {
                TextField("New label", text: $newLabel).onSubmit(addLabel)
                Button("Add", action: addLabel).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Use labels on any email from the right-click menu, ⌘K, or press L.").font(.caption).foregroundStyle(.secondary)
        }
    }

    func addLabel() {
        let name = newLabel.trimmingCharacters(in: .whitespaces), a = account
        guard !name.isEmpty else { return }
        newLabel = ""
        store.labelAction(a) { try await store.gmail(a).createLabel(name) }
    }
}

/// Renames on Return or when you click away, not on every keystroke.
struct LabelNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Label", text: $text).textFieldStyle(.plain).focused($focused)
            .onAppear { text = name }
            .onSubmit { save() }
            .onChange(of: focused) { _, f in if !f { save() } }
    }
    func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != name { commit(t) } else { text = name }
    }
}

extension Color {
    init?(hex: String?) {
        guard let h = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// One address: Email's signature and Gmail's, side by side, with a copy arrow each way.
struct SignatureSyncRow: View {
    @EnvironmentObject var store: AppStore
    let sendAs: Gmail.SendAs
    let account: String
    let refreshed: ([Gmail.SendAs]) -> Void
    @State private var note: String?
    @State private var working = false

    var body: some View {
        let ours = signatureParts(store.signature(for: sendAs.email))
        let oursHTML = ours.html ?? (ours.plain.isEmpty ? "" : plainToHTML(ours.plain))
        let theirs = sendAs.signature
        let same = normalize(plainFromHTML(oursHTML)) == normalize(plainFromHTML(theirs))
        let blocked = gmailSignatureProblem(oursHTML)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(sendAs.email).fontWeight(.medium)
                if sendAs.isPrimary { Text("Primary").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                status(same: same, ours: oursHTML, theirs: theirs)
            }
            HStack(alignment: .center, spacing: 10) {
                preview("In Lightmail", oursHTML, empty: "No signature in Lightmail")
                VStack(spacing: 8) {
                    Button { run { await store.pushSignature(sendAs.email, account: account) } } label: {
                        Label("Copy to Gmail", systemImage: "arrow.right").labelStyle(.titleAndIcon)
                    }
                    .disabled(oursHTML.isEmpty || same || blocked != nil || working)
                    .help(blocked ?? "Replace Gmail's signature with Lightmail's")
                    Button { run { await store.pullSignature(sendAs.email, account: account) } } label: {
                        Label("Copy to Lightmail", systemImage: "arrow.left")
                    }
                    .disabled(theirs.isEmpty || same || working)
                    .help("Replace Lightmail's signature with Gmail's")
                }
                .buttonBorderShape(.capsule).controlSize(.small).fixedSize()
                preview("In Gmail", theirs, empty: "No signature in Gmail")
            }
            if let blocked, !same { Label(blocked, systemImage: "info.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    func run(_ f: @escaping () async -> String) {
        working = true
        Task {
            note = await f()
            refreshed((try? await store.gmail(account).sendAs()) ?? [sendAs])
            working = false
        }
    }

    func normalize(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    @ViewBuilder func status(same: Bool, ours: String, theirs: String) -> some View {
        if ours.isEmpty && theirs.isEmpty { Text("No signatures yet").font(.caption).foregroundStyle(.secondary) }
        else if same { Label("In sync", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
        else { Label("Different", systemImage: "arrow.left.arrow.right.circle").font(.caption).foregroundStyle(.orange) }
    }

    func preview(_ title: String, _ html: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if html.isEmpty {
                    Text(empty).font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4])))
                } else {
                    EmailWebView(html: html, padding: "8px 10px").frame(maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


// MARK: Lightmail menus, cards and confirmations (replace the stock Mac menus, sheets and alerts)

struct CloseCard { var run: () -> Void = {}; func callAsFunction() { run() } }
private struct CloseCardKey: EnvironmentKey { static let defaultValue = CloseCard() }
extension EnvironmentValues { var closeCard: CloseCard { get { self[CloseCardKey.self] } set { self[CloseCardKey.self] = newValue } } }

/// A button that opens a Lightmail menu below itself. Works anywhere inside the main window.
struct MenuButton<Label: View>: View {
    @EnvironmentObject var store: AppStore
    var width: CGFloat = 290
    var trailing = false
    let entries: () -> [MenuEntry]
    var custom: (() -> AnyView)? = nil
    @ViewBuilder let label: () -> Label
    @State private var frame: CGRect = .zero
    var body: some View {
        Button { store.showPopup(entries(), anchor: frame, width: width, trailing: trailing, custom: custom?()) } label: { label() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("main")) } action: { frame = $0 }
    }
}

/// Draws the open menu above everything in the main window. Click outside or press Esc to close.
struct PopupLayer: View {
    @EnvironmentObject var store: AppStore
    @State private var height: CGFloat = 0
    var body: some View {
        if let p = store.popup {
            GeometryReader { geo in
                let a = p.anchor
                let x = min(max(12, p.trailing ? a.maxX - p.width : a.minX), geo.size.width - p.width - 12)
                let below = a.maxY + (a.height > 0 ? 6 : 2)
                let y = below + height > geo.size.height - 12 ? max(12, a.minY - height - 6) : below
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).onTapGesture { store.closePopup() }
                    panel(p, maxHeight: geo.size.height - 24)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                        .offset(x: x, y: y)
                }
            }
            .transition(.opacity)
        }
    }

    func panel(_ p: Popup, maxHeight: CGFloat) -> some View {
        Group {
            if let custom = p.custom { custom }
            else {
                let list = VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(p.entries.enumerated()), id: \.element.id) { i, e in row(e, i) }
                }.padding(6)
                ViewThatFits(in: .vertical) { list; ScrollView { list } }
            }
        }
        .frame(width: p.width, alignment: .leading)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .solidPanel(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
    }

    @ViewBuilder func row(_ e: MenuEntry, _ i: Int) -> some View {
        switch e.kind {
        case .divider: Divider().padding(.vertical, 4).padding(.horizontal, 8)
        case .header:
            Text(e.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
        case .item:
            let on = store.popupIndex == i
            Button { store.activatePopup(i) } label: {
                HStack(spacing: 10) {
                    if let l = e.letter {
                        Circle().fill(Theme.chip(l).opacity(0.2)).frame(width: 26, height: 26)
                            .overlay(Text(String(e.title.prefix(1)).uppercased()).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.chip(l)))
                    } else if let icon = e.icon {
                        Image(systemName: icon).font(.system(size: 13)).frame(width: 22)
                            .foregroundStyle(e.destructive ? Color.red : Color.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 13, weight: e.letter != nil ? .medium : .regular)).lineLimit(1)
                            .foregroundStyle(e.destructive ? Color.red : Color.primary)
                        if let sub = e.subtitle { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    if e.checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                    if let k = e.key { Text(k).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).monospacedDigit() }
                    if e.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 8).frame(minHeight: e.subtitle != nil || e.letter != nil ? 40 : 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.primary.opacity(0.08) : e.checked ? Theme.selection : .clear))
                .contentShape(Rectangle())
                .opacity(e.disabled ? 0.45 : 1)
            }
            .buttonStyle(.plain).handCursor().disabled(e.disabled)
            .onHover { if $0 { store.popupIndex = i } else if store.popupIndex == i { store.popupIndex = nil } }
        }
    }
}

/// Compose, split settings, events, snippets, summaries and link warnings float as cards over a dimmed window.
struct ModalLayer: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if store.modalOpen {
                    Color.black.opacity(0.28).ignoresSafeArea()
                        .onTapGesture { if store.summary != nil { store.summary = nil } else if store.linkPrompt != nil { store.linkPrompt = nil } }
                        .transition(.opacity)
                }
                if let m = store.composing {
                    card { ComposeView(model: m).frame(maxWidth: min(geo.size.width - 48, 880), maxHeight: min(geo.size.height - 48, 700)) }
                        .environment(\.closeCard, CloseCard { store.composing = nil })
                } else if let snip = store.editingSnippet {
                    card { SnippetEditor(snippet: snip) }.environment(\.closeCard, CloseCard { store.editingSnippet = nil })
                } else if store.splitSettingsOpen {
                    card { SplitSettingsView().frame(maxHeight: min(geo.size.height - 48, 620)) }
                        .environment(\.closeCard, CloseCard { store.splitSettingsOpen = false })
                } else if let ev = store.eventDraft {
                    card { EventSheet(draft: ev) }.environment(\.closeCard, CloseCard { store.eventDraft = nil })
                } else if let text = store.summary {
                    card { SummaryCard(text: text) }
                }
                if let lp = store.linkPrompt { card { LinkWarningCard(prompt: lp) } }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeOut(duration: 0.16), value: store.modalOpen)
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .glassButtons()
            .solidPanel(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

struct SummaryCard: View {
    @EnvironmentObject var store: AppStore
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Summary", systemImage: "text.append").font(.title3.weight(.semibold))
                Spacer()
                Button { store.summary = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help("Close (Esc)")
            }
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(24).frame(width: 540, height: 380)
    }
}

struct LinkWarningCard: View {
    @EnvironmentObject var store: AppStore
    let prompt: LinkPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 22)).foregroundStyle(.orange)
                    .frame(width: 44, height: 44).background(Circle().fill(Color.orange.opacity(0.14)))
                Text("This link may not be safe").font(.title3.weight(.semibold))
            }
            Text(prompt.reason).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("It really opens").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(prompt.url.host ?? prompt.url.absoluteString).font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(prompt.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("Open anyway") { NSWorkspace.shared.open(prompt.url); store.linkPrompt = nil }.buttonStyle(.plain).foregroundStyle(.secondary).handCursor()
                Spacer()
                Button("Don't open") { store.linkPrompt = nil }.prominentGlassButton().controlSize(.large)
            }
        }
        .padding(24).frame(width: 440)
    }
}

extension View {
    /// A Lightmail confirmation card over this view (any window). Shows while `title` is non-nil.
    func confirmCard(_ title: String?, message: String, confirm: String, icon: String, cancel: @escaping () -> Void, action: @escaping () -> Void) -> some View {
        overlay {
            if let title {
                ZStack {
                    Color.black.opacity(0.28).onTapGesture(perform: cancel)
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.red)
                            .frame(width: 42, height: 42).background(Circle().fill(Color.red.opacity(0.12)))
                        Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                            Button(confirm, role: .destructive, action: action).tint(.red).buttonStyle(.borderedProminent)
                        }.padding(.top, 4)
                    }
                    .padding(22).frame(width: 380)
                    .solidPanel(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                }
                .transition(.opacity)
            }
        }
    }
}

extension View {
    /// Shows `content` as a Lightmail card over this view (works in any window, e.g. onboarding or Settings).
    func card<C: View>(isPresented: Binding<Bool>, closeButton: Bool = false, @ViewBuilder _ content: @escaping () -> C) -> some View {
        overlay {
            if isPresented.wrappedValue {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    content()
                        .overlay(alignment: .topTrailing) {
                            if closeButton {
                                Button { isPresented.wrappedValue = false } label: {
                                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().keyboardShortcut(.cancelAction).help("Close (Esc)")
                                .padding(14)
                            }
                        }
                        .glassButtons()
                        .environment(\.closeCard, CloseCard { isPresented.wrappedValue = false })
                        .solidPanel(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.3), radius: 40, y: 16)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isPresented.wrappedValue)
    }
}

// MARK: Settings → About

struct AboutSettings: View {
    @ObservedObject private var updates = Updates.shared
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                Text("Lightmail").font(.system(size: 24, weight: .semibold))
                Text("Version \(Updates.version) (\(Updates.build))").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Fast, keyboard-first email for Gmail and iCloud.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updates").font(.headline)
                        Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates") { updates.check() }.disabled(!updates.enabled || !updates.canCheck)
                }
                if updates.enabled {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
                }
            }
            .padding(16).frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 8) {
                info("Privacy", "Mail goes straight between this Mac and Google or Apple. Lightmail has no servers.")
                info("AI", "Runs through the AI app you choose in AI Providers, signed in on this Mac.")
                info("Requires", "macOS 14 or later")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Your data").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Disk.dir]) }.buttonStyle(.link).handCursor()
                }
            }
            .font(.callout).frame(maxWidth: 460, alignment: .leading)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/dcdunk/lightmail-app")!)
                Link("Release notes", destination: URL(string: "https://github.com/dcdunk/lightmail-app/releases")!)
                Link("Report a problem", destination: URL(string: "https://github.com/dcdunk/lightmail-app/issues/new")!)
            }
            .font(.callout).handCursor()
            Spacer()
            Text("© 2026 Danny Chait. Updates by Sparkle (MIT license).").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(24).frame(maxWidth: .infinity)
    }

    var updateStatus: String {
        guard updates.enabled else { return "This is a development build. Release builds update themselves." }
        guard let d = updates.lastChecked else { return "Not checked yet" }
        return "Last checked \(d.formatted(.relative(presentation: .named)))"
    }

    func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
