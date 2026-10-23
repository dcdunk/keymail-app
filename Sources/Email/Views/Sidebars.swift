import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Sidebars

/// Slide-out folder panel, modeled on Superhuman's: account at top, folders, then labels.
struct FolderPanel: View {
    @EnvironmentObject var store: AppStore
    @State private var hovered: String?   // mouse highlight; separate from the ↑/↓ highlight so hovering never scrolls
    @State private var dropTarget: String?   // the folder an email is being dragged over
    var body: some View {
        let account = store.state.activeAccount
        let inboxCount = store.allConversations.filter(\.inInbox).count
        let labels = store.panelLabels
        VStack(alignment: .leading, spacing: 0) {
            MenuButton(width: 320, entries: { store.accountEntries() }) {
                HStack(spacing: 10) {
                    let name = account.map(store.label) ?? (store.state.accounts.count > 1 ? "All accounts" : store.state.accounts.first.map(store.label) ?? "")
                    Circle().fill(Theme.chip(name).opacity(0.25)).frame(width: 30, height: 30)
                        .overlay(Text(String(name.prefix(1)).uppercased()).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.chip(name)))
                    Text(name).font(.scaled(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.scaled(size: 10)).foregroundStyle(.tertiary)
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
                            highlighted: store.sidebarFocused && store.panelIndex == i) { store.activatePanel(i) }
                    }
                    if store.calendarEnabled {
                        row("Calendar", key: "G C", on: false) { store.openCalendar() }
                    }
                    if !labels.isEmpty {
                        Divider().padding(.vertical, 12).padding(.horizontal, 18)
                        Text("Labels").font(.scaled(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 18).padding(.bottom, 6)
                        ForEach(Array(labels.enumerated()), id: \.element) { i, l in
                            let idx = AppStore.panelFolders.count + i
                            row(l, indent: true, on: store.folder == l, highlighted: store.sidebarFocused && store.panelIndex == idx) { store.activatePanel(idx) }
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
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        // Same glass and spacing as the context panel on the right: it sits beside the inbox, not over it.
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.leading, 10).padding(.vertical, 10).padding(.top, 24)
    }

    func row(_ title: String, subtitle: String? = nil, count: Int = 0, key: String = "", indent: Bool = false, on: Bool,
             highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.scaled(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.scaled(size: 12)).foregroundStyle(.tertiary) }
                Spacer()
                if count > 0 { Text("\(count)").font(.scaled(size: 12).monospacedDigit()).foregroundStyle(.secondary) }
                else if !key.isEmpty { KeyHint(key, size: 10) }
            }
            .padding(.leading, indent ? 30 : 18).padding(.trailing, 18).padding(.vertical, 8)
            .background(alignment: .leading) {
                // The open folder: filled, with the accent bar. Mouse hover: a soft fill.
                if on {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.selection)
                        Rectangle().fill(Theme.accent).frame(width: 3)
                    }
                } else if dropTarget == title {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.18)).padding(.horizontal, 8)
                } else if hovered == title {
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).padding(.horizontal, 8)
                }
            }
            .overlay {
                // Keyboard cursor (↑/↓): an outline ring, clearly not "selected". Return opens it.
                if highlighted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 1.5).padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain).handCursor()
        .onHover { inside in
            if inside { hovered = title } else if hovered == title { hovered = nil }
        }
        // Drop an email here to move, star, archive, delete or label it.
        .dropDestination(for: String.self) { ids, _ in
            guard store.acceptsDrop(title), let id = ids.first else { return false }
            return store.drop(id, on: title)
        } isTargeted: { over in
            if over, store.acceptsDrop(title) { dropTarget = title } else if dropTarget == title { dropTarget = nil }
        }
    }
}

