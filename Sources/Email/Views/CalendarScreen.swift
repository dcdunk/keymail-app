import AppKit
import SwiftUI
import MapKit
import EmailCore

// MARK: Calendar screen (g c)

extension CalView {
    var title: String { rawValue.capitalized }
    var key: String { String(rawValue.prefix(1)).uppercased() }
}

extension AppStore {
    func calColor(_ e: CalEvent) -> Color { calSource(e.calendarId).flatMap { Color(hex: $0.colorHex) } ?? Theme.accent }
}

struct CalendarScreen: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            CalendarHeader()
            if let b = store.banner { BannerView(text: b) { store.banner = nil } }
            if let id = store.placingEmail, let c = store.allConversations.first(where: { $0.id == id }) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope").foregroundStyle(Theme.accent)
                    Text("Click a time to block 30 minutes for \"\(c.latest.subject)\"").font(.scaled(.callout)).lineLimit(1)
                    Spacer()
                    KeyHint("Esc"); Text("cancels").font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glass(RoundedRectangle(cornerRadius: 14), tint: Theme.accent.opacity(0.2))
                .padding(.horizontal, 32).padding(.bottom, 6)
            }
            if store.calView == .month { MonthGrid() } else { TimeGrid(days: store.calDays) }
        }
        .overlay(alignment: .top) { if store.quickAddOpen { QuickAddBar().padding(.top, 90) } }
        // Keeps the week current while it's open (new invites, edits made elsewhere).
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); await store.loadCalendar() } }
    }
}

