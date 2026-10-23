import AppKit
import EventKit
import EmailCore
import Foundation

/// Reads and writes the Mac's calendars (whatever is set up in the Calendar app: Google, iCloud, Exchange…).
@MainActor
final class CalendarService: ObservableObject {
    let store = EKEventStore()
    @Published var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    func requestAccess() async -> Bool {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        return authorized
    }

    func events(on day: Date) -> [EKEvent] {
        guard authorized else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
    }

    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard authorized else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    }

    /// Every Mac calendar, as the calendar screen lists them.
    var sources: [CalSource] {
        guard authorized else { return [] }
        return store.calendars(for: .event).map {
            CalSource(id: "mac:" + $0.calendarIdentifier, title: $0.title, group: $0.source.title,
                      colorHex: hex($0.cgColor), writable: $0.allowsContentModifications)
        }
    }

    /// One Mac event in the calendar screen's terms. Repeating events share an identifier, so the start time is part of the id.
    func calEvent(_ e: EKEvent) -> CalEvent {
        var c = CalEvent(id: "mac:\(e.eventIdentifier ?? "")|\(Int(e.startDate.timeIntervalSince1970))",
                         calendarId: "mac:" + e.calendar.calendarIdentifier, title: e.title ?? "Busy", start: e.startDate, end: e.endDate)
        c.allDay = e.isAllDay
        c.location = e.location ?? ""
        c.notes = e.notes ?? ""
        c.link = e.url
        c.uid = e.calendarItemExternalIdentifier ?? ""
        c.unanswered = e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .pending } ?? false
        c.editable = e.calendar.allowsContentModifications
        c.hasGuests = e.hasAttendees
        return c
    }

    /// The Mac event behind a calendar-screen id. For a repeating event, this occurrence rather than the series' first one.
    func ekEvent(_ id: String) -> EKEvent? {
        let ident = String(id.dropFirst(4).split(separator: "|").first ?? "")
        let start = Double(id.split(separator: "|").last ?? "") ?? 0
        return events(from: Date(timeIntervalSince1970: start - 1), to: Date(timeIntervalSince1970: start + 1))
            .first { $0.eventIdentifier == ident } ?? store.event(withIdentifier: ident)
    }

    func remove(_ id: String) throws {
        guard let e = ekEvent(id) else { return }
        try store.remove(e, span: .thisEvent)
    }

    /// Changes one Mac event (this occurrence only) and saves it.
    func update(_ id: String, _ change: (EKEvent) -> Void) throws {
        guard let e = ekEvent(id) else { throw AppError("That event is no longer in your calendar.") }
        change(e)
        try store.save(e, span: .thisEvent)
    }

    private func hex(_ c: CGColor) -> String {
        let n = NSColor(cgColor: c)?.usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }

    var writableCalendars: [EKCalendar] { store.calendars(for: .event).filter(\.allowsContentModifications) }

    /// Writable Mac events with this title starting at this time: the copy an earlier answer to an invite made.
    func matching(title: String, start: Date) -> [EKEvent] {
        let p = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: writableCalendars)
        return store.events(matching: p).filter { $0.title == title && abs($0.startDate.timeIntervalSince(start)) < 60 }
    }

    func remove(_ e: EKEvent) throws { try store.remove(e, span: .thisEvent) }

    func create(title: String, start: Date, minutes: Int, notes: String, location: String, calendar: EKCalendar?) throws {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = start.addingTimeInterval(Double(minutes) * 60)
        e.notes = notes.isEmpty ? nil : notes
        e.location = location.isEmpty ? nil : location
        e.calendar = calendar ?? store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent)
    }
}
