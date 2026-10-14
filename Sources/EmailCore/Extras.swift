import Foundation

// MARK: Recipient autocomplete

/// People you've corresponded with, best first. Addresses you've written to count triple.
public func contactSuggestions(_ query: String, messages: [Message], me: Set<String>, limit: Int = 6) -> [Address] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    var score: [String: Int] = [:], best: [String: Address] = [:]
    for m in messages {
        let fromMe = parseAddresses(m.from).contains { me.contains($0.email.lowercased()) }
        for (header, weight) in [(m.from, 1), (m.to, fromMe ? 3 : 1), (m.cc, fromMe ? 3 : 1)] {
            for a in parseAddresses(header) {
                let e = a.email.lowercased()
                guard e.contains("@"), !me.contains(e) else { continue }
                score[e, default: 0] += weight
                if best[e] == nil || (best[e]!.name.isEmpty && !a.name.isEmpty) { best[e] = Address(name: a.name, email: e) }
            }
        }
    }
    func hit(_ a: Address) -> Bool {
        a.email.hasPrefix(q) || a.name.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } || a.name.lowercased().hasPrefix(q)
    }
    return best.values.filter(hit).sorted { (score[$0.email] ?? 0, $1.email) > (score[$1.email] ?? 0, $0.email) }.prefix(limit).map { $0 }
}

/// The part of a To/Cc field being typed: everything after the last comma.
public func currentToken(_ field: String) -> String {
    (field.components(separatedBy: ",").last ?? "").trimmingCharacters(in: .whitespaces)
}

/// Replaces the token being typed with a full address and readies the field for the next one.
public func completeField(_ field: String, with a: Address) -> String {
    var parts = field.components(separatedBy: ",")
    parts.removeLast()
    let head = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return (head + [a.formatted]).joined(separator: ", ") + ", "
}

// MARK: Auto Archive

public enum AutoArchiveCategory: String, Codable, CaseIterable, Identifiable {
    case newsletters = "Newsletters & marketing", promotions = "Gmail Promotions tab", social = "Social notifications"
    public var id: String { rawValue }
}

/// Which auto-archive bucket a message falls in, if any. Starred mail is never auto-archived.
public func autoArchiveCategory(_ m: Message) -> AutoArchiveCategory? {
    if m.labelIds.contains("STARRED") { return nil }
    if m.labelIds.contains("CATEGORY_PROMOTIONS") { return .promotions }
    if m.labelIds.contains("CATEGORY_SOCIAL") { return .social }
    if !m.listUnsubscribe.isEmpty { return .newsletters }
    return nil
}

// MARK: Instant reply

