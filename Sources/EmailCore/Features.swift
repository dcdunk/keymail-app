import Foundation

// MARK: Split Inbox

/// A split is defined by a Gmail-style search: `from:boss@x.com OR subject:invoice`.
public struct Split: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var query: String
    public var alsoInMain = false      // also show in Important/Other
    public var hideWhenEmpty = false
    public var enabled = true
    public init(name: String, query: String, alsoInMain: Bool = false, hideWhenEmpty: Bool = false) {
        self.name = name; self.query = query; self.alsoInMain = alsoInMain; self.hideWhenEmpty = hideWhenEmpty
    }
}

public let importantTab = "Important"
public let otherTab = "Other"
public let inboxTab = "Inbox"   // the single tab when Important/Other is turned off

/// Superhuman's Split Inbox Library, minus the team-collaboration ones.
public let splitLibrary: [Split] = [
    Split(name: "VIP", query: "", alsoInMain: true),
    Split(name: "Team", query: "is:team", alsoInMain: true),
    Split(name: "News", query: ""),
    Split(name: "Calendar", query: "from:calendar-notification@google.com OR from:notifications@calendly.com OR has:ics"),
    Split(name: "Reminders", query: "is:reminder"),
]

public struct QueryContext {
    public var labelNames: [String: String] = [:]
    public var teamDomains: Set<String> = []      // your non-Gmail domains
    public var reminded: Set<String> = []          // conversation ids returned by a reminder
    public var importance: [String: Bool] = [:]   // overrides keyed by conversation id, email or domain
    public init(labelNames: [String: String] = [:], teamDomains: Set<String> = [], reminded: Set<String> = [], importance: [String: Bool] = [:]) {
        self.labelNames = labelNames; self.teamDomains = teamDomains; self.reminded = reminded; self.importance = importance
    }
}

