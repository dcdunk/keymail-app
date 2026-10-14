import Foundation

public struct Message: Codable, Identifiable, Hashable {
    public var id: String
    public var threadId: String
    public var account: String
    public var from: String
    public var to: String
    public var cc: String
    public var subject: String
    public var snippet: String
    public var date: Date
    public var labelIds: [String]
    public var messageIdHeader: String
    public var references: String
    public var listUnsubscribe: String
    public var listUnsubscribePost: Bool
    public var html: String?
    public var text: String?
    public var attachments: [AttachmentRef] = []
    public var replyTo: String?        // Reply-To header, if any
    public var authFailed: Bool?       // the sender's domain failed SPF/DKIM/DMARC (from Authentication-Results)

    public init(id: String, threadId: String, account: String, from: String, to: String = "", cc: String = "",
                subject: String = "", snippet: String = "", date: Date = Date(), labelIds: [String] = [],
                messageIdHeader: String = "", references: String = "", listUnsubscribe: String = "",
                listUnsubscribePost: Bool = false, html: String? = nil, text: String? = nil, attachments: [AttachmentRef] = []) {
        self.id = id; self.threadId = threadId; self.account = account; self.from = from; self.to = to
        self.cc = cc; self.subject = subject; self.snippet = snippet; self.date = date; self.labelIds = labelIds
        self.messageIdHeader = messageIdHeader; self.references = references; self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost; self.html = html; self.text = text; self.attachments = attachments
    }

    /// Cache key: Gmail ids are only unique within one account.
    public var key: String { account + "|" + id }

    /// Best-effort plain text of the body, for quoting and for the AI prompt.
    public var plainText: String {
        if let text, !text.isEmpty { return text }
        guard let html else { return snippet }
        return plainFromHTML(html)
    }
}

/// Strips tags, scripts and styles; keeps line breaks.
public func plainFromHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?is)<(style|script|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
}

public struct AttachmentRef: Codable, Hashable {
    public var id: String, name: String, mimeType: String, size: Int
    public var contentId: String?   // set for images embedded in the body (<img src="cid:...">)
    public init(id: String, name: String, mimeType: String, size: Int, contentId: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size; self.contentId = contentId
    }
    public var isInline: Bool { contentId != nil }
}

/// Turns bare http(s) links in already-escaped plain text into clickable links.
public func linkify(_ escaped: String) -> String {
    escaped.replacingOccurrences(of: "(https?://[^\\s<>\"]+[^\\s<>\".,;:!?)\\]])", with: "<a href=\"$1\">$1</a>", options: .regularExpression)
}

/// Swaps `cid:` image references for data URLs. `images` maps content id → data URL.
public func inlineImages(_ html: String, _ images: [String: String]) -> String {
    var out = html
    for (cid, url) in images { out = out.replacingOccurrences(of: "cid:" + cid, with: url) }
    return out
}

public struct Conversation: Identifiable, Hashable {
    public var account: String
    public var threadId: String
    public var messages: [Message] // oldest first
    public var bumped: Date?       // set when a snooze or follow-up returns it to the inbox

    public var id: String { account + "|" + threadId }
    public var latest: Message { messages[messages.count - 1] }
    public var labels: Set<String> { Set(messages.flatMap(\.labelIds)) }
    public var isUnread: Bool { labels.contains("UNREAD") }
    public var isStarred: Bool { labels.contains("STARRED") }
    public var inInbox: Bool { labels.contains("INBOX") }
    public var sortDate: Date { max(latest.date, bumped ?? .distantPast) }
}

/// Groups messages into threads, newest thread first.
public func conversations(from messages: [Message], bumped: [String: Date] = [:]) -> [Conversation] {
    let groups = Dictionary(grouping: messages) { $0.account + "|" + $0.threadId }
    return groups.map { id, msgs in
        let sorted = msgs.sorted { $0.date < $1.date }
        return Conversation(account: sorted[0].account, threadId: sorted[0].threadId, messages: sorted, bumped: bumped[id])
    }.sorted { $0.sortDate > $1.sortDate }
}

public struct Address: Hashable {
    public var name: String
    public var email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
    public var display: String { name.isEmpty ? email : name }
    public var firstName: String { name.isEmpty ? "" : String(name.split(separator: " ").first ?? "") }
    public var formatted: String {
        if name.isEmpty { return email }
        let n = name.contains(",") || name.contains("\"") ? "\"\(name.replacingOccurrences(of: "\"", with: ""))\"" : name
        return "\(n) <\(email)>"
    }
}

/// Parses a header like `"Chen, Maya" <maya@x.com>, bob@y.com`.
public func parseAddresses(_ header: String) -> [Address] {
    var parts: [String] = [], cur = "", inQuote = false, inAngle = false
    for ch in header {
        if ch == "\"" { inQuote.toggle() }
        if ch == "<" { inAngle = true }
        if ch == ">" { inAngle = false }
        if ch == ",", !inQuote, !inAngle { parts.append(cur); cur = ""; continue }
        cur.append(ch)
    }
    parts.append(cur)
    return parts.compactMap { raw in
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        if let lt = p.lastIndex(of: "<"), let gt = p.lastIndex(of: ">"), lt < gt {
            let email = String(p[p.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            let name = String(p[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return Address(name: name, email: email)
        }
        return Address(name: "", email: p)
    }
}

/// "Sam Patel, You" style label for a thread's senders.
public func participantsLabel(_ c: Conversation, me: Set<String>) -> String {
    var seen: [String] = []
    for m in c.messages {
        guard let a = parseAddresses(m.from).first else { continue }
        let label = me.contains(a.email.lowercased()) ? "You" : a.display
        if !seen.contains(label) { seen.append(label) }
    }
    if seen.count <= 1 { return seen.first ?? "" }
    return seen.suffix(3).map { $0 == "You" ? $0 : ($0.split(separator: " ").first.map(String.init) ?? $0) }.joined(separator: ", ")
}

/// "9:46 am" for today, "12 Oct" otherwise.
public func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_GB")
    if calendar.isDate(date, inSameDayAs: now) {
        f.dateFormat = "h:mm a"; f.amSymbol = "am"; f.pmSymbol = "pm"
    } else {
        f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
    }
    return f.string(from: date)
}

public func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = s
    let named = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
                 ("&middot;", "·"), ("&bull;", "•"), ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"), ("&copy;", "©"),
                 ("&reg;", "®"), ("&trade;", "™"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&zwnj;", "")]
    for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
    // Numeric entities: &#183; and &#xB7;
    if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            let ns = out as NSString
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n),
               let r = Range(m.range, in: out) { out.replaceSubrange(r, with: String(Character(u))) }
        }
    }
    return out.replacingOccurrences(of: "&amp;", with: "&")
}

public func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
