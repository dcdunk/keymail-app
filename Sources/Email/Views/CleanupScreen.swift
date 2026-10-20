import SwiftUI
import EmailCore

/// Clean up senders and Insights (⌘K). They take the inbox's place, like the calendar does.
struct ToolScreenView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    let screen: ToolScreen

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                circle("chevron.left", "Back to inbox (Esc)") { store.closeTool() }
                HStack(spacing: 8) {
                    Text(screen == .cleanup ? "Clean up" : "Insights").font(.scaled(size: 15, weight: .semibold))
                    Text(screen == .cleanup ? "\(store.cleanupSenders.count) senders" : "last \(store.insightsDays) days")
                        .font(.scaled(size: 13)).foregroundStyle(.secondary)
                }
                .lineLimit(1).fixedSize().padding(.horizontal, 16).padding(.vertical, 8).glass(Capsule())
                Spacer(minLength: 8)
                if screen == .cleanup {
                    segmented(CleanupFilter.allCases.map { f in (f.rawValue, f == store.cleanupFilter, { store.cleanupFilter = f; store.cleanupIndex = 0 }) })
                } else {
                    segmented([7, 30, 90].map { d in ("\(d) days", d == store.insightsDays, { store.insightsDays = d }) })
                }
                circle(screen == .cleanup ? "chart.bar" : "person.2.slash", screen == .cleanup ? "Insights" : "Clean up senders") {
                    store.openTool(screen == .cleanup ? .insights : .cleanup)
                }
                AccountCapsule()
            }
            .glassGroup(spacing: 10)
            .padding(.horizontal, layout.margin).padding(.top, 34).padding(.bottom, 12)
            if let b = store.banner { BannerView(text: b) { store.banner = nil } }
            if screen == .cleanup { CleanupList() } else { InsightsView() }
        }
    }

    func segmented(_ items: [(String, Bool, () -> Void)]) -> some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let (title, on, run) = items[i]
                Button(action: run) {
                    Text(title).font(.scaled(size: 13, weight: on ? .semibold : .regular)).fixedSize()
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .modifier(SelectedGlass(on: on)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(2).glass(Capsule())
    }

    func circle(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.scaled(size: 14)).frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).glass(Circle(), interactive: true)
        .help(help).accessibilityLabel(String(help.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: Clean up senders

struct CleanupList: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout

    var body: some View {
        let list = store.cleanupSenders
        let top = max(list.first?.count ?? 1, 1)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Sender").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 70)
                Text("Emails").frame(width: 90, alignment: .leading)
                Text("You read").frame(width: 110, alignment: .leading)
                Text("").frame(width: 260)
            }
            .font(.scaled(size: 11, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
            .padding(.horizontal, layout.margin + 14).padding(.bottom, 4)
            if list.isEmpty {
                Text(store.cleanupFilter == .kept ? "Senders you keep show here." : "Nothing to clean up here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                                SenderRow(s: s, top: top, current: i == store.cleanupIndex).id(s.id)
                                    .onTapGesture { store.cleanupIndex = i }
                            }
                        }
                        .padding(.horizontal, layout.margin)
                    }
                    .onChange(of: store.cleanupIndex) { _, i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
                }
            }
            HStack(spacing: 12) {
                Text("\(store.cleanupSelected.count) selected").foregroundStyle(.secondary)
                HStack(spacing: 4) { KeyHint("X"); Text("select") }
                HStack(spacing: 4) { KeyHint("U"); Text("unsubscribe") }
                HStack(spacing: 4) { KeyHint("E"); Text("archive all") }
                HStack(spacing: 4) { KeyHint("S"); Text("keep") }
                Spacer()
                Button("Unsubscribe & archive selected") { store.cleanupUnsubscribe(list.map(\.email).filter(store.cleanupSelected.contains)) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(store.cleanupSelected.isEmpty)
            }
            .font(.scaled(.caption)).foregroundStyle(.secondary)
            .padding(.horizontal, layout.margin + 14).padding(.vertical, 12)
        }
    }
}

struct SenderRow: View {
    @EnvironmentObject var store: AppStore
    let s: SenderStat, top: Int, current: Bool
    @State private var hovering = false

