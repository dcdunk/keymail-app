import Foundation

// MARK: Calendar invites (iCalendar / iTIP, RFC 5545 + 5546)

public enum RSVP: String, CaseIterable, Sendable {
    case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"
    /// Google Calendar API's responseStatus for the same answer.
    public var google: String { ["ACCEPTED": "accepted", "TENTATIVE": "tentative", "DECLINED": "declined"][rawValue]! }
    public var label: String { ["ACCEPTED": "Yes", "TENTATIVE": "Maybe", "DECLINED": "No"][rawValue]! }
    public init?(google: String) { self.init(rawValue: google == "accepted" ? "ACCEPTED" : google == "tentative" ? "TENTATIVE" : google == "declined" ? "DECLINED" : "") }
}

public struct Conference: Equatable, Sendable {
    public enum Kind: String, Sendable { case meet = "Google Meet", zoom = "Zoom", teams = "Microsoft Teams", webex = "Webex" }
    public let kind: Kind, url: URL
}

public struct Invite: Equatable, Sendable {
    public var method = "REQUEST"            // REQUEST = invitation or update, CANCEL = cancelled
    public var uid = "", summary = "", location = "", details = ""
    public var start: Date?, end: Date?, allDay = false
    public var organizer = "", organizerName = ""
    public var sequence = 0, recurrenceId: String?, rrule: String?
    public var attendees: [(email: String, status: String)] = []
    public var conference: Conference?
    public var isCancelled: Bool { method == "CANCEL" }
    public init() {}
    /// This person's current answer in the invite itself (Google's own copy can be newer).
    public func status(of email: String) -> RSVP? {
        attendees.first { $0.email.lowercased() == email.lowercased() }.flatMap { RSVP(rawValue: $0.status) }
    }
    public static func == (a: Invite, b: Invite) -> Bool { a.uid == b.uid && a.sequence == b.sequence && a.method == b.method && a.start == b.start }
}

/// Lines with their parameters, after undoing the 75-character line folding.
private func icsLines(_ text: String) -> [(name: String, params: [String: String], value: String)] {
    let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
    return unfolded.split(separator: "\n").compactMap { raw in
        let line = String(raw)
        // The value starts at the first colon that isn't inside a quoted parameter.
        var inQuotes = false, split: String.Index?
        for i in line.indices {
            if line[i] == "\"" { inQuotes.toggle() } else if line[i] == ":", !inQuotes { split = i; break }
        }
        guard let split else { return nil }
        let head = line[..<split].split(separator: ";").map(String.init)
        var params: [String: String] = [:]
        for p in head.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (head.first?.uppercased() ?? "", params, String(line[line.index(after: split)...]))
    }
}

private func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
        .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
}

/// DTSTART/DTEND: UTC ("Z"), a named time zone (TZID), floating local time, or an all-day date.
func icsDate(_ value: String, tzid: String?) -> (date: Date, allDay: Bool)? {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    if value.count == 8 {
        f.dateFormat = "yyyyMMdd"; f.timeZone = .current
        return f.date(from: value).map { ($0, true) }
    }
    f.dateFormat = "yyyyMMdd'T'HHmmss"
    if value.hasSuffix("Z") { f.timeZone = TimeZone(identifier: "UTC") }
    // Outlook sometimes sends Windows names ("Pacific Standard Time"); fall back to the Mac's zone for those.
    else { f.timeZone = tzid.flatMap { TimeZone(identifier: $0) ?? windowsZones[$0].flatMap(TimeZone.init(identifier:)) } ?? .current }
    return f.date(from: String(value.prefix(15))).map { ($0, false) }
}

private let windowsZones = ["Pacific Standard Time": "America/Los_Angeles", "Mountain Standard Time": "America/Denver",
                            "Central Standard Time": "America/Chicago", "Eastern Standard Time": "America/New_York",
                            "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin",
                            "Romance Standard Time": "Europe/Paris", "India Standard Time": "Asia/Kolkata",
                            "Tokyo Standard Time": "Asia/Tokyo", "AUS Eastern Standard Time": "Australia/Sydney", "UTC": "UTC"]

