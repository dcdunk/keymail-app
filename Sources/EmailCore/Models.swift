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
    public var calendar: String?       // a calendar invite carried inside the email (text/calendar part), if any

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
/// Linear-time on hostile input: no backtracking regex, and the input is capped (an email's text is never this long).
public func plainFromHTML(_ html: String) -> String {
        var s = removeBlocks(String(html.prefix(2_000_000)), tags: ["style", "script", "head"])
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^<>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Removes <tag ...>...</tag> blocks with plain substring searches. An unclosed block drops the rest of the text.
func removeBlocks(_ html: String, tags: [String]) -> String {
    var s = html
    for tag in tags {
        var out = "", rest = s[...]
        while let open = rest.range(of: "<" + tag, options: .caseInsensitive) {
            // "<head" must not match "<header": the tag name has to end there.
            if open.upperBound < rest.endIndex, let c = rest[open.upperBound].unicodeScalars.first,
               !(c == ">" || c == "/" || CharacterSet.whitespacesAndNewlines.contains(c)) {
                out += rest[..<open.upperBound]; rest = rest[open.upperBound...]; continue
            }
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "</" + tag, options: .caseInsensitive) else { rest = rest[rest.endIndex...]; break }
            let end = rest[close.upperBound...].firstIndex(of: ">").map { rest.index(after: $0) } ?? rest.endIndex
            rest = rest[end...]
        }
        s = out + rest
    }
    return s
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
/// Bounded: only image data URLs and plain-token ids are used, and an image is skipped when inlining it
/// would grow the email past `limit` bytes (a tiny email repeating one reference could otherwise need gigabytes).
public func inlineImages(_ html: String, _ images: [String: String], limit: Int = 30_000_000) -> String {
    var out = html, size = html.utf8.count
    let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@$%+-=")
    for (cid, url) in images.sorted(by: { $0.key.count > $1.key.count }) { // longest first, so "a" never eats "ab"
        guard !cid.isEmpty, cid.unicodeScalars.allSatisfy(token.contains), url.hasPrefix("data:image/") else { continue }
        let uses = out.components(separatedBy: "cid:" + cid).count - 1
        guard uses > 0, size + uses * url.utf8.count <= limit else { continue }
        out = out.replacingOccurrences(of: "cid:" + cid, with: url)
        size += uses * url.utf8.count
    }
    return out
}

/// Index into a palette from any hash, including Int.min (abs(Int.min) would crash).
public func paletteIndex(_ hash: Int, count: Int) -> Int { Int(UInt(bitPattern: hash) % UInt(max(count, 1))) }

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
        // RFC 5322: the address is the <...> outside quotes and (comments). A "<x@y>" inside a quoted name or a
        // comment is display text, the same way Gmail and DMARC read it, so it can't stand in for the real sender.
        var plain = "", angle: String?, inQ = false, depth = 0, cur: String?
        for ch in p {
            if ch == "\"" && depth == 0 { inQ.toggle(); plain.append(ch); continue }
            if !inQ && ch == "(" { depth += 1; continue }
            if !inQ && ch == ")" && depth > 0 { depth -= 1; continue }
            if depth > 0 { continue }
            if !inQ && ch == "<" { cur = ""; continue }
            if !inQ && ch == ">", let c = cur { angle = c; cur = nil; continue }
            if cur != nil { cur!.append(ch) } else { plain.append(ch) }
        }
        let name = plain.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if let a = angle { return Address(name: name, email: a.trimmingCharacters(in: .whitespaces)) }
        return Address(name: "", email: name)
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