/// Right panel: who you're talking to, quick actions for them, what you've shared, and your day.
struct ContextPanel: View {
    @EnvironmentObject var store: AppStore
    let conversation: Conversation
    var body: some View {
        let person = parseAddresses(conversation.messages.last { m in !store.me.contains(parseAddresses(m.from).first?.email.lowercased() ?? "") }?.from
                                    ?? conversation.latest.to).first
        let all = store.allConversations
        let email = person?.email.lowercased() ?? ""
        let withThem = all.filter { c in c.messages.contains { parseAddresses($0.from + "," + $0.to + "," + $0.cc).contains { $0.email.lowercased() == email } } }
        let history = withThem.filter { $0.id != conversation.id }.sorted { $0.latest.date > $1.latest.date }
        let files = withThem.flatMap { c in c.messages.flatMap { m in m.attachments.filter { !$0.isInline }.map { (m, $0) } } }
            .sorted { $0.0.date > $1.0.date }
        let recent = store.recentlyOpened.filter { $0 != conversation.id }.compactMap { id in all.first { $0.id == id } }
        let info = VStack(alignment: .leading, spacing: 20) {
                if let person { header(person, email: email, count: withThem.count, first: withThem.map(\.messages[0].date).min()) }
                section("History", count: history.count, hidden: history.isEmpty) {
                    ForEach(history.prefix(5)) { c in row(c) }
                }
                section("Files", count: files.count, hidden: files.isEmpty) {
                    ForEach(files.prefix(4), id: \.1.id) { m, f in
                        Button { store.preview(account: m.account, messageId: m.id, attachmentId: f.id, name: f.name) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: fileIcon(f.name)).font(.scaled(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                                Text(f.name).font(.scaled(.callout)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(shortDate(m.date)).font(.scaled(.caption)).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 8).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(ToolStyle()).help("Quick Look \(f.name)")
                    }
                }
                section("Recently opened", count: 0, hidden: recent.isEmpty) { ForEach(recent.prefix(4)) { c in row(c) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
        // Your day, set apart by a divider so it doesn't read as being about this person.
        let day = VStack(alignment: .leading, spacing: 10) {
            CalendarSection(conversation: conversation)
            let due = store.state.snoozes.filter { Calendar.current.isDateInToday($0.until) }.count
            Text("\(due) reminder\(due == 1 ? "" : "s") returning today · \(store.state.scheduled.count) scheduled")
                .font(.scaled(.caption)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
        // Today's events sit right under the person when everything fits; only a long panel scrolls and pins them to the bottom (issue #9).
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) { info; day; Spacer(minLength: 0) }
            VStack(spacing: 0) { ScrollView { info }; day }
        }
        .frame(width: 280)
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.trailing, 10).padding(.vertical, 10).padding(.top, 24)
    }

    func header(_ person: Address, email: String, count: Int, first: Date?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(address: person, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.display).font(.scaled(.headline)).lineLimit(1)
                    Text(person.email).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Text("\(count) conversation\(count == 1 ? "" : "s")\(first.map { " · since \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? "")")
                .font(.scaled(.caption)).foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                tool("square.and.pencil", "Email \(person.firstName.isEmpty ? person.display : person.firstName)") {
                    var d = Draft(from: store.sendAddress(store.defaultAccount)); d.to = person.email
                    _ = store.openCompose(d, context: nil)
                }
                tool("magnifyingglass", "All mail with \(person.email)") {
                    var q = SearchQuery(); q.from = email; store.search = q; store.runSearch()
                }
                tool("rectangle.split.3x1", "New split for \(person.display)") { store.addSplit(Split(name: person.display, query: "from:\(email)")) }
                tool("doc.on.doc", "Copy address") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(person.email, forType: .string)
                    store.banner = "Copied \(person.email)."
                }
            }
        }.padding(.horizontal, 8)
    }

    func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.scaled(size: 14)).frame(width: 30, height: 28) }
            .buttonStyle(ToolStyle()).help(help).accessibilityLabel(help)
    }

    @ViewBuilder func section<C: View>(_ title: String, count: Int, hidden: Bool, @ViewBuilder _ content: () -> C) -> some View {
        if !hidden { VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if count > 0 { Text("\(count)").font(.scaled(.caption)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 8).padding(.bottom, 4)
            content()
        } }
    }

    func row(_ c: Conversation) -> some View {
        Button { store.open(c) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(c.isUnread ? Theme.accent : .clear).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.latest.subject.isEmpty ? "(no subject)" : c.latest.subject).font(.scaled(.callout).weight(c.isUnread ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(shortDate(c.latest.date)).font(.scaled(.caption)).foregroundStyle(.tertiary)
                    }
                    Text(c.latest.snippet).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(ToolStyle())
    }

    func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": "photo"
        case "xls", "xlsx", "csv", "numbers": "tablecells"
        case "zip": "doc.zipper"
        default: "doc"
        }
    }
}
