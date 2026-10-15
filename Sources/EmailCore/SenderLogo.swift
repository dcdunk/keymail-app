import Foundation

/// Mail providers people use personally: their logo says nothing about the sender, so those keep the initial.
let personalMailDomains: Set<String> = [
    "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
    "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "fastmail.com", "hey.com", "gmx.com", "zoho.com",
]

/// The company site to take a sender's logo from: health@aws.com → aws.com, receipts@email.trinet.com → trinet.com.
/// nil for personal mailboxes (gmail.com and friends) and anything that isn't a domain.
public func logoDomain(for email: String) -> String? {
    guard let at = email.lastIndex(of: "@") else { return nil }
    let labels = email[email.index(after: at)...].lowercased().split(separator: ".").map(String.init)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
    // ponytail: two-part suffixes guessed by length (co.uk, com.au), not the full public suffix list.
    let keep = labels.count >= 3 && labels[labels.count - 2].count <= 3 && labels.last!.count == 2 ? 3 : 2
    let domain = labels.suffix(keep).joined(separator: ".")
    return personalMailDomains.contains(domain) ? nil : domain
}

/// Icon links a homepage declares, best first: apple-touch-icon (large, square), then other icons.
public func iconLinks(inHTML html: String) -> [String] {
    func all(_ pattern: String, _ text: String) -> [[String]] {
        let re = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive), ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    let tags = all("<link\\b[^>]*>", html).map { $0[0] }
    func attr(_ name: String, _ tag: String) -> String? { all(name + "\\s*=\\s*[\"']([^\"']+)[\"']", tag).first?[1] }
    let icons = tags.compactMap { t -> (rel: String, href: String)? in
        guard let rel = attr("rel", t)?.lowercased(), rel.contains("icon"), !rel.contains("mask"), let href = attr("href", t) else { return nil }
        return (rel, href.replacingOccurrences(of: "&amp;", with: "&"))
    }
    return icons.filter { $0.rel.contains("apple-touch") }.map(\.href) + icons.filter { !$0.rel.contains("apple-touch") }.map(\.href)
}

/// Sites to try, in order, for a sender's logo. Companies often mail from a domain with no website
/// (sonarsource.email, stripemail.com, acme-news.io), so after the domain itself this tries the company name
/// with mail words stripped, then the sender's name ("xSuit" mailing from an unrelated domain → xsuit.com),
/// on the usual company TLDs.
public func logoSites(for domain: String, senderName: String? = nil) -> [String] {
    var labels = domain.split(separator: ".").map(String.init)
    guard labels.count >= 2 else { return [domain] }
    labels.removeLast()
    let name = labels.last!   // bbc.co.uk → "co" handled by logoDomain keeping 3 labels; take the label before the suffix
    let base = labels.count >= 2 && name.count <= 3 ? labels[labels.count - 2] : name
    var names = [base]
    // Try each mail word on its own: "stripemail" could be stripe+mail or strip+email, so both are kept.
    for w in ["mail", "email", "mails", "emails", "mailer", "mailing", "news", "info", "notify", "notifications", "updates", "hq", "team"] {
        for cut in [base.hasSuffix(w) ? String(base.dropLast(w.count)) : nil, base.hasPrefix(w) ? String(base.dropFirst(w.count)) : nil] {
            if let n = cut?.trimmingCharacters(in: CharacterSet(charactersIn: "-_")), n.count >= 2 { names.append(n) }
        }
    }
    let company = companyName(senderName)
    if let company { names.append(company) }
    var sites = [domain]
    // .com for every guess before any rarer TLD, and only a few TLDs: each extra guess is a chance of a stranger's logo.
    for tld in ["com", "io", "co"] { for n in names { sites.append("\(n).\(tld)") } }
    // The name has nothing in common with the domain (xSuit mailing through getredo.com, a returns service):
    // the domain is a vendor's, so the sender's own name goes first or we'd show the vendor's logo.
    if let company, !base.contains(company), !company.contains(base) {
        sites = ["com", "io", "co"].map { "\(company).\($0)" } + sites
    }
    var seen = Set<String>()
    return sites.filter { seen.insert($0).inserted }
}

/// "The Sonar Team" → "sonar", "xSuit" → "xsuit", "Salesforce Billing" → "salesforce". nil for addresses and blanks.
func companyName(_ display: String?) -> String? {
    guard let display, !display.contains("@") else { return nil }
    let filler: Set<String> = ["the", "team", "billing", "support", "inc", "llc", "ltd", "co", "corp", "hq", "news", "newsletter",
                               "notifications", "updates", "no-reply", "noreply", "donotreply", "do-not-reply", "reply", "alerts", "receipts", "orders", "from", "at", "via", "customer", "service", "care", "&", "and"]
    let words = display.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
        .filter { !$0.isEmpty && !filler.contains($0) }
    let name = words.joined()
    return name.count >= 2 && name.count <= 30 ? name : nil
}
