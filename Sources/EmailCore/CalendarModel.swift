import Foundation

// MARK: Calendar view model (pure logic, so it's testable without EventKit or the network)

/// One event, from any source: the Mac's Calendar app ("mac:<calendar id>") or a Keymail account ("google:<account>").
public struct CalEvent: Identifiable, Equatable, Sendable {
    public var id: String                 // unique within its source
    public var calendarId: String         // which calendar it belongs to (CalSource.id)
    public var title: String
    public var start: Date, end: Date
    public var allDay = false
    public var location = "", notes = ""
    public var link: URL?                 // the event's own page (Google), or whatever link the Mac event carries
    public var call: URL?                 // the video call the source attached (Google Meet, or a provider's own field)
    public var uid = ""                   // iCalendar UID: the same event seen through two sources has the same one
    public var unanswered = false         // an invite you haven't said Yes / Maybe / No to
    public var editable = true
    public var hasGuests = false          // other people are invited (moving it to another account would drop them)
    public init(id: String, calendarId: String, title: String, start: Date, end: Date) {
        self.id = id; self.calendarId = calendarId; self.title = title; self.start = start; self.end = end
    }
    /// The video call to join, found in the event's link, location or notes (Meet, Zoom, Teams, Webex).
    public var conference: Conference? { findConference(in: [call?.absoluteString ?? "", link?.absoluteString ?? "", location, notes]) }
    public var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// A calendar you can show or hide.
public struct CalSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var group: String              // "Gmail · you@gmail.com", "iCloud", …
    public var colorHex: String
    public var writable: Bool
    public init(id: String, title: String, group: String, colorHex: String, writable: Bool) {
        self.id = id; self.title = title; self.group = group; self.colorHex = colorHex; self.writable = writable
    }
}

public enum CalView: String, CaseIterable, Sendable { case day, week, month }

/// The days a view shows around `date`: 1 for day, 7 for week, 42 (six full weeks) for month.
/// `workWeek` drops Saturday and Sunday from the week view (issue #6).
public func calendarDays(_ view: CalView, around date: Date, mondayFirst: Bool, workWeek: Bool = false, calendar: Calendar = .current) -> [Date] {
    var cal = calendar
    cal.firstWeekday = mondayFirst ? 2 : 1
    let day = cal.startOfDay(for: date)
    switch view {
    case .day: return [day]
    case .week:
        let start = cal.dateInterval(of: .weekOfYear, for: day)!.start
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }.filter { !workWeek || !cal.isDateInWeekend($0) }
    case .month:
        let first = cal.dateInterval(of: .month, for: day)!.start
        let start = cal.dateInterval(of: .weekOfYear, for: first)!.start
        return (0..<42).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }
}

/// Moves the focused date one step: a day, a week or a month.
public func stepDate(_ date: Date, _ view: CalView, by n: Int, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: view == .day ? .day : view == .week ? .weekOfYear : .month, value: n, to: date)!
}

/// Side-by-side placement for timed events that overlap on one day: each gets a column and the number of
/// columns in its overlapping group, so nothing is drawn on top of anything else.
public func overlapColumns(_ events: [CalEvent]) -> [String: (col: Int, of: Int)] {
    let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
    var out: [String: (Int, Int)] = [:]
    var group: [CalEvent] = [], colEnds: [Date] = [], groupEnd = Date.distantPast
    func flush() {
        for e in group { out[e.id] = (out[e.id]?.0 ?? 0, colEnds.count) }
        group = []; colEnds = []
    }
    for e in sorted {
        if e.start >= groupEnd { flush() }
        let col = colEnds.firstIndex { $0 <= e.start } ?? colEnds.count
        if col == colEnds.count { colEnds.append(e.end) } else { colEnds[col] = e.end }
        out[e.id] = (col, 0)
        group.append(e)
        groupEnd = max(groupEnd, e.end)
    }
    flush()
    return out
}

/// Drops the second copy of an event seen through two sources (say Google directly and the Mac's Calendar app
/// syncing the same Google account). Same iCalendar UID and same start = same event; the first source wins.
public func dedupeEvents(_ events: [CalEvent]) -> [CalEvent] {
    var seen = Set<String>()
    return events.filter { e in
        guard !e.uid.isEmpty else { return true }
        return seen.insert(e.uid + "|" + String(Int(e.start.timeIntervalSince1970))).inserted
    }
}

/// The Mac's Calendar app often syncs the same Google account Keymail reads directly; its copy of that account's main
/// calendar is named after the address. Those Mac copies are dropped (calendar and events) so each calendar shows once.
public func dropMirroredCalendars(_ sources: [CalSource], _ events: [CalEvent], direct: Set<String>) -> ([CalSource], [CalEvent]) {
    let mirrors = Set(sources.filter { $0.id.hasPrefix("mac:") && direct.contains($0.title.lowercased()) }.map(\.id))
    return (sources.filter { !mirrors.contains($0.id) }, events.filter { !mirrors.contains($0.calendarId) })
}

/// What someone typed into quick add: "Lunch with Priya fri 1pm at Tartine, 45 min".
public struct QuickEvent: Equatable, Sendable {
    public var title: String, start: Date, minutes: Int, location: String
    public init(title: String, start: Date, minutes: Int, location: String) {
        self.title = title; self.start = start; self.minutes = minutes; self.location = location
    }
}

/// Reads a typed event: the date and time (any wording macOS understands), an optional length ("45 min",
/// "2 hours", "for 1h"), an optional place after " at ", and the rest is the title. Nil without a time.
public func parseQuickEvent(_ text: String, now: Date = Date()) -> QuickEvent? {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
    var minutes = 30
    let lengthPattern = #"(?i)[,\s]*(?:for\s+)?(\d+(?:\.\d+)?)\s*(m|min|mins|minutes|h|hr|hrs|hour|hours)\b"#
    if let r = t.range(of: lengthPattern, options: .regularExpression) {
        let m = t[r].range(of: #"(\d+(?:\.\d+)?)\s*([a-zA-Z]+)"#, options: .regularExpression).map { String(t[r][$0]) } ?? ""
        let n = Double(m.prefix { $0.isNumber || $0 == "." }) ?? 0
        minutes = m.lowercased().contains("h") ? Int(n * 60) : Int(n)
        t.removeSubrange(r)
    }
    guard let match = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let start = match.date,
          let dr = Range(match.range, in: t) else { return nil }
    if start < now { return nil }   // already passed: never guess a different day
    if match.duration > 0, minutes == 30 { minutes = Int(match.duration / 60) }
    var rest = t
    rest.removeSubrange(dr)
    var location = ""
    if let at = rest.range(of: #"(?i)\s+(?:at|@)\s+"#, options: .regularExpression) {
        location = String(rest[at.upperBound...])
        rest = String(rest[..<at.lowerBound])
    }
    let clean: (String) -> String = {
        $0.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-").union(.whitespaces))
    }
    let title = clean(rest.replacingOccurrences(of: #"(?i)\s+(on|at)$"#, with: "", options: .regularExpression))
    return QuickEvent(title: title.isEmpty ? "New event" : title, start: start, minutes: max(5, minutes), location: clean(location))
}

/// The next event after `id` in time order (or the first one), for j / k.
public func neighborEvent(_ events: [CalEvent], after id: String?, step: Int) -> CalEvent? {
    let sorted = events.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    guard let id, let i = sorted.firstIndex(where: { $0.id == id }) else { return step > 0 ? sorted.first : sorted.last }
    return sorted[safe: i + step] ?? sorted[i]
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
