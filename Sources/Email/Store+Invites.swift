import AppKit
import EventKit
import EmailCore

/// Google Calendar API calls for one account (RSVP to invites on that account's own calendar).
struct GoogleCalendar {
    let account: String
    let auth: GoogleAuth
    nonisolated static let scope = "https://www.googleapis.com/auth/calendar.events"

    func call(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/" + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken(for: account))", forHTTPHeaderField: "Authorization")
        if let json { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, resp) = try await GoogleNet.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The account's own copy of the invited event (Google adds invites to the calendar on arrival).
    func event(_ inv: Invite) async throws -> [String: Any]? {
        let items = try await call("events", query: [.init(name: "iCalUID", value: inv.uid), .init(name: "showDeleted", value: "true")])["items"] as? [[String: Any]] ?? []
        guard let rid = inv.recurrenceId else { return items.first { $0["recurringEventId"] == nil } ?? items.first }
        // One occurrence of a series: match its original start time; otherwise don't guess (answering the whole series would be wrong).
        let compact = rid.filter(\.isNumber)
        return items.first { e in
            let o = e["originalStartTime"] as? [String: Any]
            return ((o?["dateTime"] ?? o?["date"]) as? String)?.filter(\.isNumber).hasPrefix(compact.prefix(12)) == true
        }
    }
}

struct NeedsCalendarAccess: LocalizedError {
    var errorDescription: String? { "Keymail needs permission to update your Google Calendar." }
}

extension AppStore {
    // MARK: Calendar invites

    /// The invite in this email, from its text/calendar part or its .ics attachment.
    func invite(in m: Message) async -> Invite? {
        if let ics = m.calendar { return parseInvite(ics) }
        guard let a = m.attachments.first(where: { $0.mimeType == "text/calendar" || $0.name.lowercased().hasSuffix(".ics") }), a.size < 1_000_000,
              let data = try? await fetchAttachment(account: m.account, messageId: m.id, id: a.id) else { return nil }
        return parseInvite(String(decoding: data, as: UTF8.self))
    }

    /// Which of my addresses the invite was sent to (the account or one of its aliases).
    func inviteeAddress(_ inv: Invite, account: String) -> String {
        let mine = Set(([account] + (state.aliases[account] ?? [])).map { $0.lowercased() })
        return inv.attendees.first { mine.contains($0.email.lowercased()) }?.email ?? account
    }

    /// Your current answer: Google's copy for Gmail accounts (it reflects answers given anywhere), else the invite's.
    func currentRSVP(_ inv: Invite, account: String) async -> RSVP? {
        if !isICloud(account), let e = try? await GoogleCalendar(account: account, auth: auth).event(inv),
           let me = (e["attendees"] as? [[String: Any]])?.first(where: { $0["self"] as? Bool == true }) {
            return RSVP(google: me["responseStatus"] as? String ?? "")
        }
        return inv.status(of: inviteeAddress(inv, account: account))
    }

