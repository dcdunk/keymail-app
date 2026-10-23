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
    splitRecipientField(field).token.trimmingCharacters(in: .whitespaces)
}

/// The finished recipients and the one still being typed, split at the last comma that separates addresses.
/// Commas inside a quoted name ("Fitzpatrick, Psy.D.") or <…> belong to that address: splitting there turned one
/// recipient into a chip plus a stray `Psy.D." <…>`.
public func splitRecipientField(_ field: String) -> (head: String, token: String) {
    var inQuote = false, inAngle = false, cut: String.Index?
    for i in field.indices {
        switch field[i] {
        case "\"": inQuote.toggle()
        case "<" where !inQuote: inAngle = true
        case ">" where !inQuote: inAngle = false
        case "," where !inQuote && !inAngle: cut = i
        default: break
        }
    }
    guard let cut else { return ("", field) }
    return (String(field[..<cut]), String(field[field.index(after: cut)...]))
}

/// Replaces the token being typed with a full address and readies the field for the next one.
public func completeField(_ field: String, with a: Address) -> String {
    let head = parseAddresses(splitRecipientField(field).head).map(\.formatted)
    return (head + [a.formatted]).joined(separator: ", ") + ", "
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

/// HTML replies carry the whole earlier conversation underneath. Splits at the first quote marker that Gmail, Apple Mail,
/// Outlook (web and desktop), Yahoo or Proton write, so the thread view can show only what this email added.
/// quoted is nil when there's no marker, or when nothing would be left above it (keep the email whole).
public func splitQuotedHTML(_ html: String) -> (body: String, quoted: String?) {
    let markers = [
        #"<div[^>]*class="[^"]*gmail_quote"#,              // Gmail
        #"<blockquote[^>]*type="cite""#,                   // Apple Mail
        #"<div[^>]*id="(divRplyFwdMsg|appendonsend)""#,    // Outlook on the web / new Outlook
        #"<hr[^>]*id="stopSpelling""#,                     // older Outlook web
        #"<div[^>]*style="[^"]*border-top:\s*solid\s*#[eE]1[eE]1[eE]1"#,   // Outlook desktop's "From:" rule
        #"<div[^>]*class="[^"]*(yahoo_quoted|protonmail_quote)"#,          // Yahoo, Proton
        #"-{3,}\s*Original Message\s*-{3,}"#,                // help desks (Zendesk, Salesforce) and older Outlook
        #"(?<=>)\s*On [^<>]{6,200} wrote:"#,                  // "On Mon, Sep 1, Maya wrote:" as its own line
    ]
    let ns = html as NSString
    var cut = ns.length
    for m in markers {
        if let r = try? NSRegularExpression(pattern: m, options: .caseInsensitive).firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
           r.range.location < cut { cut = r.range.location }
    }
    guard cut < ns.length else { return (html, nil) }
    let body = ns.substring(to: cut)
    // Only tags and whitespace above the quote (e.g. a forward): nothing would be left to read.
    let text = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return (html, nil) }
    return (body, ns.substring(from: cut))
}

/// Backspace in an empty To/Cc/Bcc box: the field without its last address. nil while something is being typed
/// (Backspace edits that text) or when there's nothing to remove.
/// A field whose last entry is already a complete address ("Sam <sam@x.co>") with no comma after it, finished so it
/// shows as a chip. nil when there's nothing to finish or the last entry isn't a full address yet.
public func chipsFilled(_ field: String) -> String? {
    let token = currentToken(field)
    guard !token.isEmpty, let a = parseAddresses(token).first, parseAddresses(token).count == 1,
          a.email.contains("@"), a.email.split(separator: "@").last?.contains(".") == true, !a.email.contains(" ") else { return nil }
    return (parseAddresses(splitRecipientField(field).head) + [a]).map { $0.formatted + ", " }.joined()
}

public func removingLastRecipient(_ field: String) -> String? {
    guard currentToken(field).isEmpty else { return nil }
    var chips = parseAddresses(splitRecipientField(field).head).map(\.formatted)
    guard !chips.isEmpty else { return nil }
    chips.removeLast()
    return chips.map { $0 + ", " }.joined()
}
