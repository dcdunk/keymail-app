import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

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
                Button("Reset") { store.search = SearchQuery(); range = "any" }.quiet()
                Button { store.runSearch() } label: { HStack(spacing: 8) { Text("Search").fontWeight(.semibold); KeyHint("↩") } }.keyboardShortcut(.defaultAction).prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
        .font(.scaled(.callout))
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
                                .font(.scaled(.caption)).padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }.buttonStyle(.plain).handCursor().help(a.email)
                    }
                }
            }
        }
    }

    func chip(_ title: String, _ icon: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon).font(.scaled(.callout)).padding(.horizontal, 12).padding(.vertical, 5)
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
                        Image(systemName: t.icon).font(.scaled(size: 10)).foregroundStyle(.secondary)
                        Text(t.label).lineLimit(1)
                        ChipRemoveButton { remove(t.kind) }
                    }
                    .font(.scaled(.callout)).padding(.leading, 9).padding(.trailing, 3).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.selection))
                }
                TextField(tokens.isEmpty ? "Search people, subjects, dates or words" : "Add more…", text: $store.searchText)
                    .textFieldStyle(.plain).focused($focused)
                    .onAppear { focused = true }
                    .onChange(of: store.searchText) { _, _ in highlight = nil }
                    // Keep typing focus here when chips change, so Backspace keeps working on chips.
                    .onChange(of: store.search) { _, _ in if store.searchOpen { focused = true } }
                    // ↑↓ walk the suggestions, then on into the "Emails" matches below them.
                    .onKeyPress(.downArrow) { highlight = min((highlight ?? -1) + 1, list.count + quickMatches.count - 1); return .handled }
                    .onKeyPress(.upArrow) { highlight = (highlight ?? 0) > 0 ? highlight! - 1 : nil; return .handled }
                    .onKeyPress(.tab) {
                        guard let s = list.first(where: { if case .words = $0 { return false }; return true }) ?? list.first else { return .ignored }
                        lock(s); return .handled
                    }
                    .onKeyPress(.return) {
                        let matches = quickMatches
                        if let h = highlight, list.indices.contains(h) { lock(list[h]) }
                        else if let h = highlight, matches.indices.contains(h - list.count) { jump(matches[h - list.count]) }
                        else { store.runSearch() }
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        guard store.searchText.isEmpty, !tokens.isEmpty else { return .ignored }
                        store.removeLastSearchToken(); return .handled
                    }
                Button { store.searchFiltersOpen.toggle() } label: {
                    Image(systemName: "line.3.horizontal.decrease").padding(5)
                        .background(Circle().fill(store.searchFiltersOpen ? Theme.selection : .clear))
                }.buttonStyle(.plain).handCursor().help("More filters (⌘F)").keyboardShortcut("f", modifiers: .command)
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
                Text("Emails").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                ForEach(Array(matches.enumerated()), id: \.element.id) { i, c in
                    Button { jump(c) } label: {
                        HStack(spacing: 10) {
                            Avatar(address: parseAddresses(c.latest.from).first, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.latest.subject).lineLimit(1)
                                Text(parseAddresses(c.latest.from).first?.display ?? "").font(.scaled(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(shortDate(c.latest.date)).font(.scaled(.caption)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 10).fill(highlight == list.count + i ? Theme.selection : .clear))
                    }.buttonStyle(.plain).handCursor()
                }
            }
            Text("Tab to pick the top match · ↑↓ to choose · Return to search").font(.scaled(.caption2)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.top, 6)
        }
        .font(.scaled(size: 14))
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
                Image(systemName: "circle.fill").font(.scaled(size: 8)).frame(width: 22); Text("Unread"); Spacer(); tag("Filter")
            case .words(let w):
                Image(systemName: "magnifyingglass").frame(width: 22); Text("Search for “\(w)”"); Spacer(); tag("Words")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.selection : .clear))
        .contentShape(Rectangle())
    }

    func tag(_ t: String) -> some View { Text(t).font(.scaled(.caption)).foregroundStyle(.secondary) }

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