struct CalendarHeader: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    var body: some View {
        // Narrow (both side panels open): drop the week number and arrows first (H / L still work), then Today (T),
        // then the view switcher (D / W / M), so nothing wraps or squeezes.
        ViewThatFits(in: .horizontal) {
            bar(level: 0)
            bar(level: 1)
            bar(level: 2)
            bar(level: 3)
        }
        .glassGroup(spacing: 10)
        .padding(.horizontal, layout.margin).padding(.top, 34).padding(.bottom, 12)
    }

    func bar(level: Int) -> some View {
        let d = store.calDate
        return HStack(spacing: 6) {
            if !store.foldersPinned {
                circle("line.3.horizontal", "Calendars (←)") { store.sidebarOpen.toggle() }.padding(.trailing, 8)
            }
            HStack(spacing: 8) {
                Text(store.calView == .day ? d.formatted(.dateTime.weekday(level == 0 ? .wide : .abbreviated).month(level == 0 ? .wide : .abbreviated).day())
                     : d.formatted(.dateTime.month(level == 0 ? .wide : .abbreviated).year()))
                    .font(.scaled(size: 15, weight: .semibold))
                if store.calView == .week, level == 0 {
                    Text("Week \(Calendar.current.component(.weekOfYear, from: d))").font(.scaled(size: 13)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1).fixedSize().padding(.horizontal, 16).padding(.vertical, 8).glass(Capsule())
            if level == 0 {
                circle("chevron.left", "Previous (H)") { store.calStep(-1) }
                circle("chevron.right", "Next (L)") { store.calStep(1) }
            }
            if level < 2 { Button { store.calToday() } label: {
                Text("Today").font(.scaled(size: 13, weight: .medium)).fixedSize().padding(.horizontal, 14).padding(.vertical, 8).contentShape(Capsule())
            }
            .buttonStyle(.plain).glass(Capsule(), interactive: true).help("Today (T)") }
            Spacer(minLength: 8)
            if level < 3 {
                HStack(spacing: 2) {
                    ForEach(CalView.allCases, id: \.self) { v in
                        Button { store.calView = v } label: {
                            Text(v.title).font(.scaled(size: 13, weight: v == store.calView ? .semibold : .regular)).fixedSize()
                                .foregroundStyle(v == store.calView ? Color.primary : Color.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .modifier(SelectedGlass(on: v == store.calView)).contentShape(Capsule())
                        }.buttonStyle(.plain).help("\(v.title) view (\(v.key))")
                    }
                }
                .padding(2).glass(Capsule())
            }
            circle("calendar.badge.plus", "New event (C)", primary: true) { store.quickAddOpen = true }
            if !store.contextPinned { circle("sidebar.right", "Context panel (→)") { store.contextOpen.toggle() } }
            ViewSwitchButton(toCalendar: false)
            AccountCapsule()
        }
    }

    func circle(_ symbol: String, _ help: String, primary: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.scaled(size: 14, weight: primary ? .medium : .regular)).frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(primary ? Color.primary : Color.secondary).glass(Circle(), interactive: true)
        .help(help).accessibilityLabel(String(help.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: Day and week

struct TimeGrid: View {
    @EnvironmentObject var store: AppStore
    let days: [Date]
    var hourHeight: CGFloat { 46 * Font.scale }
    let gutter: CGFloat = 54

    var body: some View {
        let events = store.calShown
        let allDay = events.filter(\.allDay)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { d in
                    let today = Calendar.current.isDateInToday(d)
                    HStack(spacing: 6) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(.secondary)
                        Text(d.formatted(.dateTime.day())).fontWeight(.semibold)
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .padding(.horizontal, today ? 7 : 0).padding(.vertical, 1)
                            .background { if today { Capsule().fill(Theme.accent) } }
                    }
                    .font(.scaled(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { store.calShowDay(d) }
                }
            }
            .padding(.bottom, 8)
            if !allDay.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Text("All day").font(.scaled(size: 10)).foregroundStyle(.tertiary).frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8)
                    ForEach(days, id: \.self) { d in
                        VStack(spacing: 2) {
                            ForEach(allDay.filter { $0.start < Calendar.current.date(byAdding: .day, value: 1, to: d)! && $0.end > d }) { e in
                                EventBlock(event: e, height: 20).frame(height: 20)
                            }
                        }.frame(maxWidth: .infinity).padding(.horizontal, 2)
                    }
                }.padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { h in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(h == 0 ? "" : hourLabel(h)).font(.scaled(size: 10.5)).foregroundStyle(.tertiary)
                                        .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8).offset(y: -7)
                                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                                }
                                .frame(height: hourHeight, alignment: .top).id(h)
                            }
                        }
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutter)
                            ForEach(days, id: \.self) { d in
                                DayColumn(day: d, events: events.filter { !$0.allDay }, hourHeight: hourHeight)
                                    .background(isWeekend(d) && days.count > 1 ? Color.primary.opacity(0.025) : .clear)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
                            }
                        }
                        NowLine(days: days, hourHeight: hourHeight, gutter: gutter)
                    }
                    .padding(.top, 8).padding(.trailing, 12)
                }
                .onAppear { proxy.scrollTo(max(0, min(Calendar.current.component(.hour, from: Date()) - 2, 7)), anchor: .top) }
                .onChange(of: store.calSelected) { _, id in
                    if let e = store.calShown.first(where: { $0.id == id }), !e.allDay {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(max(0, Calendar.current.component(.hour, from: e.start) - 1), anchor: .top) }
                    }
                }
            }
        }
        .padding(.leading, 8)
    }

    func hourLabel(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour())
    }
    func isWeekend(_ d: Date) -> Bool { Calendar.current.isDateInWeekend(d) }
}