/// Splits on whitespace, keeping "quoted phrases" (and key:"quoted values") together.
func tokenize(_ q: String) -> [String] {
    var out: [String] = [], cur = "", quoted = false
    for ch in q {
        if ch == "\"" { quoted.toggle(); continue }
        if ch.isWhitespace, !quoted { if !cur.isEmpty { out.append(cur) }; cur = ""; continue }
        cur.append(ch)
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

func addressMatches(_ header: String, _ v: String) -> Bool {
    parseAddresses(header).contains { a in
        let e = a.email.lowercased()
        if v.hasPrefix("@") { return e.hasSuffix(v) }
        if v.contains("@") { return e == v }
        if v.contains(".") { return e.hasSuffix("@" + v) || e.hasSuffix("." + v) }
        return e.contains(v) || a.name.lowercased().contains(v)
    }
}

func termMatches(_ term: String, _ m: Message, _ c: Conversation, _ ctx: QueryContext) -> Bool {
    let lower = term.lowercased()
    guard let colon = lower.firstIndex(of: ":") else {
        return m.subject.lowercased().contains(lower) || m.snippet.lowercased().contains(lower)
    }
    let key = String(lower[..<colon]), v = String(lower[lower.index(after: colon)...])
    switch key {
    case "from": return addressMatches(m.from, v)
    case "to": return addressMatches(m.to, v)
    case "cc": return addressMatches(m.cc, v)
    case "bcc": return false // Gmail doesn't return Bcc on received mail
    case "subject": return m.subject.lowercased().contains(v)
    case "label": return m.labelIds.contains { $0.lowercased() == v || ctx.labelNames[$0]?.lowercased() == v }
    case "has":
        if v == "attachment" { return !m.attachments.isEmpty }
        if v == "ics" { return m.attachments.contains { $0.name.lowercased().hasSuffix(".ics") || $0.mimeType == "text/calendar" } }
        return false
    case "is":
        switch v {
        case "unread": return m.labelIds.contains("UNREAD")
        case "starred": return m.labelIds.contains("STARRED")
        case "reminder": return ctx.reminded.contains(c.id)
        case "team":
            return parseAddresses(m.from).contains { a in
                ctx.teamDomains.contains(a.email.lowercased().split(separator: "@").last.map(String.init) ?? "")
            } && !ctx.teamDomains.isEmpty
        default: return false
        }
    default: return false
    }
}

/// `A OR B` matches either group; terms inside a group (space or AND) must all match one message. `-term` negates.
public func matchesQuery(_ query: String, _ c: Conversation, _ ctx: QueryContext = QueryContext()) -> Bool {
    var groups: [[String]] = [[]]
    for t in tokenize(query) {
        if t == "OR" { groups.append([]) } else if t != "AND" { groups[groups.count - 1].append(t) }
    }
    return groups.contains { terms in
        !terms.isEmpty && c.messages.contains { m in
            terms.allSatisfy { t in t.hasPrefix("-") ? !termMatches(String(t.dropFirst()), m, c, ctx) : termMatches(t, m, c, ctx) }
        }
    }
}

public func addTerm(_ term: String, to query: String) -> String {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty ? term : q + " OR " + term
}

public func isImportant(_ c: Conversation, _ ctx: QueryContext) -> Bool {
    if let o = ctx.importance[c.id] { return o }
    if let a = parseAddresses(c.messages.first?.from ?? "").first {
        let e = a.email.lowercased()
        if let o = ctx.importance[e] { return o }
        if let d = e.split(separator: "@").last, let o = ctx.importance[String(d)] { return o }
    }
    return c.labels.contains("IMPORTANT")
}

/// Every tab a conversation shows in. Splits can claim it, or share it with Important/Other.
public func tabs(for c: Conversation, splits: [Split], ctx: QueryContext, splitImportance: Bool = true) -> [String] {
    var out: [String] = [], main = true
    for s in splits where s.enabled && matchesQuery(s.query, c, ctx) {
        out.append(s.name)
        if !s.alsoInMain { main = false }
    }
    if main { out.append(!splitImportance ? inboxTab : isImportant(c, ctx) ? importantTab : otherTab) }
    return out
}

// MARK: Snooze, send later, follow-ups

/// A Superhuman-style reminder: hides the thread, returns it at `until`.
/// With `ifNoReply`, it's cancelled if someone replies after `setAt`.
public struct Snooze: Codable, Hashable {
    public var account: String, threadId: String, until: Date, setAt: Date, ifNoReply: Bool
    public init(account: String, threadId: String, until: Date, setAt: Date = Date(), ifNoReply: Bool) {
        self.account = account; self.threadId = threadId; self.until = until; self.setAt = setAt; self.ifNoReply = ifNoReply
    }
    public var conversationId: String { account + "|" + threadId }
}

public struct ScheduledSend: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var draft: Draft
    public var at: Date
    public var remindDays: Int?
    public init(draft: Draft, at: Date, remindDays: Int?) { self.draft = draft; self.at = at; self.remindDays = remindDays }
}

public struct FollowUp: Codable, Hashable {
    public var account: String, threadId: String, sentAt: Date, due: Date
    public init(account: String, threadId: String, sentAt: Date, due: Date) {
        self.account = account; self.threadId = threadId; self.sentAt = sentAt; self.due = due
    }
}

/// Superhuman-style presets. All land at 8am except "Later today".
public func snoozePresets(now: Date = Date(), calendar cal: Calendar = .current) -> [(String, Date)] {
    func at8(_ d: Date) -> Date { cal.date(bySettingHour: 8, minute: 0, second: 0, of: d)! }
    let tomorrow = at8(cal.date(byAdding: .day, value: 1, to: now)!)
    let saturday = at8(cal.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!)
    let monday = at8(cal.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!)
    return [("Later today", now.addingTimeInterval(3 * 3600)), ("Tomorrow", tomorrow), ("This weekend", saturday), ("Next week", monday)]
}

/// Reads a typed time like "friday 3pm" or "in 2 hours". Only future times count.
public func parseWhen(_ text: String, now: Date = Date()) -> Date? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
    let date = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))?.date
    return date.flatMap { $0 > now ? $0 : nil }
}

