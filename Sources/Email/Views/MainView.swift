import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

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