struct DayColumn: View {
    @EnvironmentObject var store: AppStore
    let day: Date
    let events: [CalEvent]
    let hourHeight: CGFloat
    var body: some View {
        let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let mine = events.filter { $0.start < end && $0.end > start }
        let cols = overlapColumns(mine)
        GeometryReader { geo in
            if store.placingEmail != nil {
                // Above the events while placing: a click anywhere picks that time (snapped to 15 minutes).
                Color.primary.opacity(0.001).contentShape(Rectangle())
                    .onTapGesture { p in
                        let minutes = (Double(p.y / hourHeight) * 60 / 15).rounded(.down) * 15
                        store.placeEmail(at: start.addingTimeInterval(minutes * 60))
                    }
                    .zIndex(1).handCursor()
            }
            ForEach(mine) { e in
                let s = max(e.start, start), f = min(e.end, end)
                let top = CGFloat(s.timeIntervalSince(start) / 3600) * hourHeight
                let h = max(18, CGFloat(f.timeIntervalSince(s) / 3600) * hourHeight - 2)
                let c = cols[e.id] ?? (0, 1), w = (geo.size.width - 4) / CGFloat(max(c.of, 1))
                EventBlock(event: e, height: h)
                    .frame(width: max(w - 2, 10), height: h)
                    .offset(x: 2 + CGFloat(c.col) * w, y: top + 1)
            }
        }
        .frame(height: hourHeight * 24).frame(maxWidth: .infinity)
    }
}

struct NowLine: View {
    let days: [Date], hourHeight: CGFloat, gutter: CGFloat
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { t in
            if days.contains(where: { Calendar.current.isDate($0, inSameDayAs: t.date) }) {
                let y = CGFloat(t.date.timeIntervalSince(Calendar.current.startOfDay(for: t.date)) / 3600) * hourHeight
                HStack(spacing: 0) {
                    Text(t.date.formatted(.dateTime.hour().minute())).font(.scaled(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Color.red))
                        .frame(width: gutter, alignment: .trailing)
                    Rectangle().fill(Color.red).frame(height: 1.5)
                }
                .offset(y: y - 7).allowsHitTesting(false)
            }
        }
    }
}

// MARK: Event block (with the inbox rows' hover: a tint plus quick actions)

struct EventBlock: View {
    @EnvironmentObject var store: AppStore
    let event: CalEvent
    var height: CGFloat = 40
    @State private var hover = false
    var body: some View {
        let color = store.calColor(event), on = store.calSelected == event.id
        let roomy = height >= 40, linked = store.linkedConversation(event) != nil
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(color.opacity(on ? 0.45 : hover ? 0.34 : event.unanswered ? 0.12 : 0.22))
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                // Narrow (overlapping events side by side): the title wins over the little icons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        if event.conference != nil { Image(systemName: "video.fill").font(.scaled(size: 8.5)).foregroundStyle(.secondary) }
                        if linked { Image(systemName: "envelope.fill").font(.scaled(size: 8.5)).foregroundStyle(.secondary) }
                        Text(event.title).font(.scaled(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    Text(event.title).font(.scaled(size: 11.5, weight: .semibold)).lineLimit(roomy && height > 56 ? 2 : 1)
                }
                if roomy && !event.allDay {
                    Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                        .font(.scaled(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, height < 24 ? 2 : 4)
            if hover && height >= 44 {
                HStack(spacing: 1) {
                    if event.conference != nil { quick("video", "Join (Shift J)") { store.joinCall(event) } }
                    if linked { quick("envelope", "Open email (O)") { store.openLinkedEmail(event) } }
                    if event.editable { quick("pencil", "Edit (E)") { store.selectEvent(event.id); store.calEditing = event.id } }
                    if event.editable { quick("trash", "Delete (⌫)") { store.deleteEvent(event) } }
                }
                .padding(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            if event.unanswered { RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
            else if hover || on { RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.5), lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
        .onTapGesture { store.selectEvent(on ? nil : event.id) }
        .eventCard(event)
        .help(event.title)
    }

    func quick(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.scaled(size: 10)).frame(width: 20, height: 18) }
            .buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial)).help(help).accessibilityLabel(help)
    }
}

extension View {
    /// The event card, shown beside whichever event is selected (click, or J / K).
    func eventCard(_ e: CalEvent) -> some View { modifier(EventCardPopover(event: e)) }
}

private struct EventCardPopover: ViewModifier {
    @EnvironmentObject var store: AppStore
    let event: CalEvent
    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { store.calSelected == event.id && !store.quickAddOpen },
                                             set: { if !$0, store.calSelected == event.id { store.calSelected = nil } }),
                        arrowEdge: .trailing) { EventCard(event: event).environmentObject(store) }
    }
}

