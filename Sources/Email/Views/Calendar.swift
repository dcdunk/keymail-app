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
        let mentioned = parseWhen(String(conversation.latest.plainText.prefix(4000)))
        let day = mentioned ?? Date()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mentioned == nil ? "Today" : "Mentioned: \(day.formatted(.dateTime.weekday(.abbreviated).month().day()))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.createEventFromEmail() } label: { Image(systemName: "calendar.badge.plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Create event (B)")
            }
            if !cal.authorized {
                Button("Show my calendar") { Task { _ = await store.calendar.requestAccess() } }.controlSize(.small)
            } else {
                let events = cal.events(on: day)
                if events.isEmpty { Text("Nothing scheduled").font(.callout).foregroundStyle(.tertiary) }
                ForEach(events.prefix(6), id: \.eventIdentifier) { e in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: e.calendar.cgColor)).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title ?? "Busy").font(.callout).lineLimit(1)
                            Text(e.isAllDay ? "All day" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}


struct EventSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.closeCard) private var dismiss
    @State var draft: EventDraft
    @State private var calendarId = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New event").font(.title2.weight(.semibold))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            DatePicker("Starts", selection: $draft.start)
            Picker("Length", selection: $draft.minutes) {
                Text("15 min").tag(15); Text("30 min").tag(30); Text("45 min").tag(45); Text("1 hour").tag(60); Text("2 hours").tag(120)
            }
            Picker("Calendar", selection: $calendarId) {
                ForEach(store.calendar.writableCalendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
            }
            TextField("Location or video link", text: $draft.location).textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.notes).frame(height: 80).font(.callout)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            Text("Invitations to the people on the email aren't sent; they're listed in the notes.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to calendar") {
                    do {
                        let cal = store.calendar.writableCalendars.first { $0.calendarIdentifier == calendarId }
                        try store.calendar.create(title: draft.title, start: draft.start, minutes: draft.minutes,
                                                  notes: draft.notes, location: draft.location, calendar: cal)
                        store.banner = "Added \"\(draft.title)\" to your calendar."
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).prominentGlassButton()
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { calendarId = store.calendar.store.defaultCalendarForNewEvents?.calendarIdentifier ?? "" }
    }
}
