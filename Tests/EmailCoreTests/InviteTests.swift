import XCTest
@testable import EmailCore

final class InviteTests: XCTestCase {
    // Trimmed from a real Google Calendar invite: Meet link, UTC times, folded DESCRIPTION.
    let google = """
    BEGIN:VCALENDAR\r
    PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
    VERSION:2.0\r
    METHOD:REQUEST\r
    BEGIN:VEVENT\r
    DTSTART:20261020T170000Z\r
    DTEND:20261020T173000Z\r
    ORGANIZER;CN=Pat Lee:mailto:pat@example.com\r
    UID:abc123@google.com\r
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Pat Lee:mailto:pat@example.com\r
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=dcdunk@gmail.com;X-NUM-GUESTS=0:mailto:dcdunk@gmail.com\r
    X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r
    DESCRIPTION:Weekly sync\\, bring notes.\\n\\nJoin with Google Meet: https://meet.goo\r
     gle.com/abc-defg-hij\r
    SEQUENCE:0\r
    SUMMARY:Product sync\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    // Outlook / Teams style: Windows time zone name, Teams link only in the description.
    let teams = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VTIMEZONE\r
    TZID:Pacific Standard Time\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    ORGANIZER;CN="Sam, Ortiz":mailto:sam@contoso.com\r
    ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Danny:mailto:dcdunk@gmail.com\r
    DESCRIPTION;LANGUAGE=en-US:Microsoft Teams meeting\\nJoin: https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d\\n\r
    UID:040000008200E00074C5B7101A82E008\r
    SUMMARY;LANGUAGE=en-US:Budget review\r
    DTSTART;TZID=Pacific Standard Time:20261021T090000\r
    DTEND;TZID=Pacific Standard Time:20261021T100000\r
    SEQUENCE:2\r
    LOCATION;LANGUAGE=en-US:Microsoft Teams Meeting\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    func testGoogleMeetInvite() {
        let i = parseInvite(google)!
        XCTAssertEqual(i.summary, "Product sync"); XCTAssertEqual(i.uid, "abc123@google.com")
        XCTAssertEqual(i.organizer, "pat@example.com"); XCTAssertEqual(i.organizerName, "Pat Lee")
        XCTAssertEqual(i.start, Date(timeIntervalSince1970: 1792515600)); XCTAssertEqual(i.end, Date(timeIntervalSince1970: 1792517400))
        XCTAssertEqual(i.conference?.kind, .meet); XCTAssertEqual(i.conference?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertTrue(i.details.contains("Weekly sync, bring notes."))
        XCTAssertNil(i.status(of: "dcdunk@gmail.com")); XCTAssertEqual(i.status(of: "PAT@example.com"), .accepted)
    }

    func testTeamsInviteWithWindowsTimeZoneAndQuotedName() {
        let i = parseInvite(teams)!
        XCTAssertEqual(i.organizerName, "Sam, Ortiz"); XCTAssertEqual(i.sequence, 2)
        XCTAssertEqual(i.conference?.kind, .teams)
        XCTAssertTrue(i.conference!.url.absoluteString.hasPrefix("https://teams.microsoft.com/l/meetup-join/"))
        // 9:00 Pacific (PDT in October) = 16:00 UTC
        XCTAssertEqual(i.start, Date(timeIntervalSince1970: 1792598400))
    }

    func testZoomLinkInLocation() {
        let z = google.replacingOccurrences(of: "X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r\n", with: "LOCATION:https://us02web.zoom.us/j/8123456789?pwd=abc\r\n")
            .replacingOccurrences(of: "Join with Google Meet: https://meet.goo\r\n gle.com/abc-defg-hij", with: "")
        let c = parseInvite(z)!.conference!
        XCTAssertEqual(c.kind, .zoom); XCTAssertEqual(c.url.absoluteString, "https://us02web.zoom.us/j/8123456789?pwd=abc")
    }

    func testCancellationAndNonInvites() {
        XCTAssertTrue(parseInvite(google.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL"))!.isCancelled)
        XCTAssertNil(parseInvite(google.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:REPLY"))) // someone else's answer
        XCTAssertNil(parseInvite("not a calendar"))
    }

    func testReplyCarriesWhatOrganizersNeed() {
        let i = parseInvite(teams)!
        let r = inviteReply(i, from: "dcdunk@gmail.com", name: "Danny", answer: .accepted, now: Date(timeIntervalSince1970: 0))
        for needed in ["METHOD:REPLY", "UID:040000008200E00074C5B7101A82E008", "SEQUENCE:2", "ORGANIZER:mailto:sam@contoso.com",
                       "ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Danny\":mailto:dcdunk@gmail.com", "DTSTART:20261021T160000Z", "DTSTAMP:19700101T000000Z"] {
            XCTAssertTrue(r.contains(needed), needed)
        }
        // Round trip: our reply parses as a REPLY (so parseInvite ignores it) and keeps CRLF line ends.
        XCTAssertNil(parseInvite(r)); XCTAssertTrue(r.hasSuffix("END:VCALENDAR\r\n"))
    }

    func testReplyEmailHasCalendarPart() {
        var d = Draft(from: "dcdunk@gmail.com"); d.to = "sam@contoso.com"; d.subject = "Accepted: Budget review"; d.body = "Yes"
        d.calendarReply = inviteReply(parseInvite(teams)!, from: "dcdunk@gmail.com", answer: .declined)
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("multipart/alternative")); XCTAssertTrue(raw.contains("Content-Type: text/calendar; method=REPLY; charset=UTF-8"))
    }
}
