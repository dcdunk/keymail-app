import Foundation

// Raw RFC 5322 / MIME parsing for IMAP providers (iCloud). Gmail's API does this for us.
// Bytes are handled as ISO-8859-1 strings: a lossless 1 byte = 1 character mapping.

private func latin1(_ d: Data) -> String { String(data: d, encoding: .isoLatin1) ?? "" }
private func bytes(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }

public struct ParsedMail {
    public var headers: [String: String] = [:]
    public var html: String?
    public var text: String?
    public var calendar: String?
    public var attachments: [(ref: AttachmentRef, data: Data)] = []
}

/// Splits header block from body and unfolds continuation lines. Keys are lowercased; first wins.
func splitHeaders(_ s: String) -> ([String: String], String) {
    let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
    let parts = normalized.components(separatedBy: "\n\n")
    let head = parts.first ?? "", body = parts.dropFirst().joined(separator: "\n\n")
    var headers: [String: String] = [:], lastKey: String?
    for line in head.components(separatedBy: "\n") {
        if let first = line.first, first == " " || first == "\t", let k = lastKey {
            headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
        } else if let colon = line.firstIndex(of: ":") {
            let k = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            if headers[k] == nil { headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces); lastKey = k } else { lastKey = nil }
        }
    }
    return (headers, body)
}

/// Reads `boundary`, `charset`, `name`, `filename` (incl. RFC 2231 `filename*=UTF-8''...`).
public func headerParam(_ header: String, _ name: String) -> String? {
    for raw in header.components(separatedBy: ";").dropFirst() {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard let eq = p.firstIndex(of: "=") else { continue }
        let key = p[..<eq].lowercased().trimmingCharacters(in: .whitespaces)
        var v = String(p[p.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if key == name { return v }
        if key == name + "*" {
            if let q = v.range(of: "''") { v = String(v[q.upperBound...]) }
            return v.removingPercentEncoding ?? v
        }
    }
    return nil
}

func decodeQuotedPrintable(_ s: String) -> String {
    var out = "", chars = Array(s.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")), i = 0
    while i < chars.count {
        if chars[i] == "=", i + 2 < chars.count, let v = UInt8(String(chars[i + 1...i + 2]), radix: 16) {
            out.append(Character(Unicode.Scalar(v))); i += 3
        } else { out.append(chars[i]); i += 1 }
    }
    return out
}

func decodeCharset(_ d: Data, _ charset: String?) -> String {
    if let cs = charset {
        let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        if cf != kCFStringEncodingInvalidId, let s = String(data: d, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
    }
    return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1) ?? ""
}

/// RFC 2047 `=?UTF-8?B?...?=` / `=?iso-8859-1?Q?...?=`. Whitespace between encoded words is dropped.
public func decodeEncodedWords(_ s: String) -> String {
    let joined = s.replacingOccurrences(of: "\\?=\\s+=\\?", with: "?==?", options: .regularExpression)
    guard let re = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return s }
    var out = joined
    for m in re.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)).reversed() {
        let ns = joined as NSString
        let cs = ns.substring(with: m.range(at: 1)), enc = ns.substring(with: m.range(at: 2)).uppercased(), text = ns.substring(with: m.range(at: 3))
        let data: Data? = enc == "B" ? Data(base64Encoded: text, options: .ignoreUnknownCharacters)
            : bytes(decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " ")))
        if let data, let r = Range(m.range, in: out) { out.replaceSubrange(r, with: decodeCharset(data, cs)) }
    }
    return out
}

func decodeBody(_ body: String, encoding: String?) -> Data {
    switch encoding?.lowercased() {
    case "base64": return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
    case "quoted-printable": return bytes(decodeQuotedPrintable(body))
    default: return bytes(body)
    }
}

