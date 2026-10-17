import XCTest
import SwiftUI
import EmailCore
@testable import Email

/// Outlook events as Microsoft Graph returns them, read into the calendar screen's terms.
@MainActor
final class CalendarSourcesTests: XCTestCase {
    let cal = CalSource(id: "outlook:me@work.com|AAA", title: "Calendar", group: "Outlook · me@work.com", colorHex: "#0F6CBD", writable: true)
    var oc: OutlookCalendar { OutlookCalendar(account: "me@work.com", auth: MicrosoftAuth()) }

    func testAMeetingInviteWithATeamsLink() throws {
        let e = try XCTUnwrap(oc.parse([
            "id": "EV1", "subject": "Client Meeting",
            "start": ["dateTime": "2026-10-13T18:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-10-13T19:00:00.0000000", "timeZone": "UTC"],
            "isAllDay": false, "location": ["displayName": "Room 4B"], "bodyPreview": "Agenda",
            "onlineMeeting": ["joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x"],
            "iCalUId": "uid-1", "responseStatus": ["response": "notResponded"], "isOrganizer": false,
        ], calendar: cal))
        XCTAssertEqual(e.id, "outlook:me@work.com|EV1")
        XCTAssertEqual(e.start, ISO8601DateFormatter().date(from: "2026-10-13T18:00:00Z"), "Graph's UTC times are read as UTC")
        XCTAssertEqual(e.location, "Room 4B")
        XCTAssertEqual(e.conference?.kind, .teams, "the Teams link becomes the Join button")
        XCTAssertTrue(e.unanswered, "an invite you haven't answered")
        XCTAssertFalse(e.editable, "someone else's meeting can't be deleted from here")
    }

    func testAllDayEventsLandOnTheLocalDay() throws {
        let e = try XCTUnwrap(oc.parse([
            "id": "EV2", "subject": "Offsite", "isAllDay": true, "isOrganizer": true,
            "start": ["dateTime": "2026-10-20T00:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-10-21T00:00:00.0000000", "timeZone": "UTC"],
        ], calendar: cal))
        XCTAssertEqual(Calendar.current.component(.day, from: e.start), 20)
        XCTAssertEqual(Calendar.current.component(.hour, from: e.start), 0, "midnight here, not midnight in London")
        XCTAssertTrue(e.allDay); XCTAssertTrue(e.editable); XCTAssertFalse(e.unanswered)
    }

    func testCancelledEventsAreLeftOut() {
        XCTAssertNil(oc.parse(["id": "X", "isCancelled": true,
                               "start": ["dateTime": "2026-10-13T18:00:00", "timeZone": "UTC"],
                               "end": ["dateTime": "2026-10-13T19:00:00", "timeZone": "UTC"]], calendar: cal))
    }

    func testGoogleEventsReadTheSameWay() throws {
        let e = try XCTUnwrap(GoogleCalendar.parse(account: "you@gmail.com")([
            "id": "g1", "summary": "Product Sync", "status": "confirmed",
            "start": ["dateTime": "2026-10-12T11:00:00-07:00"], "end": ["dateTime": "2026-10-12T12:00:00-07:00"],
            "hangoutLink": "https://meet.google.com/xpa-rbuq-kte", "htmlLink": "https://www.google.com/calendar/event?eid=abc",
            "iCalUID": "g1@google.com", "attendees": [["email": "you@gmail.com", "self": true, "responseStatus": "needsAction"]],
            "organizer": ["email": "maya@northwind.co"],
        ]))
        XCTAssertEqual(e.conference?.kind, .meet)
        XCTAssertEqual(e.link?.host, "www.google.com", "Edit opens the event in Google Calendar")
        XCTAssertTrue(e.unanswered)
        XCTAssertFalse(e.editable, "someone else's event")
        XCTAssertNil(GoogleCalendar.parse(account: "you@gmail.com")(["id": "x", "status": "cancelled", "start": [:], "end": [:]]))
    }

    /// Regression: switching from month to week crashed because the month grid drew once more with only 7 days.
    func testMonthGridDrawsSafelyWhileSwitchingToWeek() async {
        let store = AppStore()
        store.state.accounts = ["you@gmail.com"]
        store.openCalendar()
        await store.loadCalendar()
        UserDefaults.standard.set("week", forKey: "calendarView")
        let host = NSHostingView(rootView: MonthGrid().environmentObject(store).frame(width: 900, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(store.calDays.count, 7, "the store is on week view while the month grid draws")
    }
}