struct EventCard: View {
    @EnvironmentObject var store: AppStore
    let event: CalEvent
    var body: some View {
        let e = event, call = e.conference
        let source = store.calSource(e.calendarId)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(store.calColor(e)).frame(width: 10, height: 10)
                let targets = store.moveTargets(e)
                if targets.isEmpty {
                    Text(source?.title ?? "Calendar").font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    // Move to another calendar.
                    Menu {
                        ForEach(Array(Dictionary(grouping: targets, by: \.group).sorted { $0.key < $1.key }), id: \.key) { group, cals in
                            Section(group) { ForEach(cals) { c in Button(c.title) { store.moveEvent(e, to: c) } } }
                        }
                    } label: {
                        Text(source?.title ?? "Calendar").lineLimit(1).font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Move to another calendar")
                }
                Spacer(minLength: 8)
                if e.editable { tool("pencil", "Edit (E)") { store.calEditing = store.calEditing == e.id ? nil : e.id } }
                if e.editable { tool("trash", "Delete (⌫)") { store.deleteEvent(e) } }
                tool("xmark", "Close (Esc)") { store.calSelected = nil }
            }
            if store.calEditing == e.id {
                EventEditor(event: e)
            } else {
            Text(e.title).font(.scaled(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            row("clock", when(e))
            let place = e.location.trimmingCharacters(in: .whitespaces)
            if place != call?.url.absoluteString, !place.isEmpty || e.editable { PlaceSection(event: e) }
            if let call {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon("video")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.kind.rawValue).font(.scaled(.callout))
                        Text((call.url.host ?? "") + call.url.path).font(.scaled(.caption)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
            }
            let notes = cleanNotes(e.notes, call: call)
            if !notes.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon("text.alignleft")
                    Text(notes).font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                }
            }
            }
            if let c = store.linkedConversation(e) {
                Button { store.openLinkedEmail(e) } label: {
                    HStack(spacing: 10) {
                        icon("envelope")
                        Text(c.latest.subject.isEmpty ? "(no subject)" : c.latest.subject).font(.scaled(.callout)).lineLimit(1)
                        Spacer(minLength: 4)
                        KeyHint("O", size: 10)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor().padding(.horizontal, -8).help("Open the email")
            }
            if let call {
                Button { store.joinCall(e) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "video.fill")
                        Text("Join \(call.kind.rawValue)")
                        KeyHint("⇧J", size: 10)
                    }.frame(maxWidth: .infinity)
                }
                .primaryAction().padding(.top, 2)
            }
            if e.unanswered {
                Divider()
                HStack(spacing: 6) {
                    Text("Going?").font(.scaled(.callout)).foregroundStyle(.secondary)
                    ForEach([(RSVP.accepted, "Y"), (.tentative, "?"), (.declined, "N")], id: \.1) { r, key in
                        Button { store.answerEvent(e, r) } label: { HStack(spacing: 5) { Text(r.label); KeyHint(key, size: 9.5) } }.quiet()
                    }
                }
            }
        }
        .padding(16).frame(width: 300)
    }

    func when(_ e: CalEvent) -> String {
        if e.allDay { return e.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · All day" }
        return e.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · "
            + e.start.formatted(date: .omitted, time: .shortened) + " – " + e.end.formatted(date: .omitted, time: .shortened)
    }
    /// Notes without the meeting link (it has its own row and button) and without Google's boilerplate around it.
    func cleanNotes(_ n: String, call: Conference?) -> String {
        var t = n.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        if let u = call?.url.absoluteString { t = t.replacingOccurrences(of: u, with: "") }
        return t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func icon(_ s: String) -> some View { Image(systemName: s).font(.scaled(size: 13)).foregroundStyle(.secondary).frame(width: 16) }
    func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { icon(symbol); Text(text).font(.scaled(.callout)).textSelection(.enabled) }
    }
    func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.scaled(size: 13)).frame(width: 26, height: 26) }
            .buttonStyle(ToolStyle()).help(help).accessibilityLabel(help)
    }
}

