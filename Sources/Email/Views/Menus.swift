import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

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
            MenuEntry(title: "Reply", icon: "arrowshape.turn.up.left", key: Hotkeys.label("r")) { self.act(on: c, reading: true) { self.reply(all: false) } },
            MenuEntry(title: "Reply all", icon: "arrowshape.turn.up.left.2", key: Hotkeys.label("a")) { self.act(on: c, reading: true) { self.reply(all: true) } },
            MenuEntry(title: "Forward", icon: "arrowshape.turn.up.right", key: Hotkeys.label("f")) { self.act(on: c, reading: true) { self.forward() } },
            .divider,
            MenuEntry(title: "Mark done", icon: "checkmark", key: Hotkeys.label("e")) { self.act(on: c) { self.markDone() } },
            MenuEntry(title: c.isStarred ? "Unstar" : "Star", icon: c.isStarred ? "star.slash" : "star", key: Hotkeys.label("s")) { self.act(on: c) { self.toggleStar() } },
            MenuEntry(title: c.isUnread ? "Mark as read" : "Mark as unread", icon: c.isUnread ? "envelope.open" : "envelope.badge", key: Hotkeys.label("u")) { self.act(on: c) { self.toggleUnread() } },
            MenuEntry(title: "Remind me", icon: "clock", key: Hotkeys.label("h"),
                      submenu: remindEntries(c, ifNoReply: true) + [.divider] + remindEntries(c, ifNoReply: false)),
            MenuEntry(title: state.muted.contains(c.id) ? "Unmute" : "Mute", icon: state.muted.contains(c.id) ? "bell" : "bell.slash", key: "⇧M") { self.act(on: c) { self.toggleMute() } },
        ]
        // Move to: the same places you can drag an email to in the sidebar.
        var moves: [MenuEntry] = []
        if !c.inInbox { moves.append(MenuEntry(title: "Inbox", icon: "tray") { self.drop(c.id, on: "Inbox") }) }
        if c.inInbox { moves.append(MenuEntry(title: "Done", icon: "checkmark") { self.drop(c.id, on: "Done") }) }
        moves.append(MenuEntry(title: "Spam", icon: "xmark.bin") { self.drop(c.id, on: "Spam") })
        moves.append(MenuEntry(title: "Trash", icon: "trash") { self.drop(c.id, on: "Trash") })
        let mine = (gmailLabels[c.account] ?? []).map(\.name).filter { panelLabels.contains($0) }
        if !mine.isEmpty { moves += [.divider] + mine.map { n in MenuEntry(title: n, icon: "tag") { self.drop(c.id, on: n) } } }
        e.append(MenuEntry(title: "Move to", icon: "folder", submenu: moves))
        if isGmail(c.account), let labels = gmailLabels[c.account], !labels.isEmpty {
            e.append(MenuEntry(title: "Label", icon: "tag", key: Hotkeys.label("l"), submenu: labels.map { l in
                MenuEntry(title: l.name, icon: "tag", checked: c.labels.contains(l.id)) { self.setLabel(l.id, on: c, !c.labels.contains(l.id)) }
            }))
        }
        let important = isImportant(c, context(allConversations))
        e += [.divider, MenuEntry(title: "Move to \(important ? "Other" : "Important")", icon: important ? "tray" : "exclamationmark.circle") { self.setImportance(c.id, important: !important) }]
        if !c.latest.listUnsubscribe.isEmpty { e.append(MenuEntry(title: "Unsubscribe", icon: "hand.raised", key: "⇧U") { self.act(on: c) { self.unsubscribe() } }) }
        e += [.divider, MenuEntry(title: "Mark as junk", icon: "xmark.bin", key: Hotkeys.label("!")) { self.act(on: c) { self.markJunk() } },
              MenuEntry(title: "Delete", icon: "trash", key: "⌫", destructive: true) { self.act(on: c) { self.trash() } }]
        return e
    }

    /// Account switcher, shared by the top bar and the folder panel.
    func accountEntries() -> [MenuEntry] {
        var e: [MenuEntry] = [.header("Accounts")]
        for (i, a) in state.accounts.enumerated() {
            let shown = sendAddress(a)   // the address you send as (an alias, if you picked one)
            e.append(MenuEntry(title: label(a), subtitle: label(a) == a ? (shown == a ? nil : shown) : shown, letter: a, key: i < 9 ? "⌘\(i + 1)" : nil,
                               checked: state.activeAccount == a) { self.switchAccount(a) })
        }
        if state.accounts.count > 1 {
            e.append(MenuEntry(title: "All accounts", icon: "tray.2", key: "⌘0", checked: state.activeAccount == nil) { self.switchAccount(nil) })
        }
        e += [.divider,
              MenuEntry(title: "Add Email Account", icon: "plus") { self.openSettings(tab: "accounts") },
              MenuEntry(title: "Settings", icon: "gearshape", key: "⌘,") { self.openSettings() }]
        return e
    }
}

// MARK: Keymail menus, cards and confirmations (replace the stock Mac menus, sheets and alerts)

struct CloseCard { var run: () -> Void = {}; func callAsFunction() { run() } }
private struct CloseCardKey: EnvironmentKey { static let defaultValue = CloseCard() }
extension EnvironmentValues { var closeCard: CloseCard { get { self[CloseCardKey.self] } set { self[CloseCardKey.self] = newValue } } }

/// A button that opens a Keymail menu below itself. Works anywhere inside the main window.
private struct PopupHostKey: EnvironmentKey { static let defaultValue = "main" }
extension EnvironmentValues { var popupHost: String { get { self[PopupHostKey.self] } set { self[PopupHostKey.self] = newValue } } }