/// True if someone other than me wrote in the thread after `after`.
public func gotReply(_ messages: [Message], me: String, after: Date) -> Bool {
    messages.contains { m in
        m.date > after && !parseAddresses(m.from).contains { $0.email.lowercased() == me.lowercased() }
    }
}

// MARK: Snippets

public struct Snippet: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var body: String
    public init(name: String, body: String) { self.name = name; self.body = body }
}

/// Replaces {first_name}, {name}, {email} with the first recipient's details.
public func expand(_ body: String, recipient: Address?) -> String {
    body.replacingOccurrences(of: "{first_name}", with: recipient?.firstName ?? "")
        .replacingOccurrences(of: "{name}", with: recipient?.name ?? "")
        .replacingOccurrences(of: "{email}", with: recipient?.email ?? "")
}

// MARK: Unsubscribe

public enum UnsubscribeAction: Equatable { case oneClick(URL), open(URL), none }

/// RFC 8058: one-click POST when List-Unsubscribe-Post is present, else open the link or mailto.
public func unsubscribeAction(header: String, oneClickPost: Bool) -> UnsubscribeAction {
    let urls = header.components(separatedBy: ",").compactMap { part -> URL? in
        URL(string: part.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t\r\n")))
    }
    if let https = urls.first(where: { $0.scheme == "https" }) { return oneClickPost ? .oneClick(https) : .open(https) }
    if let mail = urls.first(where: { $0.scheme == "mailto" }) { return .open(mail) }
    return .none
}

// MARK: Notifications

/// Mail that just arrived and deserves a notification: new since the last sync, in the inbox, unread,
/// not from you, not in a muted thread (muted holds conversation ids, "account|threadId"), and recent (so mail synced after a long time offline doesn't flood you).
public func freshArrivals(_ messages: [Message], knownKeys: Set<String>, me: Set<String>, muted: Set<String>,
                          now: Date = Date(), maxAge: TimeInterval = 3600) -> [Message] {
    messages.filter { m in
        !knownKeys.contains(m.key) && m.labelIds.contains("INBOX") && m.labelIds.contains("UNREAD")
            && !muted.contains(m.account + "|" + m.threadId) && now.timeIntervalSince(m.date) < maxAge
            // Skip only your own copy of what you sent: Gmail marks it SENT, and mail from an inbox's own address is
            // the same thing. Mail from your other accounts still notifies (Gmail → Work is a real arrival).
            && !m.labelIds.contains("SENT")
            && !parseAddresses(m.from).contains { $0.email.lowercased() == m.account.lowercased() }
    }
    .sorted { $0.date < $1.date }
}

// MARK: Cache size

/// Which cached messages to keep, so the cache can't grow forever. Kept: every message in a thread you still
/// need (`keepThreads`: inbox, snoozed, follow-ups, all as "account|threadId"), plus each account's newest
/// `maxPerAccount` messages from the last `maxAge`. Everything else is still in Gmail/iCloud and comes back when needed.
public func cacheKeys(_ messages: [Message], keepThreads: Set<String>, now: Date = Date(),
                      maxAge: TimeInterval = 90 * 86400, maxPerAccount: Int = 5000) -> Set<String> {
    var keep = Set<String>()
    for (_, msgs) in Dictionary(grouping: messages, by: \.account) {
        for (i, m) in msgs.sorted(by: { $0.date > $1.date }).enumerated() {
            if keepThreads.contains(m.account + "|" + m.threadId) || (i < maxPerAccount && now.timeIntervalSince(m.date) < maxAge) {
                keep.insert(m.key)
            }
        }
    }
    return keep
}