/// Claude is asked to separate options with a line containing only "===".
public func parseInstantReplies(_ text: String) -> [String] {
    text.components(separatedBy: "\n===").map { $0.replacingOccurrences(of: "===", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }.prefix(3).map { $0 }
}

// MARK: Quoted text

/// Splits a plain-text email into what's new and the quoted history ("On … wrote:" or trailing > lines).
public func splitQuoted(_ text: String) -> (body: String, quoted: String?) {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var cut: Int?
    for (i, l) in lines.enumerated() {
        let t = l.trimmingCharacters(in: .whitespaces)
        let isHeader = t.hasPrefix("On ") && t.hasSuffix("wrote:")
        let isForward = t.hasPrefix("-----Original Message-----") || t.hasPrefix("---------- Forwarded message")
        let restQuoted = t.hasPrefix(">") && lines[i...].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        if (isHeader || isForward || restQuoted) && i > 0 { cut = i; break }
    }
    guard let c = cut else { return (text, nil) }
    let body = lines[..<c].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let quoted = lines[c...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? (text, nil) : (body, quoted)
}

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

// MARK: Friendly Google errors

/// Turns any Gmail API error response into a sentence a person can act on. Never shows raw JSON.
public func friendlyGoogleError(status: Int, body: String) -> String {
    let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    let err = json?["error"] as? [String: Any]
    let message = (err?["message"] as? String) ?? (json?["error_description"] as? String) ?? ""
    let reason = ((err?["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? "").lowercased()
    let lower = (message + " " + reason + " " + body.prefix(300)).lowercased()
    switch status {
    case 400 where lower.contains("invalid_grant"):
        return "Your Google sign-in expired. Re-add the account in Settings → Accounts."
    case 400:
        return "Gmail couldn't process that request" + (message.isEmpty ? "." : ": \(message)")
    case 401:
        return "Your Google sign-in expired. Re-add the account in Settings → Accounts."
    case 403 where lower.contains("ratelimit") || lower.contains("quota"):
        return "Gmail is asking Email to slow down. It will retry automatically."
    case 403 where lower.contains("accessnotconfigured") || lower.contains("has not been used") || lower.contains("disabled"):
        return "The Gmail API is turned off for your Google Cloud project. Enable it at console.cloud.google.com → APIs & Services."
    case 403 where lower.contains("insufficient") || lower.contains("scope"):
        return "Lightmail doesn't have permission for that. Remove the account and add it again to grant access."
    case 403:
        return "Google blocked that request" + (message.isEmpty ? "." : ": \(message)")
    case 404:
        return "Gmail couldn't find that email. It may have been deleted or moved elsewhere."
    case 409:
        return "That email changed somewhere else at the same time. Try again."
    case 413:
        return "That email is too large for Gmail (25 MB limit including attachments)."
    case 429:
        return "Gmail is asking Email to slow down. It will retry automatically."
    case 500...599:
        return "Gmail is having a temporary problem. Lightmail will try again shortly."
    default:
        return "Gmail returned an unexpected error (\(status))" + (message.isEmpty ? "." : ": \(message)")
    }
}

/// Errors worth retrying quietly: rate limits and Google's own temporary failures.
public func isTransientGoogleError(status: Int, body: String) -> Bool {
    status == 429 || (500...599).contains(status)
        || (status == 403 && (body.contains("ateLimit") || body.contains("uota")))
}

/// Network problems (offline, timeouts, DNS) in plain words.
public func friendlyNetworkError(_ e: Error) -> String? {
    guard let u = e as? URLError else { return nil }
    switch u.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "You're offline. Lightmail will catch up when you reconnect."
    case .timedOut: return "The connection timed out. Lightmail will try again."
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Couldn't reach the mail server. Check your connection."
    case .secureConnectionFailed, .serverCertificateUntrusted: return "A secure connection couldn't be made. If you're on public Wi-Fi, try another network."
    default: return "A network error occurred (\(u.code.rawValue)). Lightmail will try again."
    }
}

// MARK: Cache encryption

import CryptoKit

/// Files written by Email start with this so encrypted and old plain files can be told apart.
public let encryptedFileMagic = Data("EMC1".utf8)

/// AES-256-GCM: confidentiality plus tamper detection.
public func encryptFile(_ plain: Data, key: SymmetricKey) throws -> Data {
    guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw CocoaError(.coderInvalidValue) }
    return encryptedFileMagic + sealed
}

/// Decrypts Email's files; plain JSON from before encryption passes through unchanged so it can be migrated.
public func decryptFile(_ data: Data, key: SymmetricKey) throws -> Data {
    guard data.starts(with: encryptedFileMagic) else { return data }
    return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(encryptedFileMagic.count)), using: key)
}

// MARK: Phishing checks

/// True when the receiving server recorded a failed DMARC, or a failed SPF and DKIM together.
public func authenticationFailed(_ header: String?) -> Bool? {
    guard let h = header?.lowercased(), !h.isEmpty else { return nil }
    if h.contains("dmarc=fail") { return true }
    return h.contains("spf=fail") && h.contains("dkim=fail")
}

/// "mail.paypal.co.uk" → "paypal.co.uk", "login.paypal.com" → "paypal.com".
public func registrableDomain(_ host: String) -> String {
    let parts = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
    guard parts.count > 2 else { return parts.joined(separator: ".") }
    let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
    let keep = parts[parts.count - 1].count == 2 && secondLevel.contains(parts[parts.count - 2]) ? 3 : 2
    return parts.suffix(keep).joined(separator: ".")
}

/// Brands most often impersonated, and the domains they really send from.
let brandDomains: [String: [String]] = [
    "paypal": ["paypal.com"], "apple": ["apple.com", "icloud.com", "me.com"], "icloud": ["icloud.com", "apple.com"],
    "google": ["google.com", "gmail.com", "youtube.com"], "gmail": ["gmail.com", "google.com"],
    "microsoft": ["microsoft.com", "outlook.com", "office.com", "live.com"], "outlook": ["outlook.com", "microsoft.com"],
    "office 365": ["microsoft.com", "office.com"], "amazon": ["amazon.com", "amazon.co.uk", "amazonaws.com"],
    "chase": ["chase.com", "jpmorgan.com"], "bank of america": ["bankofamerica.com", "bofa.com"], "wells fargo": ["wellsfargo.com"],
    "docusign": ["docusign.com", "docusign.net"], "dropbox": ["dropbox.com"], "netflix": ["netflix.com"], "irs": ["irs.gov"],
    "fedex": ["fedex.com"], "ups": ["ups.com"], "usps": ["usps.com"], "venmo": ["venmo.com"], "coinbase": ["coinbase.com"],
    "stripe": ["stripe.com"], "linkedin": ["linkedin.com"], "zelle": ["zellepay.com"], "geek squad": ["bestbuy.com"],
]

/// Undo common letter swaps scammers use: 0→o, 1→l, rn→m, vv→w.
func deconfuse(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        .replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w").replacingOccurrences(of: "ı", with: "i")
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var row = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        var prev = row[0]; row[0] = i
        for j in 1...max(b.count, 1) where !b.isEmpty {
            let cur = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return a.isEmpty ? b.count : row[b.count]
}

/// A domain that imitates a well-known brand's real domain, e.g. paypa1.com or paypal-secure-login.com.
public func lookalikeBrand(_ domain: String) -> String? {
    let d = registrableDomain(domain)
    let allReal = Set(brandDomains.values.flatMap { $0 })
    guard !allReal.contains(d) else { return nil }
    if domain.contains("xn--") { return "a disguised international domain" }
    let name = String(d.split(separator: ".").first ?? "")
    for real in allReal {
        let realName = String(real.split(separator: ".").first ?? "")
        guard realName.count >= 4 else { continue }
        if deconfuse(name) == realName || (name.count >= 5 && editDistance(name, realName) == 1) { return real }
        // Brand name plus extra words: paypal-security.com, apple-id-verify.net
        if name.hasPrefix(realName + "-") || name.hasSuffix("-" + realName) || name.contains("-" + realName + "-") { return real }
    }
    return nil
}

public struct SuspiciousLink: Equatable { public var href: String; public var reason: String }

/// Why a single link looks wrong, or nil. `shown` is the visible link text.
public func linkWarning(href: String, shown: String) -> String? {
    let lower = href.lowercased().trimmingCharacters(in: .whitespaces)
    if lower.hasPrefix("javascript:") || lower.hasPrefix("data:text") { return "This link runs code instead of opening a page." }
    guard let url = URL(string: href), let host = url.host?.lowercased(), url.scheme?.hasPrefix("http") == true else { return nil }
    if host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return "This link goes to a bare IP address (\(host)), not a named website." }
    if host.contains("xn--") { return "This link uses a disguised international domain (\(host))." }
    if let real = lookalikeBrand(host) { return "\(registrableDomain(host)) imitates \(real)." }
    // Visible text that is itself a web address must match where the link goes.
    let text = shown.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = text.range(of: #"([a-z0-9-]+\.)+[a-z]{2,}"#, options: .regularExpression), !text.contains(" ") || text.hasPrefix("http") {
        let shownDomain = registrableDomain(String(text[r]))
        if shownDomain.contains("."), shownDomain != registrableDomain(host) {
            return "The link says \(shownDomain) but goes to \(registrableDomain(host))."
        }
    }
    return nil
}

/// All suspicious links in an HTML body.
public func suspiciousLinks(_ html: String) -> [SuspiciousLink] {
    guard let re = try? NSRegularExpression(pattern: #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, options: .caseInsensitive) else { return [] }
    let ns = html as NSString
    var out: [SuspiciousLink] = []
    for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        let href = decodeEntities(ns.substring(with: m.range(at: 1)))
        let shown = plainFromHTML(ns.substring(with: m.range(at: 2)))
        if let why = linkWarning(href: href, shown: shown), !out.contains(where: { $0.href == href }) { out.append(SuspiciousLink(href: href, reason: why)) }
    }
    return out
}

/// Reasons to doubt who an email is from. `known` = addresses you've written to (their mail skips brand checks).
public func senderWarnings(_ m: Message, known: Set<String>) -> [String] {
    guard let from = parseAddresses(m.from).first else { return [] }
    let email = from.email.lowercased()
    let domain = registrableDomain(String(email.split(separator: "@").last ?? ""))
    var out: [String] = []
    if m.authFailed == true { out.append("The sender's domain didn't verify this email (it failed SPF/DKIM/DMARC). It may be forged.") }
    // A display name that is itself an address on another domain: "service@paypal.com" <x@evil.com>
    let name = from.name.lowercased()
    if let r = name.range(of: #"[a-z0-9._%+-]+@([a-z0-9-]+\.)+[a-z]{2,}"#, options: .regularExpression) {
        let shownDomain = registrableDomain(String(name[r].split(separator: "@").last ?? ""))
        if shownDomain != domain { out.append("The name shows \(shownDomain) but the email came from \(domain).") }
    }
    if !known.contains(email) {
        if let real = lookalikeBrand(domain) {
            out.append(real.contains(".") ? "\(domain) looks like \(real) but isn't." : "The sender uses \(real).")
        } else {
            for (brand, domains) in brandDomains where name.range(of: "\\b\(brand)\\b", options: .regularExpression) != nil {
                if !domains.contains(domain) { out.append("The name says \(brand.capitalized), but the email came from \(domain)."); break }
            }
        }
    }
    if let rt = m.replyTo.flatMap({ parseAddresses($0).first?.email.lowercased() }), let rtd = rt.split(separator: "@").last.map(String.init),
       registrableDomain(rtd) != domain, !known.contains(email) {
        out.append("Replies would go to \(registrableDomain(rtd)), not \(domain).")
    }
    return out
}

// MARK: Gmail settings: out of office (vacation responder)

public struct Vacation: Equatable {
    public var enabled = false
    public var subject = ""
    public var message = ""
    public var contactsOnly = false
    public var domainOnly = false
    public var start: Date?
    public var end: Date?
    public init() {}

    /// From Gmail's `users.settings.getVacation` response.
    public init(json j: [String: Any]) {
        enabled = j["enableAutoReply"] as? Bool ?? false
        subject = j["responseSubject"] as? String ?? ""
        message = (j["responseBodyPlainText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (j["responseBodyHtml"] as? String).map(plainFromHTML) ?? ""
        contactsOnly = j["restrictToContacts"] as? Bool ?? false
        domainOnly = j["restrictToDomain"] as? Bool ?? false
        func date(_ k: String) -> Date? {
            (j[k] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        start = date("startTime"); end = date("endTime")
    }

    /// Body for `users.settings.updateVacation`. Gmail wants times as millisecond strings.
    public var json: [String: Any] {
        var j: [String: Any] = ["enableAutoReply": enabled, "responseSubject": subject,
                                "responseBodyPlainText": message, "responseBodyHtml": plainToHTML(message),
                                "restrictToContacts": contactsOnly, "restrictToDomain": domainOnly]
        if let s = start { j["startTime"] = String(Int64(s.timeIntervalSince1970 * 1000)) }
        if let e = end { j["endTime"] = String(Int64(e.timeIntervalSince1970 * 1000)) }
        return j
    }

    /// On right now: enabled and inside the date window (if any).
    public func isActive(at now: Date = Date()) -> Bool {
        enabled && (start.map { now >= $0 } ?? true) && (end.map { now <= $0 } ?? true)
    }
}

/// Gmail's allowed label colors (background, text). Gmail rejects colors outside its palette.
public let gmailLabelColors: [(bg: String, text: String)] = [
    ("#fb4c2f", "#ffffff"), ("#ffad47", "#ffffff"), ("#fad165", "#000000"), ("#16a766", "#ffffff"),
    ("#43d692", "#000000"), ("#4a86e8", "#ffffff"), ("#a479e2", "#ffffff"), ("#f691b3", "#000000"), ("#666666", "#ffffff"),
]

/// Gmail stores signatures as HTML and drops embedded (data:) images; those need a hosted https:// image.
public func gmailSignatureProblem(_ html: String) -> String? {
    html.contains("data:image") ? "Gmail can't store a logo embedded in the signature. Host the image online and use its https:// address in the HTML, then sync again." : nil
}
