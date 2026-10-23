import SwiftUI
import EmailCore

/// Split layout (Settings → Appearance → Inbox layout): a narrow message list beside the open conversation,
/// like Apple Mail. Same store, keys and actions as the full-width list; only the arrangement differs.
struct SplitInbox: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    var body: some View {
        let listWidth = min(420, max(300, layout.width * 0.3))
        HStack(spacing: 0) {
            SplitList().frame(width: listWidth)
            Divider().opacity(0.5)
            if let c = store.selected {
                ThreadView(conversation: c, embedded: true).id(c.id)
                    .onAppear { if !store.threadOpen, store.selectedID == nil || store.selectedID == c.id { store.open(c) } }   // the shown email is the open one
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open").font(.scaled(size: 34, weight: .light))
                    Text("No email selected").font(.scaled(.title3).weight(.medium))
                    Text("Pick one on the left, or press J.").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SplitList: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let items = store.visible, sel = store.selected?.id
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.searchResults == nil ? "checkmark.circle" : "magnifyingglass").font(.scaled(size: 28, weight: .light))
                Text(store.searchResults == nil ? "Inbox zero" : "No results").font(.scaled(.headline))
            }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { c in
                            SplitRow(c: c, selected: c.id == sel).id(c.id)
                                .onTapGesture { store.open(c) }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).padding(.bottom, 48)
                }
                .onChange(of: store.selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            }
        }
    }
}

/// Sender and date, subject, two lines of preview, and quiet markers for unread, thread size and attachments.
struct SplitRow: View {
    @EnvironmentObject var store: AppStore
    let c: Conversation
    let selected: Bool
    @State private var hover = false
    var body: some View {
        let unread = c.isUnread
        let mine = parseAddresses(c.latest.from).first.map { store.me.contains($0.email.lowercased()) } ?? false
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(unread ? Theme.accent : c.isStarred ? Color.yellow : .clear).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if mine { Image(systemName: "arrowshape.turn.up.left.fill").font(.scaled(size: 10)).foregroundStyle(.secondary).help("You replied last") }
                    Text(participantsLabel(c, me: store.me)).font(.scaled(size: 14, weight: unread ? .semibold : .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if store.state.accounts.count > 1 {
                        Text(store.label(c.account)).font(.scaled(.caption2)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Text(shortDate(c.latest.date)).font(.scaled(.caption)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(c.latest.subject.isEmpty ? "(no subject)" : c.latest.subject)
                        .font(.scaled(size: 13, weight: unread ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if c.messages.contains(where: { $0.attachments.contains { !$0.isInline } }) {
                        Image(systemName: "paperclip").font(.scaled(size: 11)).foregroundStyle(.secondary)
                    }
                    if c.messages.count > 1 {
                        Text("\(c.messages.count)").font(.scaled(.caption2).weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(c.latest.snippet).font(.scaled(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.selection : hover ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { h in
            hover = h   // and the right-click menu acts on this row (it was only wired for the full-width list)
            if h { store.rightClickTarget = c } else if store.rightClickTarget?.id == c.id { store.rightClickTarget = nil }
        }
        // A row that scrolls away or is archived while hovered can't leave a stale right-click target behind.
        .onDisappear { if store.rightClickTarget?.id == c.id { store.rightClickTarget = nil } }
        // Drag onto a sidebar folder or label, or the Calendar button.
        .draggable(c.id) { Label(c.latest.subject, systemImage: "envelope").padding(8).glass(Capsule()) }
    }
}