public func parseRaw(_ raw: Data) -> ParsedMail {
    var mail = ParsedMail()
    var counter = 0
    // Real mail nests a handful of levels; hostile mail can nest thousands to crash the parser.
    func walk(_ s: String, top: Bool, depth: Int = 0) {
        guard depth < 24, counter < 500 else { return }
        let (h, body) = splitHeaders(s)
        if top { mail.headers = h.mapValues { decodeEncodedWords($0).replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") } }
        let ctype = h["content-type"] ?? "text/plain"
        let mime = ctype.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        if mime.hasPrefix("multipart/"), let b = headerParam(ctype, "boundary") {
            let sections = body.components(separatedBy: "--" + b)
            for sec in sections.dropFirst() where !sec.hasPrefix("--") {
                walk(sec.hasPrefix("\r\n") ? String(sec.dropFirst(2)) : sec.hasPrefix("\n") ? String(sec.dropFirst()) : sec, top: false, depth: depth + 1)
            }
            return
        }
        let disp = h["content-disposition"] ?? ""
        let filename = (headerParam(disp, "filename") ?? headerParam(ctype, "name")).map(decodeEncodedWords)
        let data = decodeBody(body, encoding: h["content-transfer-encoding"])
        if mime.hasPrefix("text/"), filename == nil, !disp.lowercased().hasPrefix("attachment") {
            let str = decodeCharset(data, headerParam(ctype, "charset"))
            if mime == "text/html", mail.html == nil { mail.html = str }
            if mime == "text/plain", mail.text == nil { mail.text = str }
            if mime == "text/calendar", mail.calendar == nil { mail.calendar = str }
            return
        }
        let cid = h["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        mail.attachments.append((AttachmentRef(id: "\(counter)", name: filename ?? "attachment", mimeType: mime, size: data.count,
                                               contentId: cid), data))
        counter += 1
    }
    walk(latin1(raw), top: true)
    return mail
}

public func parseMailDate(_ s: String?) -> Date? {
    guard var s else { return nil }
    s = s.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return nil
}

/// Groups replies with their original: first Message-ID in References, else In-Reply-To, else its own.
public func threadKey(_ h: [String: String]) -> String {
    for k in ["references", "in-reply-to", "message-id"] {
        if let v = h[k], let r = v.range(of: "<[^>]+>", options: .regularExpression) { return String(v[r]) }
    }
    return "subject:" + (h["subject"] ?? "").lowercased()
}

/// iCloud has no "Important" signal, so mail from people counts as important and bulk/automated mail doesn't.
public func likelyImportant(_ h: [String: String]) -> Bool {
    if h["list-unsubscribe"] != nil || h["list-id"] != nil { return false }
    if let p = h["precedence"]?.lowercased(), ["bulk", "list", "junk"].contains(p) { return false }
    let from = (h["from"] ?? "").lowercased()
    return !["noreply", "no-reply", "donotreply", "do-not-reply", "notifications@", "mailer-daemon"].contains { from.contains($0) }
}

/// Builds our Message from a raw IMAP message. `flags` are IMAP flags like \Seen.
public func messageFromRaw(_ raw: Data, uid: Int, flags: [String], account: String, inInbox: Bool) -> Message {
    let p = parseRaw(raw)
    let h = p.headers
    var labels: [String] = []
    if inInbox { labels.append("INBOX") }
    if !flags.contains("\\Seen") { labels.append("UNREAD") }
    if flags.contains("\\Flagged") { labels.append("STARRED") }
    if likelyImportant(h) { labels.append("IMPORTANT") }
    var m = Message(id: "\(uid)", threadId: threadKey(h), account: account, from: h["from"] ?? "", to: h["to"] ?? "", cc: h["cc"] ?? "",
                    subject: h["subject"] ?? "(no subject)", date: parseMailDate(h["date"]) ?? Date(), labelIds: labels,
                    messageIdHeader: h["message-id"] ?? "", references: h["references"] ?? "",
                    listUnsubscribe: h["list-unsubscribe"] ?? "", listUnsubscribePost: h["list-unsubscribe-post"] != nil,
                    html: p.html.map { html in
                        // Images shown in the body are embedded directly, so they render without another download.
                        var map: [String: String] = [:]
                        for a in p.attachments where a.data.count < 5_000_000 {
                            if let c = a.ref.contentId, html.contains("cid:" + c) { map[c] = "data:\(a.ref.mimeType);base64,\(a.data.base64EncodedString())" }
                        }
                        return inlineImages(html, map)
                    }, text: p.text, attachments: p.attachments.map(\.ref))
    m.replyTo = h["reply-to"]
    m.calendar = p.calendar ?? p.attachments.first { $0.ref.mimeType == "text/calendar" || $0.ref.name.lowercased().hasSuffix(".ics") }
        .map { String(decoding: $0.data, as: UTF8.self) }
    m.authFailed = authenticationFailed(h["authentication-results"])
    m.snippet = String(m.plainText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(160))
    return m
}