    var body: some View {
        let chosen = store.cleanupSelected.contains(s.email), done = store.cleanupDone[s.email]
        let kept = store.state.cleanupKept.contains(s.email)
        HStack(spacing: 12) {
            Button { store.cleanupSelected.formSymmetricDifference([s.email]) } label: {
                Image(systemName: chosen ? "checkmark.square.fill" : "square").font(.scaled(size: 15))
                    .foregroundStyle(chosen ? Theme.accent : Color.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Select (X)")
            Avatar(address: Address(name: s.name, email: s.email), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.scaled(size: 14, weight: .semibold)).lineLimit(1)
                Text(s.email).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(s.count)").font(.scaled(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(alignment: .leading) { Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(s.count) / CGFloat(top)) }
                }.frame(height: 5)
            }
            .frame(width: 90)
            Group {
                if s.neverRead { Text("Never").fontWeight(.semibold).foregroundStyle(.orange) }
                else { Text("\(s.read * 100 / max(s.count, 1))% · \(s.read) of \(s.count)").foregroundStyle(.secondary) }
            }
            .font(.scaled(size: 12.5).monospacedDigit()).frame(width: 110, alignment: .leading)
            HStack(spacing: 6) {
                if let done {
                    Label(done, systemImage: "checkmark").foregroundStyle(.green).lineLimit(1)
                } else if kept {
                    action("Stop keeping") { store.cleanupKeep(s.email) }
                } else {
                    action("Unsubscribe", "Unsubscribe and archive all (U)") { store.cleanupUnsubscribe([s.email]) }.disabled(!s.canUnsubscribe)
                    action("Archive all", "Archive all (E)") { let n = store.cleanupArchive([s.email]); store.banner = "Archived \(n) emails. ⌘Z to undo." }
                    action("Keep", "Keep: hide from this list (S)") { store.cleanupKeep(s.email) }
                }
            }
            .font(.scaled(size: 12.5)).frame(width: 260, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .opacity(done == nil ? 1 : 0.5)
        .background(RoundedRectangle(cornerRadius: 10).fill(current || chosen ? Theme.selection : hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    func action(_ title: String, _ help: String? = nil, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(title).padding(.horizontal, 8).frame(height: 26) }.buttonStyle(ToolStyle()).help(help ?? title)
    }
}

// MARK: Insights

struct InsightsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout

    var body: some View {
        let mine = store.messages.values.filter { store.state.activeAccount == nil || $0.account == store.state.activeAccount }
        let r = inboxInsights(Array(mine), me: store.me, days: store.insightsDays)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: layout.compact ? 2 : 4), spacing: 10) {
                    kpi("Emails received", r.received.formatted(), r.previousReceived.map { change(r.received, $0) } ?? "in \(store.insightsDays) days")
                    kpi("From people", r.fromPeople.formatted(), r.received == 0 ? "" : "\(r.fromPeople * 100 / r.received)% of all mail")
                    kpi("Never opened", r.neverOpened.formatted(), r.received == 0 ? "" : "\(r.neverOpened * 100 / r.received)% of all mail", warn: true)
                    kpi("Your reply time", r.averageReply.map(durationLabel) ?? "–", "on average")
                }
                if r.neverReadSenders > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.slash").foregroundStyle(.orange)
                        Text("**\(r.neverReadSenders) senders** sent you \(r.neverReadEmails) emails you never opened.")
                        Spacer()
                        Button("Clean them up") { store.openTool(.cleanup); store.cleanupFilter = .never }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    }
                    .font(.scaled(.callout)).padding(.horizontal, 14).padding(.vertical, 10)
                    .glass(RoundedRectangle(cornerRadius: 12), tint: Color.orange.opacity(0.15))
                }
                HStack(alignment: .top, spacing: 14) {
                    card("Emails per day", note: "people vs everything else") { DayChart(days: r.days) }
                    card("Who emails you most") {
                        let top = max(r.topSenders.first?.count ?? 1, 1)
                        ForEach(r.topSenders) { s in
                            bar(s.name, s.count, of: top, color: s.neverRead ? .orange : Theme.accent, note: s.neverRead ? "never read" : nil)
                                .onTapGesture { store.openTool(.cleanup); store.cleanupIndex = store.cleanupSenders.firstIndex { $0.email == s.email } ?? 0 }
                                .help("Show in Clean up")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    card("What's in your inbox") {
                        let top = max(r.categories.first?.1 ?? 1, 1)
                        ForEach(r.categories, id: \.0) { cat, n in bar(cat.rawValue, n, of: top, color: Theme.accent.opacity(0.75)) }
                    }
                    card("People you reply to most") {
                        if r.repliedTo.isEmpty { Text("No replies in this period.").foregroundStyle(.secondary) }
                        ForEach(r.repliedTo, id: \.email) { p in
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text("\(p.replies) repl\(p.replies == 1 ? "y" : "ies") · avg \(durationLabel(p.averageReply))").foregroundStyle(.secondary)
                            }.font(.scaled(size: 13))
                        }
                    }
                }
                Text("Worked out from the mail already on this Mac. \"Never opened\" counts emails still marked unread.")
                    .font(.scaled(.caption)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, layout.margin + 8).padding(.bottom, 40)
        }
    }

    func change(_ now: Int, _ before: Int) -> String {
        guard before > 0 else { return "" }
        let pct = (now - before) * 100 / before
        return pct == 0 ? "same as the period before" : "\(pct > 0 ? "↑" : "↓") \(abs(pct))% vs the period before"
    }

    func kpi(_ title: String, _ value: String, _ note: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.scaled(.caption)).foregroundStyle(.secondary)
            Text(value).font(.scaled(size: 24, weight: .semibold).monospacedDigit())
            Text(note).font(.scaled(size: 11)).foregroundStyle(warn ? Color.orange : Color.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
        .glass(RoundedRectangle(cornerRadius: 12))
    }

    func card<C: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let note { Text(note).font(.scaled(.caption)).foregroundStyle(.tertiary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
        .glass(RoundedRectangle(cornerRadius: 12))
    }

    func bar(_ label: String, _ n: Int, of top: Int, color: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Text("\(n)\(note.map { " · \($0)" } ?? "")").foregroundStyle(note == nil ? Color.secondary : Color.orange).monospacedDigit()
            }.font(.scaled(size: 13))
            GeometryReader { g in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: g.size.width * CGFloat(n) / CGFloat(top)) }
            }.frame(height: 5)
        }
        .contentShape(Rectangle())
    }
}

