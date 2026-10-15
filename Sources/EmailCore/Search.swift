import Foundation

// MARK: Search

public struct SearchQuery: Equatable {
    public var words = "", from = "", to = "", subject = ""
    public var after: Date?, before: Date?
    public var hasAttachment = false, unreadOnly = false
    public init() {}
    public var isEmpty: Bool {
        [words, from, to, subject].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && after == nil && before == nil && !hasAttachment && !unreadOnly
    }

    /// Short labels for the active filters, shown as chips.
    public var chips: [String] {
        var out: [String] = []
        let f = DateFormatter(); f.dateStyle = .medium
        if !from.isEmpty { out.append("From: \(from)") }
        if !to.isEmpty { out.append("To: \(to)") }
        if !subject.isEmpty { out.append("Subject: \(subject)") }
        if let a = after { out.append("After \(f.string(from: a))") }
        if let b = before { out.append("Before \(f.string(from: b))") }
        if hasAttachment { out.append("Has attachment") }
        if unreadOnly { out.append("Unread") }
        if !words.isEmpty { out.append("“\(words)”") }
        return out
    }
}

/// Gmail search syntax for a query. Free text in `words` passes through, so typed operators still work.
public func gmailQuery(_ q: SearchQuery, calendar: Calendar = .current) -> String {
    func quote(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }
    let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy/MM/dd"
    var parts: [String] = []
    let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
    if !t(q.from).isEmpty { parts.append("from:" + quote(t(q.from))) }
    if !t(q.to).isEmpty { parts.append("to:" + quote(t(q.to))) }
    if !t(q.subject).isEmpty { parts.append("subject:(\(t(q.subject)))") }
    if let a = q.after { parts.append("after:" + f.string(from: a)) }
    // Gmail's before: excludes that day, so ask for the day after to include it.
    if let b = q.before { parts.append("before:" + f.string(from: calendar.date(byAdding: .day, value: 1, to: b)!)) }
    if q.hasAttachment { parts.append("has:attachment") }
    if q.unreadOnly { parts.append("is:unread") }
    if !t(q.words).isEmpty { parts.append(t(q.words)) }
    return parts.joined(separator: " ")
}

/// Local search for providers without server search (iCloud's cached mail).
public func matchesSearch(_ m: Message, _ q: SearchQuery, calendar: Calendar = .current) -> Bool {
    func has(_ hay: String, _ needle: String) -> Bool {
        let n = needle.lowercased().trimmingCharacters(in: .whitespaces)
        return n.isEmpty || hay.lowercased().contains(n)
    }
    guard has(m.from, q.from), has(m.to + " " + m.cc, q.to), has(m.subject, q.subject) else { return false }
    if let a = q.after, m.date < calendar.startOfDay(for: a) { return false }
    if let b = q.before, m.date >= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: b))! { return false }
    if q.hasAttachment, !m.attachments.contains(where: { !$0.isInline }) { return false }
    if q.unreadOnly, !m.labelIds.contains("UNREAD") { return false }
    let hay = (m.subject + " " + m.from + " " + m.plainText).lowercased()
    return q.words.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
}

// MARK: Search suggestions (type-ahead tokens)

public enum SearchSuggestion: Equatable {
    case person(Address, to: Bool)
    case subject(String)
    case dateRange(String, after: Date?, before: Date?)
    case hasAttachment, unread
    case words(String)
}