// MARK: IMAP response helpers

/// Quotes a value for an IMAP command. Line breaks and NUL are removed: inside a command they would end it
/// and let the rest of the value run as a new command (values like Message-ID come from received mail).
public func imapQuote(_ s: String) -> String {
    let clean = s.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" }
    return "\"" + String(String.UnicodeScalarView(clean)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// `* SEARCH 4 9 12` → [4, 9, 12]
public func imapSearchUIDs(_ lines: [String]) -> [Int] {
    lines.filter { $0.hasPrefix("* SEARCH") }.flatMap { $0.dropFirst(8).split(separator: " ").compactMap { Int($0) } }
}

/// `* 5 FETCH (UID 123 FLAGS (\Seen \Flagged) ...` → (123, ["\Seen", "\Flagged"])
public func imapFetchInfo(_ line: String) -> (uid: Int, flags: [String])? {
    guard line.hasPrefix("* "), line.contains(" FETCH "),
          let u = line.range(of: "UID (\\d+)", options: .regularExpression),
          let uid = Int(line[u].dropFirst(4)) else { return nil }
    var flags: [String] = []
    if let f = line.range(of: "FLAGS \\(([^)]*)\\)", options: .regularExpression) {
        flags = line[f].dropFirst(7).dropLast().split(separator: " ").map(String.init)
    }
    return (uid, flags)
}

/// `* LIST (\HasNoChildren \Archive) "/" "Archive"` → ["\Archive": "Archive"]
public func imapSpecialUse(_ lines: [String]) -> [String: String] {
    var out: [String: String] = [:]
    for l in lines where l.hasPrefix("* LIST") {
        guard let open = l.firstIndex(of: "("), let close = l.firstIndex(of: ")") else { continue }
        let attrs = l[l.index(after: open)..<close].split(separator: " ").map(String.init)
        let rest = l[l.index(after: close)...].trimmingCharacters(in: .whitespaces)
        // rest = "/" "Name"  or  "/" Name
        let name = rest.split(separator: " ", maxSplits: 1).dropFirst().first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? ""
        for a in attrs where ["\\Archive", "\\Trash", "\\Sent", "\\Junk", "\\Drafts"].contains(a) { out[a] = name }
    }
    return out
}

/// Which IMAP/SMTP servers an app-password account uses. Yahoo is picked by address; everything else is iCloud.
public struct IMAPServer: Equatable {
    public let name: String, imapHost: String, smtpURL: String
}

// ponytail: Yahoo detected by domain only; custom domains on Yahoo (Business Mail) fall through to iCloud.
public func imapServer(for email: String) -> IMAPServer {
    let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
    if domain.hasPrefix("yahoo.") || ["ymail.com", "rocketmail.com"].contains(domain) {
        return IMAPServer(name: "Yahoo", imapHost: "imap.mail.yahoo.com", smtpURL: "smtp://smtp.mail.yahoo.com:587")
    }
    return IMAPServer(name: "iCloud", imapHost: "imap.mail.me.com", smtpURL: "smtp://smtp.mail.me.com:587")
}

/// True when an HTML email would load something from the internet (images, CSS backgrounds, fonts).
public func hasRemoteContent(_ html: String) -> Bool {
    html.range(of: #"(src|background)\s*=\s*["']?\s*(https?:)?//|url\(\s*["']?\s*(https?:)?//"#, options: [.regularExpression, .caseInsensitive]) != nil
}
