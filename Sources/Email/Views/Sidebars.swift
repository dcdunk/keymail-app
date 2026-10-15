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
                            highlighted: store.panelIndex == i) { store.activatePanel(i) }
                    }
                    if !labels.isEmpty {
                        Divider().padding(.vertical, 12).padding(.horizontal, 18)
                        Text("Labels").font(.scaled(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
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
                Text(title).font(.scaled(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.scaled(size: 12)).foregroundStyle(.tertiary) }
                Spacer()
                if count > 0 { Text("\(count)").font(.scaled(size: 12).monospacedDigit()).foregroundStyle(.secondary) }
                else if !key.isEmpty { Text(key).font(.scaled(size: 10, weight: .medium)).foregroundStyle(.quaternary) }
            }
            .padding(.leading, indent ? 30 : 18).padding(.trailing, 18).padding(.vertical, 8)
            .background(alignment: .leading) {
                // Keyboard highlight (↑/↓): a soft fill, separate from the current-folder bar.
                if (highlighted || hovered == title) && !on {
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(highlighted ? 0.08 : 0.05)).padding(.horizontal, 8)
                }
                if on {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.selection)
                        Rectangle().fill(Theme.accent).frame(width: 3)
                    }
                }
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain).handCursor()
        .onHover { inside in
            if inside { hovered = title } else if hovered == title { hovered = nil }
        }
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
                            .overlay(Text(String(person.display.prefix(1)).uppercased()).font(.scaled(.title3).weight(.semibold)).foregroundStyle(Theme.chip(email)))
                        Text(person.display).font(.scaled(.headline)).lineLimit(1)
                        Text(person.email).font(.scaled(.callout)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                    }
                }
                section("Recent with \(person?.firstName.isEmpty == false ? person!.firstName : "them")", history.prefix(5))
                section("Recently opened", recent.prefix(5))
                CalendarSection(conversation: conversation)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                    Text(Date().formatted(date: .complete, time: .omitted)).font(.scaled(.callout))
                    let due = store.state.snoozes.filter { Calendar.current.isDateInToday($0.until) }.count
                    Text("\(due) reminder\(due == 1 ? "" : "s") returning today · \(store.state.scheduled.count) scheduled").font(.scaled(.callout)).foregroundStyle(.secondary)
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
                Text(title).font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items)) { c in
                    Button { store.open(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.latest.subject).font(.scaled(.callout)).lineLimit(1)
                            Text(shortDate(c.latest.date)).font(.scaled(.caption)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