// MARK: Month

struct MonthGrid: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        // Its own six weeks, never store.calDays: while switching to week or day view this grid can draw one last
        // time with the new, shorter list, and indexing six rows into it crashed.
        let days = calendarDays(.month, around: store.calDate, mondayFirst: store.calMondayFirst), events = store.calShown
        let month = Calendar.current.component(.month, from: store.calDate)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.scaled(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                }
            }.padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(days[(r * 7)..<(r * 7 + 7)], id: \.self) { d in
                            MonthCell(day: d, inMonth: Calendar.current.component(.month, from: d) == month,
                                      events: events.filter { Calendar.current.isDate($0.start, inSameDayAs: d) }.sorted { $0.start < $1.start })
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }
}

struct MonthCell: View {
    @EnvironmentObject var store: AppStore
    let day: Date, inMonth: Bool, events: [CalEvent]
    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day())).font(.scaled(size: 12, weight: today ? .bold : .regular))
                .foregroundStyle(today ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                .padding(.horizontal, today ? 6 : 2).padding(.vertical, 1)
                .background { if today { Capsule().fill(Theme.accent) } }
            ForEach(events.prefix(3)) { e in MonthChip(event: e) }
            if events.count > 3 {
                Text("+\(events.count - 3) more").font(.scaled(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
        .padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.calShowDay(day) }
    }
}

struct MonthChip: View {
    @EnvironmentObject var store: AppStore
    let event: CalEvent
    @State private var hover = false
    /// Narrow cells drop the time before the title gets cut to nothing.
    func chip(time: Bool, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            if time, !event.allDay { Text(event.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary).fixedSize() }
            Text(event.title).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        let color = store.calColor(event), on = store.calSelected == event.id
        chip(time: false, color: color)   // times don't fit every cell, and some-with some-without looks broken
        .font(.scaled(size: 11)).padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(on ? 0.35 : hover ? 0.2 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }.animation(.easeOut(duration: 0.14), value: hover)
        .onTapGesture { store.selectEvent(on ? nil : event.id) }
        .eventCard(event)
    }
}

// MARK: Quick add (C)

struct QuickAddBar: View {
    @EnvironmentObject var store: AppStore
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        let q = parseQuickEvent(text)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Lunch with Sam friday 1pm at Tartine", text: $text)
                .textFieldStyle(.plain).font(.scaled(size: 17)).padding(16).focused($focused)
                .onSubmit { store.quickAdd(text) }
                .onKeyPress(.tab) { store.quickAddMore(text); return .handled }
                .onExitCommand { store.quickAddOpen = false }
            Divider()
            Group {
                if let q {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        line("Event", q.title)
                        line("When", q.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()) + " – "
                             + q.start.addingTimeInterval(Double(q.minutes) * 60).formatted(date: .omitted, time: .shortened))
                        if !q.location.isEmpty { line("Where", q.location) }
                        line("Calendar", destinationName)
                        if let clash = clash(q) { line("Clashes", clash, color: .orange) }
                    }
                } else {
                    Text("Type what and when, like \"Dentist tomorrow 9am for 1 hour\".").foregroundStyle(.secondary)
                }
            }
            .font(.scaled(.callout)).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HStack(spacing: 14) {
                hint("Return", "add"); hint("Tab", "more options"); hint("Esc", "cancel")
                Spacer()
            }
            .font(.scaled(.caption)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 520)
        .floatingPanel(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    var destinationName: String {
        let d = store.calDefaultDestination
        if d.hasPrefix("google:") { return "Google Calendar · \(d.dropFirst(7))" }
        return store.calSource(d)?.title ?? store.calendar.writableCalendars.first { "mac:" + $0.calendarIdentifier == d }?.title ?? "Your calendar"
    }
    func clash(_ q: QuickEvent) -> String? {
        let end = q.start.addingTimeInterval(Double(q.minutes) * 60)
        return store.calShown.first { !$0.allDay && $0.start < end && $0.end > q.start }?.title
    }
    func line(_ label: String, _ value: String, color: Color = .primary) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).foregroundStyle(color).lineLimit(1) }
    }
    func hint(_ key: String, _ label: String) -> some View { HStack(spacing: 5) { KeyHint(key, size: 10); Text(label) } }
}

