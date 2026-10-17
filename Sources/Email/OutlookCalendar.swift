import Foundation
import EmailCore

/// Microsoft Graph calendar for one Outlook / Microsoft 365 account. Uses the separately approved calendar scope.
/// Event ids are "outlook:<account>|<event id>"; calendar ids are "outlook:<account>|<calendar id>".
struct OutlookCalendar {
    let account: String
    let auth: MicrosoftAuth
    var graph: GraphMail { GraphMail(account: account, auth: auth, scopes: MicrosoftAuth.calendarScopes) }

    func calendars() async throws -> [CalSource] {
        let list = try await graph.call("/calendars?$select=id,name,hexColor,canEdit,isDefaultCalendar&$top=50")["value"] as? [[String: Any]] ?? []
        return list.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let hex = (c["hexColor"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "#0F6CBD"
            return CalSource(id: "outlook:\(account)|\(id)", title: c["name"] as? String ?? "Calendar",
                             group: "Outlook · \(account)", colorHex: hex, writable: c["canEdit"] as? Bool ?? false)
        }
    }

    func events(in cal: CalSource, from: Date, to: Date) async throws -> [CalEvent] {
        let calId = String(cal.id.split(separator: "|").last ?? "")
        let f = ISO8601DateFormatter()
        var url: String? = "/calendars/\(calId)/calendarView?startDateTime=\(f.string(from: from))&endDateTime=\(f.string(from: to))"
            + "&$top=200&$select=id,subject,start,end,isAllDay,location,bodyPreview,onlineMeeting,webLink,iCalUId,responseStatus,isOrganizer,isCancelled,attendees"
        var out: [CalEvent] = []
        while let u = url, out.count < 2000 {
            let j = try await graph.call(u)
            out += (j["value"] as? [[String: Any]] ?? []).compactMap { parse($0, calendar: cal) }
            url = j["@odata.nextLink"] as? String
        }
        return out
    }

    /// Graph gives times as UTC strings without a zone marker when no time zone preference is sent.
    static func date(_ d: [String: Any]?) -> Date? {
        guard let s = d?["dateTime"] as? String else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: d?["timeZone"] as? String ?? "UTC") ?? TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let x = f.date(from: s) { return x }
        }
        return nil
    }

    func parse(_ e: [String: Any], calendar cal: CalSource) -> CalEvent? {
        guard e["isCancelled"] as? Bool != true, let id = e["id"] as? String,
              let start = Self.date(e["start"] as? [String: Any]), let end = Self.date(e["end"] as? [String: Any]) else { return nil }
        var c = CalEvent(id: "outlook:\(account)|\(id)", calendarId: cal.id, title: e["subject"] as? String ?? "Busy", start: start, end: end)
        c.allDay = e["isAllDay"] as? Bool ?? false
        if c.allDay {   // all-day events come as UTC midnights; show them on the local day
            let utc = TimeZone(identifier: "UTC")!, local = TimeZone.current
            c.start = start.addingTimeInterval(TimeInterval(utc.secondsFromGMT(for: start) - local.secondsFromGMT(for: start)))
            c.end = end.addingTimeInterval(TimeInterval(utc.secondsFromGMT(for: end) - local.secondsFromGMT(for: end)))
        }
        c.location = (e["location"] as? [String: Any])?["displayName"] as? String ?? ""
        c.notes = e["bodyPreview"] as? String ?? ""
        c.call = ((e["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String).flatMap(URL.init(string:))
        c.link = (e["webLink"] as? String).flatMap(URL.init(string:))
        c.uid = e["iCalUId"] as? String ?? ""
        let response = (e["responseStatus"] as? [String: Any])?["response"] as? String ?? ""
        c.unanswered = e["isOrganizer"] as? Bool != true && (response == "notResponded" || response == "none")
        c.editable = cal.writable && (e["isOrganizer"] as? Bool ?? true)
        c.hasGuests = !((e["attendees"] as? [[String: Any]]) ?? []).isEmpty
        return c
    }

    static func eventId(_ e: CalEvent) -> String { String(e.id.split(separator: "|").last ?? "") }

    func delete(_ e: CalEvent) async throws { try await graph.call("/events/\(Self.eventId(e))", method: "DELETE") }

    func answer(_ e: CalEvent, _ r: RSVP) async throws {
        let verb = ["ACCEPTED": "accept", "TENTATIVE": "tentativelyAccept", "DECLINED": "decline"][r.rawValue]!
        try await graph.call("/events/\(Self.eventId(e))/\(verb)", method: "POST", json: ["sendResponse": true])
    }

    func update(_ e: CalEvent, title: String, start: Date, end: Date, notes: String) async throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
        try await graph.call("/events/\(Self.eventId(e))", method: "PATCH", json: [
            "subject": title, "body": ["contentType": "text", "content": notes],
            "start": ["dateTime": f.string(from: start), "timeZone": "UTC"], "end": ["dateTime": f.string(from: end), "timeZone": "UTC"]])
    }

    func setLocation(_ e: CalEvent, _ place: String) async throws {
        try await graph.call("/events/\(Self.eventId(e))", method: "PATCH", json: ["location": ["displayName": place]])
    }

    func create(title: String, start: Date, minutes: Int, location: String, calendarId: String) async throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
        var ev: [String: Any] = ["subject": title,
                                 "start": ["dateTime": f.string(from: start), "timeZone": "UTC"],
                                 "end": ["dateTime": f.string(from: start.addingTimeInterval(Double(minutes) * 60)), "timeZone": "UTC"]]
        if !location.isEmpty { ev["location"] = ["displayName": location] }
        let path = calendarId.isEmpty ? "/events" : "/calendars/\(calendarId)/events"
        try await graph.call(path, method: "POST", json: ev)
    }
}
