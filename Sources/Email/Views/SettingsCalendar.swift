import SwiftUI
import EmailCore

/// Settings → Calendar: where events come from, and how the calendar screen behaves.
struct CalendarSettings: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var cal: CalendarService
    @AppStorage("calendarEnabled") private var enabled = true
    @AppStorage("calendarMondayFirst") private var mondayFirst = Calendar.current.firstWeekday == 2
    @AppStorage("calendarView") private var view = "week"
    @AppStorage("calendarDefault") private var destination = ""
    @AppStorage("inviteDayStrip") private var inviteDayStrip = true

    var body: some View {
        Form {
            Section {
                ForEach(store.gmailAccounts + store.state.accounts.filter(store.isMicrosoft), id: \.self) { a in
                    LabeledContent {
                        if store.calNeedsAccess.contains(a) {
                            Button("Allow calendar access") { Task { if await store.grantCalendarAccess(for: a) { await store.loadCalendar() } } }.quiet()
                        } else { Text("Connected").foregroundStyle(.secondary) }
                    } label: {
                        HStack(spacing: 10) {
                            BrandLogo(brand: store.isMicrosoft(a) ? "microsoft" : "google", size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(store.label(a))
                                Text("\(store.isMicrosoft(a) ? "Outlook" : "Gmail") · \(a)").font(.scaled(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                LabeledContent {
                    if cal.authorized { Text("Connected").foregroundStyle(.secondary) }
                    else { Button("Allow calendar access") { Task { if await store.calendar.requestAccess() { await store.loadCalendar() } } }.quiet() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar").frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Your Mac's calendars")
                            Text("iCloud, Exchange and anything else in the Calendar app").font(.scaled(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Calendars").settingAnchor("Calendars") } footer: {
                Text("Gmail and Outlook calendars come straight from your Keymail accounts. If an account needs your OK, Keymail asks once and your mail keeps working either way. Events that show up in two places appear once.").settingsFooter()
            }
            Section("Calendar") {
                Toggle(isOn: $enabled) { Text("Show the calendar"); Text("Adds Calendar beside Mail. Switch with G C.") }
                    .settingAnchor("Show the calendar")
                    .onChange(of: enabled) { _, on in if !on { store.closeCalendar() } }
                Picker("Week starts on", selection: $mondayFirst) { Text("Monday").tag(true); Text("Sunday").tag(false) }
                    .pickerStyle(.segmented).settingAnchor("Week starts on")
                Picker("Default view", selection: $view) { ForEach(CalView.allCases, id: \.self) { Text($0.title).tag($0.rawValue) } }
                    .pickerStyle(.segmented).settingAnchor("Default view")
                Picker("New events go to", selection: $destination) {
                    Text("Automatic").tag("")
                    ForEach(store.gmailAccounts, id: \.self) { a in Text("Google Calendar · \(a)").tag("google:" + a) }
                    ForEach(store.calSources.filter { $0.id.hasPrefix("outlook:") && $0.writable }) { c in Text("\(c.title) · \(store.outlookAccount(c.id))").tag(c.id) }
                    ForEach(cal.writableCalendars, id: \.calendarIdentifier) { c in Text("\(c.title) · \(c.source.title)").tag("mac:" + c.calendarIdentifier) }
                }.settingAnchor("New events go to")
            }
            if !store.calSources.isEmpty {
                Section {
                    ForEach(store.calSources) { c in
                        LabeledContent {
                            HStack(spacing: 6) {
                                // The current color comes first when it isn't one of ours, so the ring always shows what's in use.
                                let own = AppStore.calendarPalette.contains { $0.uppercased() == c.colorHex.uppercased() } ? [] : [c.colorHex]
                                ForEach(own + AppStore.calendarPalette, id: \.self) { hex in
                                    let on = c.colorHex.uppercased() == hex.uppercased()
                                    Button { store.setCalendarColor(c.id, hex) } label: {
                                        Circle().fill(Color(hex: hex) ?? .gray).frame(width: 16, height: 16)
                                            .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.9 : 0), lineWidth: 2).padding(-3))
                                    }
                                    .buttonStyle(.plain).handCursor().accessibilityLabel("Color \(hex)")
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title)
                                Text(c.group).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                } header: { Text("Colors").settingAnchor("Calendar colors") } footer: {
                    Text("Changes how each calendar looks in Keymail only.").settingsFooter()
                }
            }
            Section("Invites") {
                Toggle(isOn: $inviteDayStrip) { Text("Show my day beside invites"); Text("A strip of the rest of that day on invite emails, so clashes show before you answer. Y, ? and N answer.") }
                    .settingAnchor("Show my day beside invites")
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .task { await store.loadCalendar() }   // fills in which accounts still need your OK
    }
}