// MARK: Side panels

/// Left panel in the calendar: back to mail, then your calendars to show or hide. Same glass and place as the folders panel.
struct CalendarListPanel: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cal: CalendarService
    var body: some View {
        let hidden = store.calHidden
        VStack(alignment: .leading, spacing: 1) {
            nav("Mail", "envelope", "G I", on: false) { store.closeCalendar() }
            nav("Calendar", "calendar", "G C", on: true) {}
            Divider().padding(.vertical, 12).padding(.horizontal, 18)
            Text("Calendars").font(.scaled(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).padding(.horizontal, 18).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(groups, id: \.0) { group, sources in
                        Text(group).font(.scaled(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
                        ForEach(sources) { s in
                            let shown = !hidden.contains(s.id), color = Color(hex: s.colorHex) ?? Theme.accent
                            Button { store.toggleCalendarHidden(s.id) } label: {
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 4).fill(shown ? color : .clear)
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 2))
                                        .overlay { if shown { Image(systemName: "checkmark").font(.scaled(size: 8, weight: .bold)).foregroundStyle(.white) } }
                                        .frame(width: 14, height: 14)
                                    Text(s.title).font(.scaled(size: 14)).lineLimit(1).foregroundStyle(shown ? .primary : .secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 18).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).handCursor().help(shown ? "Hide \(s.title)" : "Show \(s.title)")
                        }
                    }
                    if !cal.authorized && !AppFlavor.isTesting && !AppFlavor.isDemo {
                        Button("Show my Mac's calendars") { Task { if await store.calendar.requestAccess() { await store.loadCalendar() } } }
                            .quiet().font(.scaled(.callout)).padding(.horizontal, 12).padding(.top, 10)
                    }
                    ForEach(Array(store.calNeedsAccess).sorted(), id: \.self) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(a)'s calendar needs your OK once.").font(.scaled(.caption)).foregroundStyle(.secondary)
                            Button("Allow calendar access") { Task { if await store.grantCalendarAccess(for: a) { await store.loadCalendar() } } }
                                .quiet().font(.scaled(.caption))
                        }.padding(.horizontal, 18).padding(.top, 10)
                    }
                }.padding(.bottom, 16)
            }
        }
        .padding(.top, 18)
        .frame(width: 270).frame(maxHeight: .infinity, alignment: .top)
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.leading, 10).padding(.vertical, 10).padding(.top, 24)
    }

    var groups: [(String, [CalSource])] {
        var order: [String] = [], by: [String: [CalSource]] = [:]
        for s in store.calSources { if by[s.group] == nil { order.append(s.group) }; by[s.group, default: []].append(s) }
        return order.map { ($0, by[$0]!) }
    }

    func nav(_ title: String, _ symbol: String, _ key: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.scaled(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.scaled(size: 14, weight: on ? .semibold : .regular))
                Spacer()
                KeyHint(key, size: 10)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(alignment: .leading) {
                if on { ZStack(alignment: .leading) { Rectangle().fill(Theme.selection); Rectangle().fill(Theme.accent).frame(width: 3) } }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }
}

