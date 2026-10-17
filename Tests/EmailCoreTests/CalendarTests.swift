import XCTest
@testable import EmailCore

final class CalendarTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }
    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = cal.timeZone
        return f.date(from: s)!
    }
    func ev(_ id: String, _ s: String, _ e: String, uid: String = "") -> CalEvent {
        var x = CalEvent(id: id, calendarId: "c", title: id, start: date(s), end: date(e)); x.uid = uid; return x
    }

    func testWeekStartsOnTheChosenDay() {
        let sat = date("2026-10-17 10:30")
        let mon = calendarDays(.week, around: sat, mondayFirst: true, calendar: cal)
        XCTAssertEqual(mon.count, 7)
        XCTAssertEqual(mon.first, date("2026-10-12 00:00"), "Monday-first week of Sat Oct 17 starts Mon Oct 12")
        let sun = calendarDays(.week, around: sat, mondayFirst: false, calendar: cal)
        XCTAssertEqual(sun.first, date("2026-10-11 00:00"), "Sunday-first week starts Sun Oct 11")
        XCTAssertEqual(calendarDays(.day, around: sat, mondayFirst: true, calendar: cal), [date("2026-10-17 00:00")])
    }

    func testMonthShowsSixFullWeeksCoveringTheMonth() {
        let days = calendarDays(.month, around: date("2026-10-17 10:30"), mondayFirst: true, calendar: cal)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(days.first, date("2026-09-28 00:00"), "October 2026 grid starts on Monday Sep 28")
        XCTAssertTrue(days.contains(date("2026-10-31 00:00")))
    }

    func testStepMovesByTheViewsUnit() {
        let d = date("2026-10-17 10:00")
        XCTAssertEqual(stepDate(d, .day, by: 1, calendar: cal), date("2026-10-18 10:00"))
        XCTAssertEqual(stepDate(d, .week, by: -1, calendar: cal), date("2026-10-10 10:00"))
        XCTAssertEqual(stepDate(d, .month, by: 1, calendar: cal), date("2026-11-17 10:00"))
    }

    func testOverlappingEventsSitSideBySide() {
        let cols = overlapColumns([ev("a", "2026-10-13 11:00", "2026-10-13 12:00"),
                                   ev("b", "2026-10-13 11:00", "2026-10-13 12:00"),
                                   ev("c", "2026-10-13 11:30", "2026-10-13 12:30"),
                                   ev("d", "2026-10-13 15:00", "2026-10-13 16:00")])
        XCTAssertEqual(cols["a"]?.of, 3); XCTAssertEqual(cols["b"]?.of, 3); XCTAssertEqual(cols["c"]?.of, 3)
        XCTAssertEqual(Set([cols["a"]!.col, cols["b"]!.col, cols["c"]!.col]), [0, 1, 2], "each overlapping event gets its own column")
        XCTAssertEqual(cols["d"]!.col, 0); XCTAssertEqual(cols["d"]!.of, 1, "an event on its own is full width")
    }

    func testBackToBackEventsDontShareColumns() {
        let cols = overlapColumns([ev("a", "2026-10-13 09:00", "2026-10-13 10:00"), ev("b", "2026-10-13 10:00", "2026-10-13 11:00")])
        XCTAssertEqual(cols["a"]?.of, 1); XCTAssertEqual(cols["b"]?.of, 1)
    }

    func testTheSameEventFromTwoSourcesShowsOnce() {
        let list = dedupeEvents([ev("google-1", "2026-10-13 11:00", "2026-10-13 12:00", uid: "abc@google.com"),
                                 ev("mac-1", "2026-10-13 11:00", "2026-10-13 12:00", uid: "abc@google.com"),
                                 ev("mac-2", "2026-10-14 11:00", "2026-10-14 12:00", uid: "abc@google.com"),   // a later occurrence
                                 ev("x", "2026-10-13 11:00", "2026-10-13 12:00")])
        XCTAssertEqual(list.map(\.id), ["google-1", "mac-2", "x"])
    }

    func testMeetingLinkIsFoundAnywhereInTheEvent() {
        var e = ev("a", "2026-10-13 11:00", "2026-10-13 12:00")
        XCTAssertNil(e.conference)
        e.notes = "Agenda attached.\nJoin: https://northwind.zoom.us/j/84213377120?pwd=x"
        XCTAssertEqual(e.conference?.kind, .zoom)
        e.notes = ""; e.location = "https://meet.google.com/xpa-rbuq-kte"
        XCTAssertEqual(e.conference?.kind, .meet)
    }

    func testQuickAddReadsTitleTimePlaceAndLength() throws {
        let now = date("2026-10-17 10:30")   // Saturday
        let q = try XCTUnwrap(parseQuickEvent("Lunch with Priya fri 1pm at Tartine, 45 min", now: now))
        XCTAssertEqual(q.title, "Lunch with Priya")
        XCTAssertEqual(q.location, "Tartine")
        XCTAssertEqual(q.minutes, 45)
        XCTAssertGreaterThan(q.start, now)
        XCTAssertEqual(Calendar.current.component(.hour, from: q.start), 13)
        XCTAssertEqual(Calendar.current.component(.weekday, from: q.start), 6, "Friday")

        let r = try XCTUnwrap(parseQuickEvent("Dentist tomorrow at 9am for 2 hours", now: now))
        XCTAssertEqual(r.title, "Dentist"); XCTAssertEqual(r.minutes, 120)
        XCTAssertNil(parseQuickEvent("just some words", now: now), "no time, no event")
        XCTAssertNil(parseQuickEvent("Standup today 9am", now: now), "a time that already passed today isn't moved to another day")
    }

    func testJAndKWalkEventsInTimeOrder() {
        let list = [ev("late", "2026-10-13 15:00", "2026-10-13 16:00"), ev("early", "2026-10-12 09:00", "2026-10-12 10:00"),
                    ev("mid", "2026-10-13 09:00", "2026-10-13 10:00")]
        XCTAssertEqual(neighborEvent(list, after: nil, step: 1)?.id, "early")
        XCTAssertEqual(neighborEvent(list, after: "early", step: 1)?.id, "mid")
        XCTAssertEqual(neighborEvent(list, after: "late", step: 1)?.id, "late", "stays on the last one")
        XCTAssertEqual(neighborEvent(list, after: "mid", step: -1)?.id, "early")
    }

    func testMacCopiesOfGoogleCalendarsKeymailReadsAreDropped() {
        let sources = [CalSource(id: "google:you@gmail.com", title: "Gmail", group: "Gmail · you@gmail.com", colorHex: "#4285F4", writable: true),
                       CalSource(id: "mac:A", title: "you@gmail.com", group: "Google", colorHex: "#000000", writable: true),
                       CalSource(id: "mac:B", title: "Family", group: "Google", colorHex: "#000000", writable: true),
                       CalSource(id: "mac:C", title: "other@work.com", group: "Exchange", colorHex: "#000000", writable: true)]
        let events = [CalEvent(id: "1", calendarId: "mac:A", title: "x", start: Date(), end: Date()),
                      CalEvent(id: "2", calendarId: "mac:B", title: "y", start: Date(), end: Date())]
        let (s, e) = dropMirroredCalendars(sources, events, direct: ["you@gmail.com"])
        XCTAssertEqual(s.map(\.id), ["google:you@gmail.com", "mac:B", "mac:C"], "the Mac copy of the account Keymail reads goes; other calendars stay")
        XCTAssertEqual(e.map(\.id), ["2"])
    }
}
