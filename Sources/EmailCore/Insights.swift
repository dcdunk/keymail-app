import Foundation

// MARK: Clean up senders, Insights and "needs a reply"

/// Everything one sender sent you in the period, for Clean up.
public struct SenderStat: Identifiable, Hashable {
    public var email: String          // lowercased
    public var name: String
    public var count: Int
    public var read: Int
    public var canUnsubscribe: Bool   // at least one email carries a List-Unsubscribe header
    public var isNewsletter: Bool
    public var id: String { email }
    public var neverRead: Bool { read == 0 }
}

/// Senders of mail you received since `since`, most mail first. Your own addresses are left out.
public func senderStats(_ messages: [Message], me: Set<String>, since: Date) -> [SenderStat] {
    var out: [String: SenderStat] = [:]
    for m in messages where m.date >= since && !m.labelIds.contains("SENT") {
        guard let a = parseAddresses(m.from).first else { continue }
        let e = a.email.lowercased()
        if e.isEmpty || me.contains(e) { continue }
        var s = out[e] ?? SenderStat(email: e, name: a.name.isEmpty ? e : a.name, count: 0, read: 0, canUnsubscribe: false, isNewsletter: false)
        s.count += 1
        if !m.labelIds.contains("UNREAD") { s.read += 1 }
        if !m.listUnsubscribe.isEmpty { s.canUnsubscribe = true }
        if autoArchiveCategory(m) != nil { s.isNewsletter = true }
        out[e] = s
    }
    return out.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.email < $1.email }
}

/// Mail from a person (not a list, a no-reply address or a Gmail Promotions/Social category).
public func isFromPerson(_ m: Message) -> Bool {
    guard let e = parseAddresses(m.from).first?.email, !isAutomatedAddress(e) else { return false }
    // Shared mailboxes that send receipts, bills, alerts and marketing aren't someone writing to you.
    let local = e.lowercased().split(separator: "@").first.map(String.init) ?? ""
    let roles = ["receipt", "receipts", "billing", "invoice", "invoices", "alerts", "alert", "orders", "order", "news",
                 "newsletter", "info", "updates", "marketing", "notify", "hello", "team", "support", "accounts", "security"]
    if roles.contains(local) { return false }
    return autoArchiveCategory(m) == nil && m.calendar == nil
}

/// The latest email is from a person, written to you directly (To, not just Cc), and you haven't answered it.
public func needsReply(_ c: Conversation, me: Set<String>) -> Bool {
    let m = c.latest
    guard c.inInbox, !m.labelIds.contains("SENT"), isFromPerson(m) else { return false }
    if let from = parseAddresses(m.from).first?.email.lowercased(), me.contains(from) { return false }
    return parseAddresses(m.to).contains { me.contains($0.email.lowercased()) }
}

public enum InsightCategory: String, CaseIterable {
    case people = "People", newsletters = "Newsletters", notifications = "Notifications", calendar = "Calendar"
}

public func insightCategory(_ m: Message) -> InsightCategory {
    if m.calendar != nil { return .calendar }
    if isFromPerson(m) { return .people }
    if autoArchiveCategory(m) != nil { return .newsletters }
    return .notifications
}

public struct InboxInsights {
    public struct Day: Hashable { public var date: Date; public var people: Int; public var other: Int }
    public struct Replied: Hashable { public var name: String; public var email: String; public var replies: Int; public var averageReply: TimeInterval }
    public var received = 0, fromPeople = 0, neverOpened = 0
    public var previousReceived: Int?   // nil when Keymail doesn't hold mail that far back, so a comparison would mislead
    public var averageReply: TimeInterval?
    public var days: [Day] = []
    public var categories: [(InsightCategory, Int)] = []
    public var topSenders: [SenderStat] = []
    public var repliedTo: [Replied] = []
    /// Senders you never read who sent at least 3 emails: the "Clean them up" prompt.
    public var neverReadSenders = 0, neverReadEmails = 0
}

/// Numbers for the Insights screen over the last `days` days, worked out from the mail already on this Mac.
public func inboxInsights(_ messages: [Message], me: Set<String>, days: Int, now: Date = Date(), calendar cal: Calendar = .current) -> InboxInsights {
    let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -(days - 1), to: now)!)
    let prevStart = cal.date(byAdding: .day, value: -days, to: start)!
    var r = InboxInsights()
    let received = messages.filter { !$0.labelIds.contains("SENT") && !me.contains(parseAddresses($0.from).first?.email.lowercased() ?? "") }
    let inPeriod = received.filter { $0.date >= start && $0.date <= now }
    r.received = inPeriod.count
    // Only compare when the mail on this Mac reaches back through the whole earlier period.
    if let oldest = received.map(\.date).min(), oldest < prevStart.addingTimeInterval(86400) {
        r.previousReceived = received.filter { $0.date >= prevStart && $0.date < start }.count
    }
    r.fromPeople = inPeriod.filter(isFromPerson).count
    r.neverOpened = inPeriod.filter { $0.labelIds.contains("UNREAD") }.count

    var byDay: [Date: (Int, Int)] = [:]
    for m in inPeriod {
        let d = cal.startOfDay(for: m.date), p = isFromPerson(m)
        byDay[d, default: (0, 0)].0 += p ? 1 : 0
        byDay[d, default: (0, 0)].1 += p ? 0 : 1
    }
    r.days = (0..<days).map { i in
        let d = cal.date(byAdding: .day, value: i, to: start)!
        return InboxInsights.Day(date: d, people: byDay[d]?.0 ?? 0, other: byDay[d]?.1 ?? 0)
    }
    let counts = Dictionary(grouping: inPeriod, by: insightCategory).mapValues(\.count)
    r.categories = InsightCategory.allCases.map { ($0, counts[$0] ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    let senders = senderStats(inPeriod, me: me, since: start)
    r.topSenders = Array(senders.prefix(6))
    let never = senders.filter { $0.neverRead && $0.count >= 3 }
    r.neverReadSenders = never.count
    r.neverReadEmails = never.reduce(0) { $0 + $1.count }

    // Reply time: each email you sent in the period, measured from the newest email someone else sent before it in that thread.
    var waits: [TimeInterval] = [], perPerson: [String: (name: String, n: Int, total: TimeInterval)] = [:]
    for (_, thread) in Dictionary(grouping: messages, by: { $0.account + "|" + $0.threadId }) {
        let sorted = thread.sorted { $0.date < $1.date }
        for (i, m) in sorted.enumerated() where m.labelIds.contains("SENT") && m.date >= start && m.date <= now {
            guard let prev = sorted[..<i].last(where: { !$0.labelIds.contains("SENT") }),
                  let who = parseAddresses(prev.from).first, isFromPerson(prev) else { continue }
            let wait = m.date.timeIntervalSince(prev.date)
            waits.append(wait)
            let e = who.email.lowercased()
            let cur = perPerson[e] ?? (who.name.isEmpty ? e : who.name, 0, 0)
            perPerson[e] = (cur.name, cur.n + 1, cur.total + wait)
        }
    }
    r.averageReply = waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count)
    r.repliedTo = perPerson.map { InboxInsights.Replied(name: $0.value.name, email: $0.key, replies: $0.value.n, averageReply: $0.value.total / Double($0.value.n)) }
        .sorted { $0.replies != $1.replies ? $0.replies > $1.replies : $0.email < $1.email }.prefix(5).map { $0 }
    return r
}

/// "3h 40m", "50m", "2 days" for reply times.
public func durationLabel(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    if m < 60 { return "\(max(m, 1))m" }
    if m < 48 * 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
    return "\(m / 1440) days"
}