/// Right panel in the calendar: a month to jump around in and what's coming up. Same glass and place as the context panel.
struct CalendarContextPanel: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MiniMonth()
            if let e = store.calSelectedEvent, let c = store.linkedConversation(e) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Linked email").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    Button { store.openLinkedEmail(e) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.latest.subject.isEmpty ? "(no subject)" : c.latest.subject).font(.scaled(.callout).weight(.semibold)).lineLimit(1)
                            HStack(spacing: 4) { Text("Open with").foregroundStyle(.secondary); KeyHint("O", size: 9.5) }.font(.scaled(.caption))
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))).contentShape(Rectangle())
                    }.buttonStyle(.plain).handCursor()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming · next 7 days").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
                if store.calUpcoming.isEmpty {
                    Text("Nothing in the next 7 days").font(.scaled(.callout)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.calUpcoming.prefix(12)) { e in
                            Button { store.calDate = e.start; store.reloadCalendar(); store.calSelected = e.id } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2).fill(store.calColor(e)).frame(width: 3, height: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(e.title).font(.scaled(.callout)).lineLimit(1)
                                            if e.unanswered { Text("· not answered").font(.scaled(.caption)).foregroundStyle(.orange) }
                                        }
                                        Text(upcomingWhen(e)).font(.scaled(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(ToolStyle())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 16)
        .frame(width: 280).frame(maxHeight: .infinity, alignment: .top)
        .glass(RoundedRectangle(cornerRadius: 20))
        .padding(.trailing, 10).padding(.vertical, 10).padding(.top, 24)
    }

    func upcomingWhen(_ e: CalEvent) -> String {
        let day = Calendar.current.isDateInToday(e.start) ? "Today" : Calendar.current.isDateInTomorrow(e.start) ? "Tomorrow"
            : e.start.formatted(.dateTime.weekday(.abbreviated).day())
        return e.allDay ? "\(day) · All day" : "\(day) · \(e.start.formatted(date: .omitted, time: .shortened))"
    }
}

struct MiniMonth: View {
    @EnvironmentObject var store: AppStore
    @State private var shown: Date?
    var body: some View {
        let month = shown ?? store.calDate
        let days = calendarDays(.month, around: month, mondayFirst: store.calMondayFirst)
        let viewDays = Set(store.calDays.map { Calendar.current.startOfDay(for: $0) })
        let m = Calendar.current.component(.month, from: month)
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.scaled(.headline))
                Spacer()
                Button { shown = stepDate(month, .month, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }.buttonStyle(ToolStyle()).help("Previous month")
                Button { shown = stepDate(month, .month, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }.buttonStyle(ToolStyle()).help("Next month")
            }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(days.prefix(7), id: \.self) { d in
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.scaled(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<6, id: \.self) { r in
                    GridRow {
                        ForEach(days[(r * 7)..<(r * 7 + 7)], id: \.self) { d in
                            let today = Calendar.current.isDateInToday(d), inView = viewDays.contains(d)
                            Button { shown = nil; store.calDate = d; store.calSelected = nil; store.reloadCalendar() } label: {
                                Text(d.formatted(.dateTime.day())).font(.scaled(size: 11, weight: today ? .bold : .regular))
                                    .foregroundStyle(today ? Color.white : Calendar.current.component(.month, from: d) == m ? Color.primary : Color.secondary.opacity(0.5))
                                    .frame(maxWidth: .infinity, minHeight: 22)
                                    .background {
                                        if today { Capsule().fill(Theme.accent) }
                                        else if inView { RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)) }
                                    }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: Place (Apple Maps)

/// The event's place: tap to change it (Apple Maps suggests addresses as you type), a map of it, and buttons to
/// open it in Maps or get directions.
struct PlaceSection: View {
    @EnvironmentObject var store: AppStore
    let event: CalEvent
    @State private var editing = false
    @State private var text = ""
    @State private var item: MKMapItem?
    @StateObject private var search = PlaceSearch()
    @FocusState private var focused: Bool

    var body: some View {
        let place = event.location.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "mappin.and.ellipse").font(.scaled(size: 13)).foregroundStyle(.secondary).frame(width: 16)
                if editing {
                    TextField("Add a place or address", text: $text).textFieldStyle(.plain).font(.scaled(.callout)).focused($focused)
                        .onChange(of: text) { _, t in search.query = t }
                        .onSubmit { save(text) }
                        .onExitCommand { editing = false }
                } else {
                    Button { text = place; editing = event.editable; focused = true } label: {
                        Text(place.isEmpty ? "Add location" : place).font(.scaled(.callout))
                            .foregroundStyle(place.isEmpty ? .secondary : .primary).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain).disabled(!event.editable).help(event.editable ? "Change the place" : "")
                }
            }
            if editing, !search.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results.prefix(5), id: \.self) { r in
                        Button { save(r.subtitle.isEmpty ? r.title : "\(r.title), \(r.subtitle)") } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).font(.scaled(.callout)).lineLimit(1)
                                if !r.subtitle.isEmpty { Text(r.subtitle).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(ToolStyle())
                    }
                }
                .padding(.leading, 18)
            }
            if !editing, let item {
                Map(initialPosition: .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))) {
                    Marker(item.name ?? place, coordinate: item.placemark.coordinate)
                }
                .mapControlVisibility(.hidden)
                .frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                .onTapGesture { item.openInMaps() }
                .help("Open in Maps")
                HStack(spacing: 6) {
                    Button { item.openInMaps() } label: { Label("Open in Maps", systemImage: "map") }.quiet()
                    Button { item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault]) } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }.quiet()
                }
                .font(.scaled(.caption))
            }
        }
        .task(id: place) { item = await PlaceSearch.find(place) }
    }

    func save(_ value: String) {
        editing = false
        store.setLocation(event, value)
    }
}

