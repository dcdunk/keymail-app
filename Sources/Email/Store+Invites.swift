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

    /// This account's events between two dates, repeating events expanded into their occurrences.
    func events(from start: Date, to end: Date) async throws -> [CalEvent] {
        let f = ISO8601DateFormatter()
        var out: [CalEvent] = [], page: String?
        repeat {
            var q: [URLQueryItem] = [.init(name: "timeMin", value: f.string(from: start)), .init(name: "timeMax", value: f.string(from: end)),
                                     .init(name: "singleEvents", value: "true"), .init(name: "maxResults", value: "250")]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            let j = try await call("events", query: q)
            out += (j["items"] as? [[String: Any]] ?? []).compactMap(Self.parse(account: account))
            page = j["nextPageToken"] as? String
        } while page != nil && out.count < 2000
        return out
    }

    static func parse(account: String) -> ([String: Any]) -> CalEvent? {
        { e in
            guard e["status"] as? String != "cancelled", let id = e["id"] as? String,
                  let s = e["start"] as? [String: Any], let en = e["end"] as? [String: Any] else { return nil }
            func date(_ d: [String: Any]) -> Date? {
                if let t = d["dateTime"] as? String { return ISO8601DateFormatter().date(from: t) }
                guard let day = d["date"] as? String else { return nil }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
                return f.date(from: day)
            }
            guard let start = date(s), let end = date(en) else { return nil }
            var c = CalEvent(id: "google:\(account)|\(id)", calendarId: "google:" + account,
                             title: (e["summary"] as? String) ?? "Busy", start: start, end: end)
            c.allDay = s["date"] != nil
            c.location = e["location"] as? String ?? ""
            c.notes = e["description"] as? String ?? ""
            let video = ((e["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]])?
                .first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
            c.call = (video ?? e["hangoutLink"] as? String).flatMap(URL.init(string:))
            c.link = (e["htmlLink"] as? String).flatMap(URL.init(string:))
            c.uid = e["iCalUID"] as? String ?? ""
            let me = (e["attendees"] as? [[String: Any]])?.first { $0["self"] as? Bool == true }
            c.unanswered = me?["responseStatus"] as? String == "needsAction"
            c.hasGuests = ((e["attendees"] as? [[String: Any]]) ?? []).contains { $0["self"] as? Bool != true }
            c.editable = me == nil || (e["organizer"] as? [String: Any])?["self"] as? Bool == true || e["guestsCanModify"] as? Bool == true
            return c
        }
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
        if isGmail(account), let e = try? await GoogleCalendar(account: account, auth: auth).event(inv),
           let me = (e["attendees"] as? [[String: Any]])?.first(where: { $0["self"] as? Bool == true }) {
            return RSVP(google: me["responseStatus"] as? String ?? "")
        }
        return inv.status(of: inviteeAddress(inv, account: account))
    }

    /// Answers an invite so both your calendar and the organizer's show it. Returns what to tell the person.
    func rsvp(_ inv: Invite, _ answer: RSVP, message m: Message) async throws -> String {
        let acct = m.account, me = inviteeAddress(inv, account: acct)
        if !organizerIsSender(inv, m) {
            let alert = NSAlert()
            alert.messageText = "Send your answer to \(inv.organizer)?"
            alert.informativeText = m.authFailed == true
                ? "This email failed its sender check (it may be forged), so Keymail won't answer it without asking."
                : "The invite names \(inv.organizer) as the organizer, but the email came from \(m.from). Only send if you trust it."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { throw AppError("Cancelled. No answer was sent.") }
        }
        if isGmail(acct) {
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
        } else if isMicrosoft(acct), (try? await OutlookCalendar(account: acct, auth: microsoft).respond(uid: inv.uid, answer)) == true {
            // Outlook answered on its own calendar and told the organizer, the same as Gmail above.
            return "\(answer.label): \(inv.summary). Your Outlook calendar and \(inv.organizerName.isEmpty ? inv.organizer : inv.organizerName) are updated."
        } else if !isMicrosoft(acct), let s = inv.start, let end = inv.end, calendar.authorized {
            // iCloud: the Mac's iCloud calendar (falls back to the default calendar). One copy whatever you answer:
            // changing Yes to Maybe used to add a second event, and No left the first one in place.
            let existing = calendar.matching(title: inv.summary, start: s)
            if answer == .declined {
                for e in existing { try? calendar.remove(e) }
            } else if existing.isEmpty {
                let target = calendar.writableCalendars.first { $0.source.sourceType == .calDAV && $0.source.title.lowercased().contains("icloud") }
                do {
                    try calendar.create(title: inv.summary, start: s, minutes: max(1, Int(end.timeIntervalSince(s) / 60)),
                                        notes: inv.details, location: inv.conference?.url.absoluteString ?? inv.location, calendar: target)
                } catch { banner = "Your answer was sent, but Keymail couldn't add the event to your calendar: \(error.localizedDescription)" }
            }
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
        if isMicrosoft(account) {
            do {
                let email = try await microsoft.signIn(hint: account, scopes: MicrosoftAuth.calendarScopes)
                if email.lowercased() != account.lowercased() { banner = "You approved \(email), not \(account). Try again and pick \(account)."; return false }
                calNeedsAccess.remove(account)
                return true
            } catch { report(error); return false }
        }
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

extension AppStore {
    // MARK: Answering invites (the invite card, Y / ? / N, and the calendar's event card)

    /// True when you organized it: there's nothing to answer.
    func isMine(_ inv: Invite) -> Bool { Set(fromAddresses.map { $0.lowercased() }).contains(inv.organizer.lowercased()) }

    /// Remembers the invite in the email you're reading, and loads the rest of your day for the "Your Tuesday" strip.
    func loadInviteDay(_ inv: Invite, message m: Message) async {
        openInvite = (m, inv)
        guard let s = inv.start, !inv.isCancelled, UserDefaults.standard.object(forKey: "inviteDayStrip") as? Bool ?? true else { inviteDay = nil; return }
        let day = Calendar.current.startOfDay(for: s)
        let (sources, events) = await fetchEvents(from: day, to: Calendar.current.date(byAdding: .day, value: 1, to: day)!)
        if calSources.isEmpty { calSources = withColors(sources) }   // colors for the strip
        inviteDay = InviteDay(uid: inv.uid, day: day, events: events.filter { $0.uid != inv.uid && !$0.allDay }.sorted { $0.start < $1.start })
    }

    /// Y / ? / N while reading an invite. False when there's nothing here to answer, so the key does its usual job.
    func answerOpenInvite(_ r: RSVP) -> Bool {
        guard let (m, inv) = openInvite, let c = selected, c.messages.contains(where: { $0.key == m.key }),
              !inv.isCancelled, !isMine(inv) else { return false }
        respondToInvite(inv, r, message: m)
        return true
    }

    func respondToInvite(_ inv: Invite, _ r: RSVP, message m: Message) {
        guard inviteSending == nil else { return }
        inviteSending = inv.uid
        Task {
            defer { inviteSending = nil }
            if AppFlavor.isTesting || AppFlavor.isDemo { inviteAnswers[inv.uid] = r; banner = "\(r.label): \(inv.summary)."; return }
            do {
                banner = try await rsvp(inv, r, message: m)
                inviteAnswers[inv.uid] = r
                if calendarOpen { await loadCalendar() }
            } catch is NeedsCalendarAccess { calNeedsAccess.insert(m.account) }
            catch { report(error) }
        }
    }

    /// Yes / Maybe / No on an unanswered event in the calendar (Google calendars; the Mac's Calendar app doesn't allow it).
    func answerEvent(_ e: CalEvent, _ r: RSVP) {
        guard e.unanswered else { return }
        func done() {
            for i in calEvents.indices where calEvents[i].id == e.id { calEvents[i].unanswered = false }
            for i in calUpcoming.indices where calUpcoming[i].id == e.id { calUpcoming[i].unanswered = false }
        }
        if AppFlavor.isTesting || AppFlavor.isDemo {
            for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id { demoCalendarEvents[i].unanswered = false }
            done(); banner = "\(r.label): \(e.title)."; return
        }
        if e.calendarId.hasPrefix("outlook:") {
            let acct = outlookAccount(e.calendarId)
            Task {
                do { try await OutlookCalendar(account: acct, auth: microsoft).answer(e, r); done(); banner = "\(r.label): \(e.title). The organizer is told." }
                catch is NeedsCalendarAccess { calNeedsAccess.insert(acct) }
                catch { report(error) }
            }
            return
        }
        guard e.calendarId.hasPrefix("google:") else { banner = "Answer this one in the Calendar app, or from the invite email."; return }
        let acct = String(e.calendarId.dropFirst(7)), gid = String(e.id.split(separator: "|").last ?? "")
        Task {
            do {
                let cal = GoogleCalendar(account: acct, auth: auth)
                var people = try await cal.call("events/\(gid)")["attendees"] as? [[String: Any]] ?? []
                guard let i = people.firstIndex(where: { $0["self"] as? Bool == true }) else { return }
                people[i]["responseStatus"] = r.google
                _ = try await cal.call("events/\(gid)", method: "PATCH", query: [.init(name: "sendUpdates", value: "all")], json: ["attendees": people])
                done(); banner = "\(r.label): \(e.title). The organizer is told."
            } catch let err as HTTPError where err.needsMorePermission { calNeedsAccess.insert(acct) }
            catch { report(error) }
        }
    }
}