    /// Answers an invite so both your calendar and the organizer's show it. Returns what to tell the person.
    func rsvp(_ inv: Invite, _ answer: RSVP, message m: Message) async throws -> String {
        let acct = m.account, me = inviteeAddress(inv, account: acct)
        if !isICloud(acct) {
            let cal = GoogleCalendar(account: acct, auth: auth)
            do {
                if let e = try await cal.event(inv), let id = e["id"] as? String {
                    // Google updates your calendar and notifies the organizer (Google, Outlook or anyone else) itself.
                    var people = e["attendees"] as? [[String: Any]] ?? []
                    if let i = people.firstIndex(where: { $0["self"] as? Bool == true || ($0["email"] as? String)?.lowercased() == me.lowercased() }) {
                        people[i]["responseStatus"] = answer.google
                    } else { people.append(["email": me, "responseStatus": answer.google]) }
                    _ = try await cal.call("events/\(id)", method: "PATCH", query: [.init(name: "sendUpdates", value: "all")], json: ["attendees": people])
                    return "\(answer.label): \(inv.summary). Your Google Calendar and \(inv.organizerName.isEmpty ? inv.organizer : inv.organizerName) are updated."
                }
                // Not on the calendar yet (invite from outside Google that wasn't auto-added): add it with your answer.
                if answer != .declined, let s = inv.start, let end = inv.end {
                    func when(_ d: Date) -> [String: Any] {
                        inv.allDay ? ["date": ISO8601DateFormatter.string(from: d, timeZone: .current, formatOptions: [.withFullDate])]
                                   : ["dateTime": ISO8601DateFormatter().string(from: d)]
                    }
                    var ev: [String: Any] = ["iCalUID": inv.uid, "summary": inv.summary, "start": when(s), "end": when(end),
                                             "organizer": ["email": inv.organizer],
                                             "attendees": [["email": me, "responseStatus": answer.google]]]
                    if !inv.location.isEmpty { ev["location"] = inv.location }
                    if !inv.details.isEmpty { ev["description"] = inv.details }
                    _ = try await cal.call("events/import", method: "POST", json: ev)
                }
            } catch let e as HTTPError where e.needsMorePermission { throw NeedsCalendarAccess() }
            catch let e as HTTPError where e.status == 403 && (e.body.contains("accessNotConfigured") || e.body.contains("has not been used")) {
                throw AppError("The Google Calendar API is turned off for Keymail's Google Cloud project. Turn it on at console.cloud.google.com/apis/library/calendar-json.googleapis.com, wait a minute, then try again.")
            }
        } else if answer != .declined, let s = inv.start, let end = inv.end, calendar.authorized {
            // iCloud: put it on the Mac's iCloud calendar (falls back to the default calendar).
            let cals = calendar.writableCalendars
            let target = cals.first { $0.source.sourceType == .calDAV && $0.source.title.lowercased().contains("icloud") }
            try? calendar.create(title: inv.summary, start: s, minutes: max(1, Int(end.timeIntervalSince(s) / 60)),
                                 notes: inv.details, location: inv.conference?.url.absoluteString ?? inv.location, calendar: target)
        }
        // The organizer's calendar records the answer from a standard RSVP email.
        var d = Draft(from: me)
        d.to = inv.organizer
        d.subject = "\(["ACCEPTED": "Accepted", "TENTATIVE": "Tentative", "DECLINED": "Declined"][answer.rawValue]!): \(inv.summary)"
        d.body = "\(label(acct)) has \(answer == .accepted ? "accepted" : answer == .declined ? "declined" : "tentatively accepted") this invitation."
        d.calendarReply = inviteReply(inv, from: me, name: state.accountNames[acct] ?? "", answer: answer)
        try await send(d, remindDays: nil)
        return "\(answer.label): \(inv.summary). Sent to \(inv.organizerName.isEmpty ? inv.organizer : inv.organizerName)."
    }

    /// Asks Google for calendar permission on this account (same consent screen as sign-in, account preselected).
    func grantCalendarAccess(for account: String) async -> Bool {
        busy = "Approve calendar access in your browser…"
        defer { busy = nil }
        do {
            let r = try await auth.signIn(hint: account)
            if r.email.lowercased() != account.lowercased() { banner = "You approved \(r.email), not \(account). Try again and pick \(account)."; return false }
            if !r.scopes.contains(GoogleCalendar.scope) {
                banner = "Google didn't include calendar access. On Google's screen, tick \"View and edit events on all your calendars\" (or Select all)."
                return false
            }
            if r.scopes.contains(GoogleAuth.settingsScope) { needsSettingsAccess.remove(account) }
            return true
        } catch { report(error); return false }
    }
}

extension AppStore {
    /// Creates an event on this Gmail account's Google Calendar. Guests get Google's invitation when `invite` is on.
    /// Returns the event's web link.
    func createGoogleEvent(_ d: EventDraft, account: String, guests: [String], invite: Bool, meet: Bool) async throws -> URL? {
        let f = ISO8601DateFormatter()
        let tz = TimeZone.current.identifier
        var ev: [String: Any] = ["summary": d.title,
                                 "start": ["dateTime": f.string(from: d.start), "timeZone": tz],
                                 "end": ["dateTime": f.string(from: d.start.addingTimeInterval(Double(d.minutes) * 60)), "timeZone": tz]]
        if !d.location.isEmpty { ev["location"] = d.location }
        if !d.notes.isEmpty { ev["description"] = d.notes }
        if !guests.isEmpty { ev["attendees"] = guests.map { ["email": $0] } }
        if meet { ev["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]] }
        do {
            let j = try await GoogleCalendar(account: account, auth: auth).call("events", method: "POST", query: [
                .init(name: "conferenceDataVersion", value: "1"), .init(name: "sendUpdates", value: invite && !guests.isEmpty ? "all" : "none")], json: ev)
            return (j["htmlLink"] as? String).flatMap(URL.init(string:))
        } catch let e as HTTPError where e.needsMorePermission { throw NeedsCalendarAccess() }
    }
}
