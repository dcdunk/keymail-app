import SwiftUI
import EmailCore

/// Stream layout: the inbox as one continuous read. Each conversation's newest email shows in full, one after another,
/// under Today / Yesterday / Earlier. J/K (and clicking) move the current email; ones you've passed fade.
struct StreamInbox: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let items = store.visible
        let cur = items.firstIndex { $0.id == store.selectedID } ?? -1
        if items.isEmpty { EmptyInbox() } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                            if i == 0 || dayLabel(items[i - 1].latest.date) != dayLabel(c.latest.date) { DayDivider(text: dayLabel(c.latest.date)) }
                            StreamItem(c: c, current: i == cur)
                                .opacity(cur >= 0 && i < cur ? 0.55 : 1)
                                .id(c.id)
                                .onTapGesture { store.open(c) }
                        }
                    }
                    .frame(maxWidth: 800).frame(maxWidth: .infinity)
                    .padding(.horizontal, 24).padding(.vertical, 20).padding(.bottom, 60)
                }
                .onChange(of: store.selectedID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
    }
}

/// A stream card: who, subject and the first few lines. Expand for the full email (click, or Space on the current one).
/// Actions sit on every card, same keys as everywhere else.
struct StreamItem: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("emailButtons") private var emailButtons = "text"
    @AppStorage("emailButtonKeys") private var showKeys = true
    let c: Conversation
    let current: Bool
    var body: some View {
        let m = c.latest, open = store.streamExpanded.contains(c.id)
        let from = parseAddresses(m.from).first
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(address: from, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if c.isUnread { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                        Text(participantsLabel(c, me: store.me)).font(.scaled(size: 14, weight: c.isUnread ? .semibold : .medium)).lineLimit(1)
                        if c.messages.count > 1 { Text("\(c.messages.count)").font(.scaled(.caption)).foregroundStyle(.secondary) }
                        Spacer(minLength: 6)
                        Text(shortDate(m.date)).font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                    Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(.scaled(size: 15, weight: .semibold)).lineLimit(2)
                }
            }
            if open {
                MessageCard(message: m, collapsible: false) {}
            } else {
                // The opening lines only: long emails stay one card tall, so the stream scrolls quickly.
                Text(splitQuoted(m.plainText).body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.prefix(8).joined(separator: "\n"))
                    .font(.scaled(size: 13.5)).foregroundStyle(.secondary).lineSpacing(2).lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 2) {
                let acts: [(String, String, String, () -> Void)] = [
                    (open ? "Space" : "Space", open ? "Collapse" : "Show full email", open ? "chevron.up" : "chevron.down", { store.streamExpanded.formSymmetricDifference([c.id]) }),
                    (Hotkeys.label("r"), "Reply", "arrowshape.turn.up.left", { store.act(on: c, reading: true) { store.reply(all: false) } }),
                    (Hotkeys.label("e"), "Done", "checkmark", { store.act(on: c, reading: true) { store.markDone() } }),
                    (Hotkeys.label("h"), "Remind", "clock", { store.act(on: c, reading: true) { store.openPalette("remind") } }),
                    (Hotkeys.label("s"), c.isStarred ? "Unstar" : "Star", c.isStarred ? "star.fill" : "star", { store.act(on: c, reading: true) { store.toggleStar() } }),
                    ("⌫", "Delete", "trash", { store.act(on: c, reading: true) { store.trash() } }),
                ]
                ForEach(acts, id: \.1) { k, l, icon, run in
                    Button(action: run) {
                        HStack(spacing: 5) {
                            Image(systemName: icon).accessibilityLabel(l)
                            if emailButtons == "text" { Text(l) }
                            if current && showKeys { KeyHint(k) }
                        }.font(.scaled(.callout)).padding(.horizontal, 8).frame(height: 28)
                    }.buttonStyle(ToolStyle()).help("\(l) (\(k))")
                }
                Spacer()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(current ? 0.05 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(current ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.06)))
        // Right-click a card for the same menu as the list and split layouts.
        .onHover { h in if h { store.rightClickTarget = c } else if store.rightClickTarget?.id == c.id { store.rightClickTarget = nil } }
        .onDisappear { if store.rightClickTarget?.id == c.id { store.rightClickTarget = nil } }
    }
}

/// Filmstrip layout: one conversation fills the screen; flip with J/K or ← →; the scrubber marks every email
/// (blue unread, taller = longer) so you can jump anywhere.
struct FilmstripInbox: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let items = store.visible
        VStack(spacing: 0) {
            if items.isEmpty { EmptyInbox() }
            else if let c = store.selected ?? items.first {
                HStack(spacing: 0) {
                    flip("chevron.left", "Previous (K or ←)") { store.move(-1) }
                    ThreadView(conversation: c, embedded: true).id(c.id)
                    flip("chevron.right", "Next (J or →)") { store.move(1) }
                }
                // The email on screen is the open one, so Space, ".", Shift-O and y/n/? work from the start.
                .onAppear { if !store.threadOpen { store.open(c) } }
            }
            Scrubber(items: items)
        }
    }

    func flip(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.scaled(size: 16, weight: .semibold)).frame(width: 36, height: 36) }
            .buttonStyle(ToolStyle()).help(help).padding(.horizontal, 6)
    }
}

struct Scrubber: View {
    @EnvironmentObject var store: AppStore
    let items: [Conversation]
    @State private var hover: String?
    var body: some View {
        let cur = items.firstIndex { $0.id == store.selectedID }
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                    let len = min(4, max(1, c.latest.plainText.count / 600 + 1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(c.isUnread ? Theme.accent : Color.primary.opacity(0.25))
                        .frame(maxWidth: 14, minHeight: 6)
                        .frame(height: 12 + CGFloat(len) * 7)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary, lineWidth: i == cur ? 2 : 0))
                        .opacity(hover == c.id || i == cur ? 1 : 0.75)
                        .onHover { hover = $0 ? c.id : nil }
                        .onTapGesture { store.open(c) }
                        .help("\(parseAddresses(c.latest.from).first?.display ?? ""): \(c.latest.subject)")
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack {
                Text("Newest"); Spacer()
                if let cur { Text("\(cur + 1) of \(items.count)").monospacedDigit() }
                Spacer(); Text("Oldest")
            }
            .font(.scaled(.caption2)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 44)
        .overlay(alignment: .top) { Divider() }
    }
}

struct DayDivider: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            Text(text.uppercased()).font(.scaled(.caption2).weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

struct EmptyInbox: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: store.searchResults == nil ? "checkmark.circle" : "magnifyingglass").font(.scaled(size: 34, weight: .light))
            Text(store.searchResults == nil ? "Inbox zero" : "No results").font(.scaled(.title3).weight(.medium))
        }
        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Today", "Yesterday", or the weekday / date for older mail.
func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(.dateTime.month(.wide).year())
}
