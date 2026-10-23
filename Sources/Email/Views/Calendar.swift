import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Calendar

struct CalendarSection: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cal: CalendarService   // redraws when access is granted
    let conversation: Conversation
    var body: some View {
        content.task { if !store.calTriedLoad { store.calTriedLoad = true; await store.loadCalendar() } }
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(header)
                    .font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if store.calendarEnabled {
                    Button { store.openCalendar() } label: { Text("Open calendar ›").font(.scaled(.caption).weight(.semibold)).foregroundStyle(Theme.accent) }
                        .buttonStyle(.plain).handCursor().help("Calendar (G C)")
                }
                Button { store.createEventFromEmail() } label: { Image(systemName: "calendar.badge.plus").frame(width: 26, height: 26) }
                    .buttonStyle(ToolStyle()).help("Create event (\(Hotkeys.label("b")))")
            }
            // Reading an invite: its day instead of today, with the invite in it.
            if let day = store.inviteDay, let open = store.openInvite, open.invite.uid == day.uid,
               conversation.messages.contains(where: { $0.key == open.message.key }) {
                inviteDay(day, invite: open.invite)
            } else { today }

        }
    }

    @ViewBuilder var today: some View {
            // The same events as the calendar screen: Gmail calendars straight from Google, plus the Mac's calendars.
            let today = store.calUpcoming.filter { Calendar.current.isDateInToday($0.start) || ($0.start < Date() && $0.end > Date()) }
            if store.calSources.isEmpty && !cal.authorized {
                Button("Show my calendar") { Task { _ = await store.calendar.requestAccess(); await store.loadCalendar() } }.quiet().font(.scaled(.callout))
            } else if today.isEmpty {
                Text("Nothing else today").font(.scaled(.callout)).foregroundStyle(.tertiary)
            }
            ForEach(today.prefix(6)) { e in
                Button { store.calDate = e.start; store.openCalendar(); store.calSelected = e.id } label: {   // on its own day
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(store.calColor(e)).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.scaled(.callout)).lineLimit(1)
                            Text(e.allDay ? "All day" : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                .font(.scaled(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).handCursor().help("Open in the calendar")
            }
    }

    var header: String {
        if let day = store.inviteDay, let open = store.openInvite, open.invite.uid == day.uid,
           conversation.messages.contains(where: { $0.key == open.message.key }), !Calendar.current.isDateInToday(day.day) {
            return day.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return "Today's Events"
    }

    @ViewBuilder func inviteDay(_ day: InviteDay, invite: Invite) -> some View {
        let rows = (day.events.map { (Optional($0), $0.title, $0.start, $0.end) } + [(nil, invite.summary, invite.start ?? day.day, invite.end ?? day.day)])
            .sorted { $0.2 < $1.2 }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(r.0.map(store.calColor) ?? Theme.accent).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.1).font(.scaled(.callout).weight(r.0 == nil ? .semibold : .regular)).lineLimit(1)
                    Text("\(r.2.formatted(date: .omitted, time: .shortened)) – \(r.3.formatted(date: .omitted, time: .shortened))\(r.0 == nil ? " · this invite" : "")")
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }
}


struct EventSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    @State var draft: EventDraft
    @State private var destination = ""          // "google:<account>" or "mac:<calendar id>"
    @State private var guests: Set<String> = []
    @State private var invite = true
    @State private var meet = false
    @State private var saving = false
    @State private var needsAccess = false
    @State private var error: String?

    var googleAccount: String? { destination.hasPrefix("google:") ? String(destination.dropFirst(7)) : nil }
    var gmailAccounts: [String] { store.gmailAccounts }
    /// Mac calendars, minus Google calendars Keymail can already reach directly (they'd show twice).
    var macCalendars: [EKCalendar] {
        let direct = Set(gmailAccounts.map { $0.lowercased() })
        return store.calendar.writableCalendars.filter { !direct.contains($0.title.lowercased()) }
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }
    var end: Date { draft.start.addingTimeInterval(Double(draft.minutes) * 60) }

    var body: some View {
        VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New event").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                TextField("Event title", text: $draft.title).textFieldStyle(.plain).font(.scaled(size: 22, weight: .semibold))
            }

            section("clock") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $draft.start, displayedComponents: .date).labelsHidden().fixedSize()
                        DatePicker("", selection: $draft.start, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                        Text("to \(end.formatted(date: Calendar.current.isDate(end, inSameDayAs: draft.start) ? .omitted : .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Picker("", selection: $draft.minutes) {
                        Text("15m").tag(15); Text("30m").tag(30); Text("45m").tag(45); Text("1h").tag(60); Text("90m").tag(90); Text("2h").tag(120)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                    if draft.timeFromEmail {
                        Label("Time found in the email", systemImage: "sparkles").font(.scaled(.caption)).foregroundStyle(Theme.accent)
                    }
                }
            }

            section("calendar") {
                if googleAccount != nil { BrandLogo(brand: "google", size: 14) }
                else if let c = macCalendars.first(where: { "mac:" + $0.calendarIdentifier == destination }) {
                    Circle().fill(Color(cgColor: c.cgColor)).frame(width: 10, height: 10)
                }
                Menu {
                    if !gmailAccounts.isEmpty {
                        Section("Google Calendar") {
                            ForEach(gmailAccounts, id: \.self) { a in Button(a) { destination = "google:" + a } }
                        }
                    }
                    ForEach(Dictionary(grouping: macCalendars, by: { $0.source.title }).sorted { $0.key < $1.key }, id: \.key) { src, cals in
                        Section("Mac Calendar · \(src)") {
                            ForEach(cals, id: \.calendarIdentifier) { c in Button(c.title) { destination = "mac:" + c.calendarIdentifier } }
                        }
                    }
                } label: { destinationLabel }
                .menuStyle(.borderlessButton).fixedSize()
            }

            if !draft.people.isEmpty {
                section("person.2") {
                    VStack(alignment: .leading, spacing: 8) {
                        FlowChips(people: draft.people, selected: $guests, enabled: googleAccount != nil)
                        if googleAccount != nil {
                            Toggle("Email invitations to guests", isOn: $invite).toggleStyle(.checkbox).disabled(guests.isEmpty)
                        } else {
                            Text("Mac calendars can't send invitations. Guests are listed in the notes instead.")
                                .font(.scaled(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            section("video") {
                VStack(alignment: .leading, spacing: 8) {
                    if googleAccount != nil { Toggle("Add a Google Meet link", isOn: $meet).toggleStyle(.checkbox) }
                    if !meet { TextField("Location or video link", text: $draft.location).textFieldStyle(.roundedBorder) }
                }
            }

            section("text.alignleft") {
                TextEditor(text: $draft.notes).font(.scaled(.callout)).frame(height: 60).scrollContentBackground(.hidden)
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            if needsAccess, let a = googleAccount {
                HStack(spacing: 8) {
                    Text("Keymail needs your OK to add events to \(a)'s Google Calendar.").font(.scaled(.caption)).foregroundStyle(.secondary)
                    Button("Allow calendar access") { Task { if await store.grantCalendarAccess(for: a) { needsAccess = false; save() } } }.quiet().font(.scaled(.caption))
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.scaled(.callout)).fixedSize(horizontal: false, vertical: true) }

            }
            .padding(24)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.quiet().keyboardShortcut(.cancelAction)
                Button { save() } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small) }
                        Text(googleAccount != nil ? (invite && !guests.isEmpty ? "Add and invite" : "Add to Google Calendar") : "Add to calendar")
                    }
                }
                .keyboardShortcut(.defaultAction).primaryAction()
                .disabled(saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || destination.isEmpty)
            }
            .actionBar()
        }
        .frame(width: 520)
        .onAppear {
            if gmailAccounts.contains(draft.account) { destination = "google:" + draft.account }
            else if let c = store.calendar.store.defaultCalendarForNewEvents { destination = "mac:" + c.calendarIdentifier }
            else if let a = gmailAccounts.first { destination = "google:" + a }
            guests = draft.suggestGuests ? Set(draft.people.map(\.email).filter { !isAutomatedAddress($0) }) : []
        }
    }

    /// A row with a leading icon, like Calendar's own event editor.
    func section<C: View>(_ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            content()
        }
    }

    @ViewBuilder var destinationLabel: some View {
        if let a = googleAccount { Text("Google Calendar · \(a)") }
        else if let c = macCalendars.first(where: { "mac:" + $0.calendarIdentifier == destination }) { Text("\(c.title) · \(c.source.title)") }
        else { Text("Choose a calendar") }
    }

    func save() {
        error = nil
        if let a = googleAccount {
            saving = true
            Task {
                defer { saving = false }
                do {
                    let picked = draft.people.map(\.email).filter { guests.contains($0) }
                    _ = try await store.createGoogleEvent(draft, account: a, guests: picked, invite: invite, meet: meet)
                    store.banner = "Added \"\(draft.title)\" to Google Calendar" + (invite && !picked.isEmpty ? " and invited \(picked.count) \(picked.count == 1 ? "person" : "people")." : ".")
                    dismiss()
                } catch is NeedsCalendarAccess { needsAccess = true }
                catch { self.error = error.localizedDescription }
            }
        } else {
            do {
                let cal = macCalendars.first { "mac:" + $0.calendarIdentifier == destination }
                let names = draft.people.map(\.formatted).joined(separator: ", ")
                try store.calendar.create(title: draft.title, start: draft.start, minutes: draft.minutes,
                                          notes: draft.notes + (names.isEmpty ? "" : "\nWith: \(names)"), location: draft.location, calendar: cal)
                store.banner = "Added \"\(draft.title)\" to \(cal?.title ?? "your calendar")."
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// People on the email as toggleable chips (on = invited).
struct FlowChips: View {
    let people: [Address]
    @Binding var selected: Set<String>
    var enabled: Bool
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }
    @ViewBuilder var chips: some View {
        ForEach(people, id: \.email) { p in
            let on = enabled && selected.contains(p.email)
            Button {
                if selected.contains(p.email) { selected.remove(p.email) } else { selected.insert(p.email) }
            } label: {
                HStack(spacing: 4) {
                    if enabled { Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.accent : .secondary) }
                    Text(p.name.isEmpty ? p.email : p.name).lineLimit(1)
                }
                .font(.scaled(.callout)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? Theme.selection : Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain).disabled(!enabled).help(p.email)
        }
    }
}