struct MenuButton<Label: View>: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.popupHost) private var host
    var width: CGFloat = 290
    var trailing = false
    let entries: () -> [MenuEntry]
    var custom: (() -> AnyView)? = nil
    @ViewBuilder let label: () -> Label
    @State private var frame: CGRect = .zero
    var body: some View {
        Button { store.showPopup(entries(), anchor: frame, width: width, trailing: trailing, custom: custom?(), host: host) } label: { label() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("main")) } action: { frame = $0 }
    }
}

/// Draws the open menu above everything in the main window. Click outside or press Esc to close.
struct PopupLayer: View {
    @EnvironmentObject var store: AppStore
    var host = "main"
    @State private var height: CGFloat = 0
    var body: some View {
        if let p = store.popup, p.host == host {
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
            .allowsHitTesting(store.popup != nil)
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
            Text(e.title).font(.scaled(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
        case .item:
            let on = store.popupIndex == i
            Button { store.activatePopup(i) } label: {
                HStack(spacing: 10) {
                    if let l = e.letter {
                        let tint = store.state.accounts.contains(l) ? store.accountColor(l) : Theme.chip(l)
                        Circle().fill(tint.opacity(0.2)).frame(width: 26, height: 26)
                            .overlay(Text(String(e.title.prefix(1)).uppercased()).font(.scaled(size: 11.5, weight: .semibold)).foregroundStyle(tint))
                    } else if let icon = e.icon {
                        Image(systemName: icon).font(.scaled(size: 13)).frame(width: 22)
                            .foregroundStyle(e.destructive ? Color.red : Color.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.scaled(size: 13, weight: e.letter != nil ? .medium : .regular)).lineLimit(1)
                            .foregroundStyle(e.destructive ? Color.red : Color.primary)
                        if let sub = e.subtitle { Text(sub).font(.scaled(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    if e.checked { Image(systemName: "checkmark").font(.scaled(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                    if let k = e.key { KeyHint(k) }
                    if e.submenu != nil { Image(systemName: "chevron.right").font(.scaled(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
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
                        .allowsHitTesting(store.modalOpen)
                        .transition(.opacity)
                }
                // Compose lives in its own window (ComposeWindow) or inline in the conversation, never here.
                if let snip = store.editingSnippet {
                    card { SnippetEditor(snippet: snip) }.environment(\.closeCard, CloseCard { store.editingSnippet = nil })
                } else if store.splitSettingsOpen {
                    card { SplitSettingsView().frame(maxHeight: min(geo.size.height - 48, 620)) }
                        .environment(\.closeCard, CloseCard { store.splitSettingsOpen = false })
                } else if let ev = store.eventDraft {
                    card { EventSheet(draft: ev) }.environment(\.closeCard, CloseCard { store.eventDraft = nil })
                } else if let ap = store.agentApproval {
                    card { AgentApprovalCard(approval: ap) }
                } else if let t = store.claudeTask {
                    card { ClaudeTaskCard(task: t) }.environment(\.closeCard, CloseCard { store.claudeTask = nil })
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
                Label("Summary", systemImage: "text.append").font(.scaled(.title3).weight(.semibold))
                Spacer()
                Button { store.summary = nil } label: { Image(systemName: "xmark").font(.scaled(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
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
                Image(systemName: "exclamationmark.shield.fill").font(.scaled(size: 22)).foregroundStyle(.orange)
                    .frame(width: 44, height: 44).background(Circle().fill(Color.orange.opacity(0.14)))
                Text("This link may not be safe").font(.scaled(.title3).weight(.semibold))
            }
            Text(prompt.reason).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("It really opens").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                Text(prompt.url.host ?? prompt.url.absoluteString).font(.scaled(.callout, design: .monospaced).weight(.semibold))
                Text(prompt.url.absoluteString).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("Open anyway") { NSWorkspace.shared.open(prompt.url); store.linkPrompt = nil }.quiet().help("Open anyway (⌘↵)")
                Spacer()
                Button("Don't open") { store.linkPrompt = nil }.primaryAction()
            }
        }
        .padding(24).frame(width: 440)
    }
}

extension View {
    /// A Keymail confirmation card over this view (any window). Shows while `title` is non-nil.
    func confirmCard(_ title: String?, message: String, confirm: String, icon: String, cancel: @escaping () -> Void, action: @escaping () -> Void) -> some View {
        overlay {
            if let title {
                ZStack {
                    Color.black.opacity(0.28).onTapGesture(perform: cancel)
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: icon).font(.scaled(size: 20)).foregroundStyle(.red)
                            .frame(width: 42, height: 42).background(Circle().fill(Color.red.opacity(0.12)))
                        Text(title).font(.scaled(.title3).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Cancel", action: cancel).quiet().keyboardShortcut(.cancelAction)
                            Button(confirm, role: .destructive, action: action).tint(.red).primaryAction().keyboardShortcut(.defaultAction)
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
    /// Shows `content` as a Keymail card over this view (works in any window, e.g. onboarding or Settings).
    func card<C: View>(isPresented: Binding<Bool>, closeButton: Bool = false, @ViewBuilder _ content: @escaping () -> C) -> some View {
        overlay {
            if isPresented.wrappedValue {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    content()
                        .overlay(alignment: .topTrailing) {
                            if closeButton {
                                Button { isPresented.wrappedValue = false } label: {
                                    Image(systemName: "xmark").font(.scaled(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
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