/// The video call link, wherever the inviting calendar put it.
public func findConference(in texts: [String]) -> Conference? {
    let patterns: [(Conference.Kind, String)] = [
        (.meet, #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#),
        (.zoom, #"https://[\w.-]*zoom\.us/(j|my|w)/[^\s"<>\\]+"#),
        (.teams, #"https://teams\.(microsoft|live)\.com/(l/meetup-join|meet)/[^\s"<>\\]+"#),
        (.webex, #"https://[\w.-]*webex\.com/[^\s"<>\\]+"#),
    ]
    for (kind, p) in patterns {
        for t in texts {
            if let r = t.range(of: p, options: [.regularExpression, .caseInsensitive]), let u = URL(string: String(t[r])) {
                return Conference(kind: kind, url: u)
            }
        }
    }
    return nil
}

/// The first event in an invite (.ics). Nil for anything that isn't an invitation, update or cancellation.
public func parseInvite(_ ics: String) -> Invite? {
    var inv = Invite(), inEvent = false, seenEvent = false, conferenceHints: [String] = []
    for l in icsLines(ics) {
        switch (l.name, l.value.uppercased()) {
        case ("METHOD", _): inv.method = l.value.uppercased()
        case ("BEGIN", "VEVENT"): if !seenEvent { inEvent = true }
        case ("END", "VEVENT"): if inEvent { inEvent = false; seenEvent = true }
        default:
            guard inEvent else { continue }
            switch l.name {
            case "UID": inv.uid = l.value
            case "SUMMARY": inv.summary = unescape(l.value)
            case "LOCATION": inv.location = unescape(l.value); conferenceHints.append(inv.location)
            case "DESCRIPTION": inv.details = unescape(l.value); conferenceHints.append(inv.details)
            case "X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "URL": conferenceHints.insert(l.value, at: 0)
            case "SEQUENCE": inv.sequence = Int(l.value) ?? 0
            case "RECURRENCE-ID": inv.recurrenceId = l.value
            case "RRULE": inv.rrule = l.value
            case "DTSTART": if let d = icsDate(l.value, tzid: l.params["TZID"]) { inv.start = d.date; inv.allDay = d.allDay }
            case "DTEND": inv.end = icsDate(l.value, tzid: l.params["TZID"])?.date
            case "ORGANIZER":
                inv.organizer = l.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                inv.organizerName = l.params["CN"] ?? ""
            case "ATTENDEE":
                let email = l.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                inv.attendees.append((email, l.params["PARTSTAT"]?.uppercased() ?? "NEEDS-ACTION"))
            default: break
            }
        }
    }
    guard seenEvent, !inv.uid.isEmpty, ["REQUEST", "CANCEL", "PUBLISH"].contains(inv.method) else { return nil }
    if inv.end == nil, let s = inv.start { inv.end = s.addingTimeInterval(inv.allDay ? 86400 : 3600) }
    inv.conference = findConference(in: conferenceHints)
    return inv
}

private func icsEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
        .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
}

/// The iTIP REPLY an organizer's calendar (Google, Outlook/Exchange, iCloud) reads to record your answer.
public func inviteReply(_ inv: Invite, from me: String, name: String = "", answer: RSVP, now: Date = Date()) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let day = DateFormatter(); day.locale = f.locale; day.timeZone = .current; day.dateFormat = "yyyyMMdd"
    func when(_ d: Date?) -> String { guard let d else { return "" }; return inv.allDay ? "VALUE=DATE:" + day.string(from: d) : f.string(from: d) }
    let cn = name.isEmpty ? "" : ";CN=\"\(name.replacingOccurrences(of: "\"", with: ""))\""
    var lines = ["BEGIN:VCALENDAR", "PRODID:-//Keymail//EN", "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:REPLY", "BEGIN:VEVENT",
                 "UID:\(inv.uid)", "SEQUENCE:\(inv.sequence)", "DTSTAMP:\(f.string(from: now))"]
    if let r = inv.recurrenceId { lines.append("RECURRENCE-ID:\(r)") }
    if inv.start != nil { lines.append((inv.allDay ? "DTSTART;" : "DTSTART:") + when(inv.start)) }
    if inv.end != nil { lines.append((inv.allDay ? "DTEND;" : "DTEND:") + when(inv.end)) }
    lines += ["ORGANIZER:mailto:\(inv.organizer)", "ATTENDEE;PARTSTAT=\(answer.rawValue)\(cn):mailto:\(me)",
              "SUMMARY:\(icsEscape(inv.summary))", "END:VEVENT", "END:VCALENDAR"]
    return lines.joined(separator: "\r\n") + "\r\n"
}
