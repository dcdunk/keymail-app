import AppKit
import EventKit
import EmailCore

extension AppStore {
    // MARK: Calendar screen (g c)

    var calendarEnabled: Bool { UserDefaults.standard.object(forKey: "calendarEnabled") as? Bool ?? true }
    var calView: CalView {
        get { CalView(rawValue: UserDefaults.standard.string(forKey: "calendarView") ?? "") ?? .week }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "calendarView"); objectWillChange.send(); reloadCalendar() }
    }
    var calMondayFirst: Bool { UserDefaults.standard.object(forKey: "calendarMondayFirst") as? Bool ?? (Calendar.current.firstWeekday == 2) }
    var calHidden: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "calendarHidden") ?? []) }
    var calDays: [Date] { calendarDays(calView, around: calDate, mondayFirst: calMondayFirst, workWeek: UserDefaults.standard.bool(forKey: "calendarWorkWeek")) }
    /// Events on calendars you haven't hidden.
    var calShown: [CalEvent] { let h = calHidden; return calEvents.filter { !h.contains($0.calendarId) } }
    var calSelectedEvent: CalEvent? { calEvents.first { $0.id == calSelected } ?? calUpcoming.first { $0.id == calSelected } }
    func calSource(_ id: String) -> CalSource? { calSources.first { $0.id == id } }

    func openCalendar() {
        toolScreen = nil
        guard calendarEnabled else { return }
        calendarOpen = true
        calSelected = nil
        sidebarFocused = false
        reloadCalendar()
    }
    func closeCalendar() { calendarOpen = false; calSelected = nil; quickAddOpen = false }

    func toggleCalendarHidden(_ id: String) {
        var h = calHidden
        if h.contains(id) { h.remove(id) } else { h.insert(id) }
        UserDefaults.standard.set(Array(h), forKey: "calendarHidden")
        objectWillChange.send()
    }

    func calStep(_ n: Int) { calDate = stepDate(calDate, calView, by: n); calSelected = nil; reloadCalendar() }
    func calToday() { calDate = Date(); calSelected = nil; reloadCalendar() }
    func calShowDay(_ d: Date) { calDate = d; calView = .day }

    func reloadCalendar() { Task { await loadCalendar() } }

    /// Fetches what the view shows plus the next 7 days, from Google (per Gmail account) and the Mac's calendars.
    func loadCalendar() async {
        let days = calDays
        guard let first = days.first, let last = days.last else { return }
        let from = first, to = Calendar.current.date(byAdding: .day, value: 1, to: last)!
        let now = Calendar.current.startOfDay(for: Date()), week = Calendar.current.date(byAdding: .day, value: 8, to: now)!
        let lo = min(from, now), hi = max(to, week)
        calLoadID += 1
        let mine = calLoadID
        let (sources, all) = await fetchEvents(from: lo, to: hi)
        guard mine == calLoadID else { return }   // a newer load (you moved on) already started; its result wins
        calSources = withColors(sources)
        calEvents = all.filter { $0.end > from && $0.start < to }
        let hidden = calHidden
        calUpcoming = all.filter { $0.end > Date() && $0.start < week && !hidden.contains($0.calendarId) }.sorted { $0.start < $1.start }
    }

    /// Every event between two dates from Google (each Gmail account) and the Mac's calendars, with duplicates removed.
    func fetchEvents(from: Date, to: Date) async -> ([CalSource], [CalEvent]) {
        if AppFlavor.isTesting || AppFlavor.isDemo {
            return (demoCalendarSources, demoCalendarEvents.filter { $0.end > from && $0.start < to })
        }
        // Ask for the Mac's calendars the first time you open the calendar, not just because the inbox loaded.
        if calendarOpen, EKEventStore.authorizationStatus(for: .event) == .notDetermined { _ = await calendar.requestAccess() }
        enum Result { case ok(String, [CalSource], [CalEvent]), needsAccess(String), failed }
        let auth = self.auth, microsoft = self.microsoft
        let google = gmailAccounts.enumerated().map { i, a in
            (a, CalSource(id: "google:" + a, title: label(a), group: "Gmail · \(a)", colorHex: Self.calendarPalette[i % Self.calendarPalette.count], writable: true))
        }
        // An Outlook account you haven't approved calendar access for is skipped until you do (Settings → Calendar).
        let outlook = state.accounts.filter { isMicrosoft($0) && !calNeedsAccess.contains($0) }
        // Every account at once, so several accounts cost one round trip instead of one each.
        let results = await withTaskGroup(of: Result.self) { group in
            for (a, src) in google {
                group.addTask {
                    do { return .ok(a, [src], try await GoogleCalendar(account: a, auth: auth).events(from: from, to: to)) }
                    catch let e as HTTPError where e.needsMorePermission { return .needsAccess(a) }
                    catch { return .failed }   // offline or Google down: show what the Mac has
                }
            }
            for a in outlook {
                group.addTask {
                    let o = OutlookCalendar(account: a, auth: microsoft)
                    do {
                        let cals = try await o.calendars()
                        // One calendar you can't read (a shared one, say) only loses that calendar, never the account.
                        let evs = await withTaskGroup(of: [CalEvent].self) { g in
                            for c in cals { g.addTask { (try? await o.events(in: c, from: from, to: to)) ?? [] } }
                            return await g.reduce(into: []) { $0 += $1 }
                        }
                        return .ok(a, cals, evs)
                    } catch is NeedsCalendarAccess { return .needsAccess(a) }
                    catch { return .failed }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        var sources: [CalSource] = [], events: [CalEvent] = []
        // Google first and in a fixed account order, so the same event seen twice keeps the same copy.
        let order = google.map(\.0) + outlook
        for r in results.sorted(by: { a, b in
            func idx(_ r: Result) -> Int { if case .ok(let acct, _, _) = r { return order.firstIndex(of: acct) ?? 0 }; return 0 }
            return idx(a) < idx(b)
        }) {
            switch r {
            case .ok(let a, let s, let e): sources += s; events += e; calNeedsAccess.remove(a)
            case .needsAccess(let a): calNeedsAccess.insert(a)
            case .failed: break
            }
        }
        sources += calendar.sources
        events += calendar.events(from: from, to: to).map(calendar.calEvent)
        let direct = Set(sources.filter { $0.id.hasPrefix("google:") }.map { String($0.id.dropFirst(7)).lowercased() })
        let (kept, keptEvents) = dropMirroredCalendars(sources, events, direct: direct)
        return (kept, dedupeEvents(keptEvents))
    }

    // MARK: Event actions

    func selectEvent(_ id: String?) { calSelected = id; calEditing = nil }

    func joinCall(_ e: CalEvent) {
        guard let c = e.conference else { return }
        if !AppFlavor.isTesting { NSWorkspace.shared.open(c.url) }
        banner = "Opening \(c.kind.rawValue)…"
    }

    func deleteEvent(_ e: CalEvent) {
        guard e.editable else { banner = "\"\(e.title)\" belongs to someone else's calendar, so it can't be deleted here."; return }
        if !AppFlavor.isTesting {
            let alert = NSAlert()
            alert.messageText = "Delete \"\(e.title)\"?"
            alert.informativeText = "It's removed from \(calSource(e.calendarId)?.title ?? "your calendar") everywhere."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        calSelected = nil
        calEvents.removeAll { $0.id == e.id }
        calUpcoming.removeAll { $0.id == e.id }
        if AppFlavor.isTesting || AppFlavor.isDemo { demoCalendarEvents.removeAll { $0.id == e.id }; return }
        Task {
            do {
                try await removeAtSource(e)
                banner = "Deleted \"\(e.title)\"."
            } catch { report(error) }
            await loadCalendar()
        }
    }

    /// "outlook:<account>|<calendar>" → the account.
    func outlookAccount(_ id: String) -> String { String(id.dropFirst(8).split(separator: "|").first ?? "") }

    // MARK: New events

    /// Where new events go: Settings → Calendar, else the first Gmail account's calendar, else the Mac's default.
    var calDefaultDestination: String {
        if let d = UserDefaults.standard.string(forKey: "calendarDefault"), !d.isEmpty { return d }
        if let a = gmailAccounts.first { return "google:" + a }
        return calendar.store.defaultCalendarForNewEvents.map { "mac:" + $0.calendarIdentifier } ?? ""
    }

    func quickAdd(_ text: String) {
        guard let q = parseQuickEvent(text) else { banner = "Add a day or time that's still ahead, like \"Lunch with Sam fri 1pm\"."; return }
        quickAddOpen = false
        createEvent(q, notes: "", link: nil)
    }

    /// Adds an event to the default calendar. `link` remembers the email it came from (shown on the event's card).
    func createEvent(_ q: QuickEvent, notes: String, link conversationId: String?) {
        let dest = calDefaultDestination
        if let conversationId { state.eventLinks[linkKey(title: q.title, start: q.start)] = conversationId }
        if AppFlavor.isTesting || AppFlavor.isDemo {
            var e = CalEvent(id: "demo:\(UUID().uuidString)", calendarId: dest.isEmpty || dest.hasPrefix("google:") ? "demo:work" : dest, title: q.title,
                             start: q.start, end: q.start.addingTimeInterval(Double(q.minutes) * 60))
            e.location = q.location; e.notes = notes
            demoCalendarEvents.append(e)
            calDate = q.start
            Task { await loadCalendar(); calSelected = e.id }
            return
        }
        Task {
            do {
                try await createAt(dest, q, notes: notes)
                banner = "Added \"\(q.title)\", \(q.start.formatted(.dateTime.weekday(.wide).hour().minute()))."
                calDate = q.start
                await loadCalendar()
            } catch is NeedsCalendarAccess {
                banner = "Keymail needs your OK to add to this calendar. Settings → Calendar → Allow calendar access."
            } catch { report(error) }
        }
    }

    // MARK: Calendar colors (Settings → Calendar)

    /// The choices offered in Settings, and the defaults Gmail accounts get in turn (so two accounts never share one).
    static let calendarPalette = ["#4285F4", "#3CC29B", "#F0905F", "#A98BFF", "#EE6AA6", "#E5B93C", "#5BC0DE", "#8E8E93"]
    var calendarColors: [String: String] { UserDefaults.standard.dictionary(forKey: "calendarColors") as? [String: String] ?? [:] }

    func setCalendarColor(_ id: String, _ hex: String) {
        var c = calendarColors; c[id] = hex
        UserDefaults.standard.set(c, forKey: "calendarColors")
        calSources = withColors(calSources)
    }

    /// Your chosen colors win over what each calendar says.
    func withColors(_ sources: [CalSource]) -> [CalSource] {
        let chosen = calendarColors
        return sources.map { var s = $0; if let c = chosen[s.id] { s.colorHex = c }; return s }
    }

    // MARK: Changing an event (calendar, place)

    /// Calendars an event can move to: on the Mac, any calendar in the same account (the Calendar app moves it as is).
    /// Anywhere else it's copied to the new calendar and removed from the old one, which is only safe without guests.
    func moveTargets(_ e: CalEvent) -> [CalSource] {
        guard e.editable else { return [] }
        let mac = calendar.authorized ? calendar.ekEvent(e.id)?.calendar.source.sourceIdentifier : nil
        return calSources.filter { s in
            guard s.writable, s.id != e.calendarId else { return false }
            if AppFlavor.isTesting || AppFlavor.isDemo { return true }
            if e.calendarId.hasPrefix("mac:"), s.id.hasPrefix("mac:"),
               let src = calendar.store.calendar(withIdentifier: String(s.id.dropFirst(4)))?.source.sourceIdentifier, src == mac { return true }
            return !e.hasGuests && !e.allDay   // copy + delete: guests and all-day timing wouldn't survive
        }
    }

    func moveEvent(_ e: CalEvent, to dest: CalSource) {
        guard moveTargets(e).contains(where: { $0.id == dest.id }) else {
            banner = "\"\(e.title)\" has guests, so it can only move to another calendar in the same account."
            return
        }
        func moved() { banner = "Moved \"\(e.title)\" to \(dest.title)." }
        if AppFlavor.isTesting || AppFlavor.isDemo {
            for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id { demoCalendarEvents[i].calendarId = dest.id }
            for i in calEvents.indices where calEvents[i].id == e.id { calEvents[i].calendarId = dest.id }
            moved(); return
        }
        Task {
            do {
                if e.calendarId.hasPrefix("mac:"), dest.id.hasPrefix("mac:"),
                   let target = calendar.store.calendar(withIdentifier: String(dest.id.dropFirst(4))) {
                    try calendar.update(e.id) { $0.calendar = target }
                } else {
                    try await createAt(dest.id, QuickEvent(title: e.title, start: e.start, minutes: e.minutes, location: e.location), notes: e.notes)
                    try await removeAtSource(e)
                }
                moved()
            } catch is NeedsCalendarAccess { banner = "Keymail needs your OK for that calendar. Settings → Calendar → Allow calendar access." }
            catch { report(error) }
            await loadCalendar()
        }
    }

    /// Saves edits made in the event card (title, time, notes) to wherever the event lives.
    func updateEvent(_ e: CalEvent, title: String, start: Date, end: Date, notes: String) {
        let title = title.trimmingCharacters(in: .whitespaces).isEmpty ? e.title : title
        guard e.editable, end > start else { banner = "The end has to be after the start."; return }
        func apply(_ x: inout CalEvent) { x.title = title; x.start = start; x.end = end; x.notes = notes }
        for i in calEvents.indices where calEvents[i].id == e.id { apply(&calEvents[i]) }
        if AppFlavor.isTesting || AppFlavor.isDemo {
            for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id { apply(&demoCalendarEvents[i]) }
            return
        }
        Task {
            do {
                if e.calendarId.hasPrefix("google:") {
                    let acct = String(e.calendarId.dropFirst(7)), gid = String(e.id.split(separator: "|").last ?? "")
                    let f = ISO8601DateFormatter(), tz = TimeZone.current.identifier
                    _ = try await GoogleCalendar(account: acct, auth: auth).call("events/\(gid)", method: "PATCH", query: [.init(name: "sendUpdates", value: "all")], json: [
                        "summary": title, "description": notes,
                        "start": ["dateTime": f.string(from: start), "timeZone": tz], "end": ["dateTime": f.string(from: end), "timeZone": tz]])
                } else if e.calendarId.hasPrefix("outlook:") {
                    try await OutlookCalendar(account: outlookAccount(e.calendarId), auth: microsoft).update(e, title: title, start: start, end: end, notes: notes)
                } else {
                    try calendar.update(e.id) { $0.title = title; $0.startDate = start; $0.endDate = end; $0.notes = notes.isEmpty ? nil : notes }
                }
                banner = "Saved \"\(title)\"."
            } catch let err as HTTPError where err.needsMorePermission { banner = "Keymail needs your OK to change this calendar. Settings → Calendar." }
            catch { report(error) }
            await loadCalendar()
        }
    }

    func setLocation(_ e: CalEvent, _ place: String) {
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.editable, place != e.location else { return }
        for i in calEvents.indices where calEvents[i].id == e.id { calEvents[i].location = place }
        if AppFlavor.isTesting || AppFlavor.isDemo {
            for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id { demoCalendarEvents[i].location = place }
            return
        }
        Task {
            do {
                if e.calendarId.hasPrefix("google:") {
                    let acct = String(e.calendarId.dropFirst(7)), gid = String(e.id.split(separator: "|").last ?? "")
                    _ = try await GoogleCalendar(account: acct, auth: auth).call("events/\(gid)", method: "PATCH", json: ["location": place])
                } else if e.calendarId.hasPrefix("outlook:") {
                    try await OutlookCalendar(account: outlookAccount(e.calendarId), auth: microsoft).setLocation(e, place)
                } else { try calendar.update(e.id) { $0.location = place.isEmpty ? nil : place } }
            } catch let err as HTTPError where err.needsMorePermission { banner = "Keymail needs your OK to change this calendar. Settings → Calendar." }
            catch { report(error) }
            await loadCalendar()
        }
    }

    /// Adds an event to one specific calendar ("google:…", "outlook:…|…" or "mac:…").
    func createAt(_ dest: String, _ q: QuickEvent, notes: String) async throws {
        if dest.hasPrefix("google:") {
            _ = try await createGoogleEvent(EventDraft(title: q.title, start: q.start, minutes: q.minutes, notes: notes, location: q.location),
                                            account: String(dest.dropFirst(7)), guests: [], invite: false, meet: false)
        } else if dest.hasPrefix("outlook:") {
            try await OutlookCalendar(account: outlookAccount(dest), auth: microsoft)
                .create(title: q.title, start: q.start, minutes: q.minutes, location: q.location, calendarId: String(dest.split(separator: "|").last ?? ""))
        } else {
            let cal = calendar.writableCalendars.first { "mac:" + $0.calendarIdentifier == dest }
            try calendar.create(title: q.title, start: q.start, minutes: q.minutes, notes: notes, location: q.location, calendar: cal)
        }
    }

    func removeAtSource(_ e: CalEvent) async throws {
        if e.calendarId.hasPrefix("google:") {
            let acct = String(e.calendarId.dropFirst(7)), gid = String(e.id.split(separator: "|").last ?? "")
            _ = try await GoogleCalendar(account: acct, auth: auth).call("events/\(gid)", method: "DELETE")
        } else if e.calendarId.hasPrefix("outlook:") {
            try await OutlookCalendar(account: outlookAccount(e.calendarId), auth: microsoft).delete(e)
        } else { try calendar.remove(e.id) }
    }

    // MARK: Emails linked to events

    func linkKey(title: String, start: Date) -> String { title + "|" + String(Int(start.timeIntervalSince1970 / 60)) }

    /// The email an event came from: the invite that carries the same UID, or the email you made it from.
    func linkedConversation(_ e: CalEvent) -> Conversation? {
        let id = (e.uid.isEmpty ? nil : state.eventLinks[e.uid] ?? inviteIndex[e.uid]) ?? state.eventLinks[linkKey(title: e.title, start: e.start)]
        guard let id else { return nil }
        return allConversations.first { $0.id == id }
    }

    /// Invite UID → conversation id, rebuilt only when the mail changes (events ask for it on every redraw).
    var inviteIndex: [String: String] {
        let stamp = messages.count
        if let c = inviteIndexCache, c.stamp == stamp { return c.map }
        var map: [String: String] = [:]
        for c in allConversations { for m in c.messages where m.calendar != nil { if let u = m.calendar.flatMap(parseInvite)?.uid { map[u] = c.id } } }
        inviteIndexCache = (stamp, map)
        return map
    }

    func openLinkedEmail(_ e: CalEvent) {
        guard let c = linkedConversation(e) else { return }
        closeCalendar()
        selectedID = c.id
        open(c)
    }

    /// Drag an email onto the Calendar button (or ⌘K "Block time…"): the calendar opens and waits for you to click a time.
    func startPlacing(_ conversationId: String) {
        guard allConversations.contains(where: { $0.id == conversationId }) else { return }
        openCalendar()
        if calView == .month { calView = .week }
        placingEmail = conversationId
    }

    func placeEmail(at start: Date) {
        guard let id = placingEmail, let c = allConversations.first(where: { $0.id == id }) else { placingEmail = nil; return }
        placingEmail = nil
        let title = c.latest.subject.isEmpty ? "Email follow-up" : c.latest.subject
        createEvent(QuickEvent(title: title, start: start, minutes: 30, location: ""), notes: "From email: \(title)", link: c.id)
        banner = "Blocked 30 minutes for \"\(title)\", \(start.formatted(.dateTime.weekday(.wide).hour().minute()))."
    }

    /// Tab in quick add: the full event form, filled in from what was typed.
    func quickAddMore(_ text: String) {
        quickAddOpen = false
        let q = parseQuickEvent(text)
        let nextHour = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        let dest = calDefaultDestination
        eventDraft = EventDraft(title: q?.title ?? text, start: q?.start ?? nextHour, minutes: q?.minutes ?? 30, notes: "",
                                location: q?.location ?? "", account: dest.hasPrefix("google:") ? String(dest.dropFirst(7)) : "")
    }

    // MARK: Keys on the calendar screen

    func handleCalendarKey(code: UInt16, ch: String, shift: Bool) -> Bool {
        if let g = pendingG, Date().timeIntervalSince(g) < 1.5 {
            pendingG = nil
            if let dest = ["i": "Inbox", "s": "Starred", "t": "Sent", "e": "Done", "h": "Reminders", "d": "Drafts"][ch] {
                closeCalendar(); goFolder(dest); return true
            }
            if ch == "c" { return true }
        }
        let e = calSelectedEvent
        if let e, e.unanswered, let r = ["y": RSVP.accepted, "?": .tentative, "n": .declined][ch] { answerEvent(e, r); return true }
        if shift, ch.lowercased() == "j" { if let e { joinCall(e) }; return true }   // other shifted keys (#, ?) carry on below
        switch (code, ch) {
        case (53, _) where placingEmail != nil: placingEmail = nil
        case (53, _) where calEditing != nil: calEditing = nil
        case (53, _): if calSelected != nil { calSelected = nil } else { closeCalendar() }
        case (_, "o") where e.flatMap(linkedConversation) != nil: openLinkedEmail(e!)
        case (125, _), (_, "j"): stepEvent(1)
        case (126, _), (_, "k"): stepEvent(-1)
        case (_, "h"): calStep(-1)
        case (_, "l"): calStep(1)
        case (_, "t"): calToday()
        case (_, "d"): calView = .day
        case (_, "w"): calView = .week
        case (_, "m"): calView = .month
        case (_, "c"): quickAddOpen = true
        case (_, "g"): pendingG = Date()
        case (36, _), (_, "o"): if calSelected == nil { calSelected = neighborEvent(calShown, after: nil, step: 1)?.id }
        case (_, "e"): if let e, e.editable { calEditing = e.id }
        case (_, "#"), (51, _), (117, _): if let e { deleteEvent(e) }
        case (123, _): if !foldersPinned { sidebarOpen.toggle() }
        case (124, _): if !contextPinned { contextOpen.toggle() }
        default: return false
        }
        return true
    }

    /// J / K: the next or previous event; past the last one on screen, the view moves on and picks the first (or last) there.
    func stepEvent(_ step: Int) {
        let next = neighborEvent(calShown, after: calSelected, step: step)
        if let next, next.id != calSelected { calSelected = next.id; return }
        guard calSelected != nil else { return }   // nothing on screen at all: stay put
        calDate = stepDate(calDate, calView, by: step)
        calSelected = nil
        Task {
            await loadCalendar()
            calSelected = neighborEvent(calShown, after: nil, step: step)?.id
        }
    }

    // MARK: Demo and test calendar

    var demoCalendarSources: [CalSource] {
        [CalSource(id: "demo:work", title: "Work", group: "Outlook", colorHex: "#5B8DEF", writable: true),
         CalSource(id: "demo:meet", title: "Meetings", group: "Outlook", colorHex: "#A98BFF", writable: true),
         CalSource(id: "demo:focus", title: "Focus time", group: "Gmail", colorHex: "#3CC29B", writable: true),
         CalSource(id: "demo:personal", title: "Personal", group: "iCloud", colorHex: "#F0905F", writable: true)]
    }
}

/// Sample week for the demo build and the tests, built around today so it's always current.
/// The Monday of the week the calendar shows (with a Sunday-first week, the Monday after this Sunday).
func demoMonday() -> Date {
    let cal = Calendar.current
    let mondayFirst = UserDefaults.standard.object(forKey: "calendarMondayFirst") as? Bool ?? (cal.firstWeekday == 2)
    var c = cal; c.firstWeekday = mondayFirst ? 2 : 1
    return cal.date(byAdding: .day, value: mondayFirst ? 0 : 1, to: c.dateInterval(of: .weekOfYear, for: Date())!.start)!
}

@MainActor var demoCalendarEvents: [CalEvent] = {
    let cal = Calendar.current, monday = demoMonday()
    func at(_ day: Int, _ h: Double, _ len: Double, _ title: String, _ calId: String, notes: String = "", loc: String = "", unanswered: Bool = false) -> CalEvent {
        let s = cal.date(byAdding: .minute, value: Int(h * 60), to: cal.date(byAdding: .day, value: day, to: monday)!)!
        var e = CalEvent(id: "demo:\(title)", calendarId: calId, title: title, start: s, end: s.addingTimeInterval(len * 3600))
        e.notes = notes; e.location = loc; e.unanswered = unanswered
        return e
    }
    return [at(0, 9, 0.5, "Weekly Planning", "demo:work"),
            at(0, 11, 1, "Product Sync", "demo:meet", notes: "https://meet.google.com/xpa-rbuq-kte"),
            at(1, 9.5, 1, "Design Review", "demo:work", notes: "Walk through onboarding v3 flows.", loc: "Room 4B"),
            at(1, 11, 1, "Client Meeting", "demo:meet", notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting"),
            at(2, 10, 1, "Team Standup", "demo:meet", notes: "https://northwind.zoom.us/j/84213377120"),
            at(2, 15, 1.5, "Deep Work", "demo:focus"),
            at(3, 9, 1, "Sprint Planning", "demo:work"),
            at(4, 11, 1, "Project Review", "demo:work", unanswered: true),
            { var e = at(1, 11, 1, "Q4 roadmap review", "demo:meet", notes: "https://northwind.zoom.us/j/90155520417", unanswered: true)
              e.uid = "q4-roadmap@demo.keymail"; return e }(),   // the invite email in the sample inbox
            at(5, 10, 1, "Errands", "demo:personal", loc: "Whole Foods, Venice Blvd"),
            at(5, 16, 1, "Plan Next Week", "demo:personal", notes: "Review priorities, check upcoming deadlines, and block focus time for the week ahead.", loc: "Home office")]
}()
