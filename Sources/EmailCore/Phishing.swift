import Foundation

// MARK: Phishing checks

/// The Authentication-Results header the provider's own receiving server added, or nil.
/// Senders can add their own fake "dmarc=pass" headers lower down, so only the server's own one counts.
public func providerAuthResults(_ headers: [String], server: String) -> String? {
    headers.first { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(server) }
}

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
    if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") { return "This link runs code instead of opening a page." }
    guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return "This link isn't a normal web address." }
    // Allowlist: only web pages and new emails open directly. Anything else (files, network shares,
    // remote login, other apps' links) can act on this Mac, so it always asks first.
    if scheme == "mailto" { return nil }
    guard scheme == "http" || scheme == "https" else { return "This link opens something on your Mac (\(scheme):), not a web page." }
    guard let host = url.host?.lowercased() else { return "This link has no website in it." }
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

/// All suspicious links in an HTML body. One linear pass over the tags (no backtracking on hostile input),
/// capped at the first 2 MB and 2,000 links.
public func suspiciousLinks(_ html: String) -> [SuspiciousLink] {
    let text = String(html.prefix(2_000_000))
    guard let tags = try? NSRegularExpression(pattern: #"<a\s[^<>]*>|</a\s*>"#, options: .caseInsensitive),
          let hrefRe = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) else { return [] }
    let ns = text as NSString
    var out: [SuspiciousLink] = [], open: (href: String, end: Int)?, seen = 0
    for m in tags.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let tag = ns.substring(with: m.range)
        if tag.hasPrefix("</") {
            guard let o = open else { continue }
            open = nil
            let shown = plainFromHTML(ns.substring(with: NSRange(location: o.end, length: m.range.location - o.end)))
            if let why = linkWarning(href: o.href, shown: shown), !out.contains(where: { $0.href == o.href }) { out.append(SuspiciousLink(href: o.href, reason: why)) }
        } else if let h = hrefRe.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
            seen += 1
            if seen > 2000 { break }
            open = (decodeEntities((tag as NSString).substring(with: h.range(at: 1))), m.range.location + m.range.length)
        }
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

/// One spelling per link: lowercase scheme and host, no trailing "/" on a bare host. The same link written in the email
/// and as WebKit hands it over on a click compare equal.
public func normalizedLink(_ href: String) -> String {
    guard var c = URLComponents(string: href.trimmingCharacters(in: .whitespacesAndNewlines)) else { return href }
    c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased()
    if c.path == "/" { c.path = "" }
    return c.string ?? href
}