/// Apple Maps address suggestions as you type, and turning a place's text into a spot on the map.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    var query = "" { didSet { completer.queryFragment = query } }
    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }
    nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        let r = c.results
        Task { @MainActor in self.results = r }
    }
    nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// The first Apple Maps match for a place, or nil for empty text and links (a Zoom link isn't a place).
    static func find(_ place: String) async -> MKMapItem? {
        guard !place.isEmpty, !place.lowercased().hasPrefix("http"), !AppFlavor.isTesting else { return nil }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = place
        return try? await MKLocalSearch(request: req).start().mapItems.first
    }
}

// MARK: Editing in the card (E or the pencil)

/// Title, day, start and end, and notes, edited right in the event card. Place and calendar have their own rows.
struct EventEditor: View {
    @EnvironmentObject var store: AppStore
    let event: CalEvent
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var notes: String
    @FocusState private var titleFocused: Bool

    // Filled in before the view exists: setting them on appear counted as "you moved the start" and dragged the end along.
    init(event: CalEvent) {
        self.event = event
        _title = State(initialValue: event.title); _start = State(initialValue: event.start)
        _end = State(initialValue: event.end); _notes = State(initialValue: event.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title).textFieldStyle(.plain).font(.scaled(size: 15, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .focused($titleFocused).onSubmit(save).onExitCommand { store.calEditing = nil }
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.scaled(size: 13)).foregroundStyle(.secondary).frame(width: 16)
                DatePicker("", selection: $start, displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden()
                    .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }   // keeps the length
            }
            if !event.allDay {
                HStack(spacing: 8) {
                    Text("to").font(.scaled(.callout)).foregroundStyle(.secondary).frame(width: 16)
                    DatePicker("", selection: $end, in: start.addingTimeInterval(300)..., displayedComponents: [.hourAndMinute]).labelsHidden()
                    Text("\(max(0, Int(end.timeIntervalSince(start) / 60))) min").font(.scaled(.caption)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.alignleft").font(.scaled(size: 13)).foregroundStyle(.secondary).frame(width: 16).padding(.top, 6)
                TextEditor(text: $notes).font(.scaled(.callout)).frame(height: 64).scrollContentBackground(.hidden)
                    .padding(4).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            HStack {
                Spacer()
                Button("Cancel") { store.calEditing = nil }.quiet()
                Button("Save", action: save).keyboardShortcut(.defaultAction).primaryAction().controlSize(.regular)
            }
        }
        .onAppear { DispatchQueue.main.async { titleFocused = true } }
    }

    func save() {
        store.updateEvent(event, title: title, start: start, end: end, notes: notes)
        store.calEditing = nil
    }
}