/// Stacked bars per day: people (accent) under everything else (gray).
struct DayChart: View {
    let days: [InboxInsights.Day]
    var body: some View {
        let top = CGFloat(max(days.map { $0.people + $0.other }.max() ?? 1, 1))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: days.count > 40 ? 1 : 3) {
                ForEach(days, id: \.date) { d in
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.22)).frame(height: 120 * CGFloat(d.other) / top)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(height: 120 * CGFloat(d.people) / top)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(d.date.formatted(date: .abbreviated, time: .omitted)): \(d.people) from people, \(d.other) other")
                }
            }
            .frame(height: 122)
            HStack {
                Text(days.first?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
                Spacer()
                Text(days.last?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "")
            }.font(.scaled(size: 10)).foregroundStyle(.tertiary)
            HStack(spacing: 14) {
                Label { Text("From people") } icon: { RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 9, height: 9) }
                Label { Text("Newsletters, receipts, notifications") } icon: { RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.22)).frame(width: 9, height: 9) }
            }.font(.scaled(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Ready draft (under the email it answers)

struct ReadyDraftCard: View {
    @EnvironmentObject var store: AppStore
    let conversation: Conversation

    var body: some View {
        if let d = store.readyDraft(conversation) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Draft reply, ready", systemImage: "pencil.line").font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text("written by \(store.ai.name) \(d.written.formatted(.relative(presentation: .named)))").font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                Text(d.text).font(.scaled(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Why:").foregroundStyle(.tertiary)
                    ForEach(d.why, id: \.self) { w in
                        Text(w).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                    }
                }.font(.scaled(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button { store.sendReadyDraft() } label: { HStack(spacing: 6) { Text("Send"); KeyHint("⌘↵") } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    Button { store.editReadyDraft() } label: { HStack(spacing: 6) { Text("Edit"); KeyHint(Hotkeys.label("r")) } }.buttonBorderShape(.capsule)
                    Button("Write again") { store.rewriteReadyDraft() }.buttonBorderShape(.capsule)
                    Button("Throw away") { store.discardReadyDraft() }.buttonBorderShape(.capsule)
                }
                .font(.scaled(.callout))
            }
            // Same width, padding and corners as an email card, with an accent edge so it reads as yours.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.3)))
        } else if store.draftsWriting.contains(conversation.id) {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(store.ai.name) is writing a draft reply…") }
                .font(.scaled(.callout)).foregroundStyle(.secondary)
        }
    }
}