/// Date phrases people type: today, yesterday, this/last week|month|year, or a specific date ("march 3").
public func parseDateRange(_ text: String, now: Date = Date(), calendar cal: Calendar = .current) -> (label: String, after: Date?, before: Date?)? {
    let t = text.lowercased().trimmingCharacters(in: .whitespaces)
    guard t.count >= 3 else { return nil }
    let today = cal.startOfDay(for: now)
    func start(_ c: Calendar.Component, offset: Int) -> Date {
        let s = cal.dateInterval(of: c, for: now)!.start
        return cal.date(byAdding: c, value: offset, to: s)!
    }
    let fixed: [(String, Date?, Date?)] = [
        ("today", today, today),
        ("yesterday", cal.date(byAdding: .day, value: -1, to: today), cal.date(byAdding: .day, value: -1, to: today)),
        ("this week", start(.weekOfYear, offset: 0), nil),
        ("last week", start(.weekOfYear, offset: -1), cal.date(byAdding: .day, value: -1, to: start(.weekOfYear, offset: 0))),
        ("this month", start(.month, offset: 0), nil),
        ("last month", start(.month, offset: -1), cal.date(byAdding: .day, value: -1, to: start(.month, offset: 0))),
        ("this year", start(.year, offset: 0), nil),
        ("last year", start(.year, offset: -1), cal.date(byAdding: .day, value: -1, to: start(.year, offset: 0))),
    ]
    if let hit = fixed.first(where: { $0.0.hasPrefix(t) }) { return (hit.0.capitalized, hit.1, hit.2) }
    // A specific day like "march 3" or "10/12" (past or future).
    guard t.rangeOfCharacter(from: .decimalDigits) != nil || cal.monthSymbols.contains(where: { $0.lowercased().hasPrefix(t) }),
          let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
          let d = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date else { return nil }
    var day = cal.startOfDay(for: d)
    if day > today, let lastYear = cal.date(byAdding: .year, value: -1, to: day) { day = lastYear } // "march 3" means the past one
    let f = DateFormatter(); f.dateStyle = .medium
    return (f.string(from: day), day, day)
}

/// What the search bar offers for the text being typed, given the tokens already locked in.
public func searchSuggestions(_ text: String, current q: SearchQuery, messages: [Message], me: Set<String>,
                              now: Date = Date(), calendar: Calendar = .current) -> [SearchSuggestion] {
    var t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return [] }
    var onlyPeople: Bool? = nil // nil = anything; false = from; true = to
    if t.lowercased().hasPrefix("from:") { onlyPeople = false; t = String(t.dropFirst(5)) }
    else if t.lowercased().hasPrefix("to:") { onlyPeople = true; t = String(t.dropFirst(3)) }
    t = t.trimmingCharacters(in: .whitespaces)
    var out: [SearchSuggestion] = []
    // People first: once From is locked, offer them as To instead.
    if t.count >= 2 || onlyPeople != nil {
        let toField = onlyPeople ?? !q.from.isEmpty
        if !(toField ? !q.to.isEmpty : !q.from.isEmpty) {
            out += contactSuggestions(t.isEmpty ? "@" : t, messages: messages, me: me, limit: 4).map { .person($0, to: toField) }
        }
    }
    if onlyPeople != nil { return out }
    if q.after == nil && q.before == nil, let d = parseDateRange(t, now: now, calendar: calendar) {
        out.append(.dateRange(d.label, after: d.after, before: d.before))
    }
    let l = t.lowercased()
    if !q.hasAttachment, l.count >= 3, "has attachment".contains(l) || "attachments".hasPrefix(l) || "files".hasPrefix(l) { out.append(.hasAttachment) }
    if !q.unreadOnly, l.count >= 3, "unread".hasPrefix(l) { out.append(.unread) }
    if q.subject.isEmpty, t.count >= 3 {
        var seen = Set<String>()
        for m in messages.sorted(by: { $0.date > $1.date }) where m.subject.lowercased().contains(l) && (q.from.isEmpty || matchesSearch(m, q)) {
            let s = m.subject.trimmingCharacters(in: .whitespaces)
            if seen.insert(s.lowercased()).inserted { out.append(.subject(s)) }
            if seen.count == 3 { break }
        }
    }
    out.append(.words(t))
    return out
}

/// Locks a suggestion into the query. Returns the updated query.
public func apply(_ s: SearchSuggestion, to q: SearchQuery) -> SearchQuery {
    var q = q
    switch s {
    case .person(let a, let to): if to { q.to = a.email } else { q.from = a.email }
    case .subject(let subject): q.subject = subject
    case .dateRange(_, let after, let before): q.after = after; q.before = before
    case .hasAttachment: q.hasAttachment = true
    case .unread: q.unreadOnly = true
    case .words(let w): q.words = [q.words, w].filter { !$0.isEmpty }.joined(separator: " ")
    }
    return q
}
