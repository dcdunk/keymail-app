import EventKit
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

    var writableCalendars: [EKCalendar] { store.calendars(for: .event).filter(\.allowsContentModifications) }

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
