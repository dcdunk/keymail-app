import Foundation
import CryptoKit

public struct Draft: Codable, Hashable {
    /// Nothing written yet: no recipients, subject, text or attachments. Closing it doesn't ask, and it's never saved.
    public var isBlank: Bool {
        to.trimmingCharacters(in: .whitespaces).isEmpty && cc.trimmingCharacters(in: .whitespaces).isEmpty
            && bcc.trimmingCharacters(in: .whitespaces).isEmpty && subject.isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
    }
    public var from: String
    public var to = ""
    public var cc = ""
    public var bcc = ""
    public var subject = ""
    public var body = ""
    public var inReplyTo = ""
    public var references = ""
    public var threadId: String?
    public var files: [OutgoingFile] = []
    public var messageId: String?
    public var draftId: String?   // Gmail draft this compose is saved as
    public var quoted: String?           // the original being replied to / forwarded, kept apart from what you type
    public var signaturePlain: String?   // plain-text signature, placed between `body` and `quoted`
    public var signatureHTML: String?    // its rich version; when set, the email also goes out as HTML
    public var calendarReply: String?    // an iTIP REPLY (.ics) sent alongside the text so the organizer's calendar records it
    /// The account this draft saves and sends through. One address can be an alias on two accounts (an iCloud address
    /// Gmail also sends as), so the address alone can't say which; nil falls back to looking the address up.
    public var account: String?
    public init(from: String, account: String? = nil) { self.from = from; self.account = account }
}

public struct OutgoingFile: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String, mimeType: String, data: Data
    public init(name: String, mimeType: String, data: Data) { self.name = name; self.mimeType = mimeType; self.data = data }
}

/// Each provider's largest email, after base64 (which adds about a third): Gmail 25 MB, iCloud/Yahoo 20 MB, and
/// Outlook about 3 MB, because Keymail sends Outlook mail as a MIME upload that Microsoft caps at 4 MB.
public func attachmentLimit(provider: String) -> (bytes: Int, label: String) {
    switch provider {
    case "outlook": return (3_000_000, "Outlook's 3 MB limit for emails sent from Keymail")
    case "icloud": return (19_000_000, "iCloud's 20 MB limit")
    default: return (24_000_000, "Gmail's 25 MB limit")
    }
}
public func attachmentsTooLarge(_ files: [OutgoingFile], limit: Int = 24_000_000) -> Bool { files.reduce(0) { $0 + $1.data.count } * 4 / 3 > limit }

public func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

public func base64urlDecode(_ s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b = b.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.count % 4 != 0 { b += "=" }
    return Data(base64Encoded: b)
}

/// RFC 2047 encoded-word for non-ASCII header text.
public func encodeHeader(_ s: String) -> String {
    s.allSatisfy(\.isASCII) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
}

/// RFC 5322 message, plain text UTF-8 body. Gmail wants this base64url-encoded in `raw`.
public func buildRaw(_ d: Draft, date: Date = Date()) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    // Recipient fields may carry a trailing ", " from the chip editor; send a clean list.
    func clean(_ f: String) -> String { parseAddresses(f).map(\.formatted).joined(separator: ", ") }
    var h: [(String, String)] = [("From", d.from), ("To", clean(d.to)), ("Cc", clean(d.cc)), ("Bcc", clean(d.bcc)),
                                 ("Subject", encodeHeader(d.subject)), ("Date", df.string(from: date)),
                                 ("In-Reply-To", d.inReplyTo), ("References", d.references), ("Message-ID", d.messageId ?? "")]
    h = h.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
    h.append(("MIME-Version", "1.0"))
    let content = contentPart(d)
    var body = content
    if !d.files.isEmpty {
        let boundary = "=_email_" + UUID().uuidString
        h.append(("Content-Type", "multipart/mixed; boundary=\"\(boundary)\""))
        var parts = [content]
        for f in d.files {
            let name = headerSafe(encodeHeader(f.name)).replacingOccurrences(of: "\"", with: "")
            let mime = headerSafe(f.mimeType).replacingOccurrences(of: ";", with: "")
            parts.append("Content-Type: \(mime); name=\"\(name)\"\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\n"
                         + "Content-Transfer-Encoding: base64\r\n\r\n" + f.data.base64EncodedString(options: .lineLength76Characters))
        }
        body = parts.map { "--\(boundary)\r\n" + $0 + "\r\n" }.joined() + "--\(boundary)--"
    }
    let head = h.map { "\($0.0): \(headerSafe($0.1))" }.joined(separator: "\r\n")
    // Single part: the content part's own headers become top-level headers.
    return head + "\r\n" + (d.files.isEmpty ? body : "\r\n" + body) + "\r\n"
}

/// Header values must be one line: CR, LF and other control characters (which can arrive in quoted
/// subjects and addresses from received mail) are replaced with spaces.
func headerSafe(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : $0 }))
}

private func base64Part(_ type: String, _ text: String) -> String {
    let data = Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
    return "Content-Type: \(type); charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + data.base64EncodedString(options: .lineLength76Characters)
}

/// Plain text alone, or plain + HTML (multipart/alternative) when there's a rich signature.
/// Images embedded as data: URLs become inline attachments (multipart/related), since Gmail blocks data: images.
func contentPart(_ d: Draft) -> String {
    let plain = base64Part("text/plain", fullBody(d))
    if let ics = d.calendarReply {
        let b = "=_cal_" + UUID().uuidString
        return "Content-Type: multipart/alternative; boundary=\"\(b)\"\r\n\r\n--\(b)\r\n\(plain)\r\n--\(b)\r\n"
            + base64Part("text/calendar; method=REPLY", ics) + "\r\n--\(b)--"
    }
    guard let html = composeHTML(d) else { return plain }
    let (cidHTML, images) = extractDataImages(html)
    var htmlPart = base64Part("text/html", cidHTML)
    if !images.isEmpty {
        let r = "=_rel_" + UUID().uuidString
        var parts = [htmlPart]
        for img in images {
            parts.append("Content-Type: \(img.mimeType)\r\nContent-ID: <\(img.cid)>\r\nContent-Disposition: inline\r\n"
                         + "Content-Transfer-Encoding: base64\r\n\r\n" + img.data.base64EncodedString(options: .lineLength76Characters))
        }
        htmlPart = "Content-Type: multipart/related; boundary=\"\(r)\"\r\n\r\n" + parts.map { "--\(r)\r\n\($0)\r\n" }.joined() + "--\(r)--"
    }
    let b = "=_alt_" + UUID().uuidString
    return "Content-Type: multipart/alternative; boundary=\"\(b)\"\r\n\r\n"
        + "--\(b)\r\n\(plain)\r\n--\(b)\r\n\(htmlPart)\r\n--\(b)--"
}

/// Replaces `src="data:image/...;base64,..."` with `cid:` references and returns the decoded images.
public func extractDataImages(_ html: String) -> (html: String, images: [(cid: String, mimeType: String, data: Data)]) {
    guard let re = try? NSRegularExpression(pattern: "data:(image/[a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=\\s]+)") else { return (html, []) }
    var out = html, images: [(String, String, Data)] = []
    for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
        let ns = html as NSString
        guard let data = Data(base64Encoded: ns.substring(with: m.range(at: 2)), options: .ignoreUnknownCharacters),
              let r = Range(m.range, in: out) else { continue }
        let cid = "img\(images.count + 1).\(UUID().uuidString.prefix(8))@email"
        images.append((cid, ns.substring(with: m.range(at: 1)), data))
        out.replaceSubrange(r, with: "cid:" + cid)
    }
    return (out, images.reversed())
}

/// The inside of <body>, without doctype/head, so a pasted or imported page becomes a signature fragment.
public func extractBodyHTML(_ html: String) -> String {
    var s = html
    if let open = s.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
        s = String(s[open.upperBound...])
        if let close = s.range(of: "</body>", options: .caseInsensitive) { s = String(s[..<close.lowerBound]) }
    }
    s = s.replacingOccurrences(of: "(?is)<!doctype[^>]*>|<head>.*?</head>|</?html[^>]*>|<meta[^>]*>", with: "", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Layout the rich-text editor can't round-trip without changing it.
public func isComplexHTML(_ html: String) -> Bool {
    html.range(of: "<(table|img|style)\\b|border-radius|display\\s*:", options: [.regularExpression, .caseInsensitive]) != nil
}

/// Escapes plain text for HTML, keeping line breaks and making links clickable.
public func plainToHTML(_ text: String) -> String {
    linkify(escapeHTML(text)).replacingOccurrences(of: "\n", with: "<br>\n")
}

/// Standard signature delimiter ("-- " on its own line), which mail apps recognise.
public let signatureDelimiter = "-- \n"

/// What actually gets sent as text: your text, then the signature, then the quoted original.
public func fullBody(_ d: Draft) -> String {
    let sig = (d.signaturePlain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return d.body + (sig.isEmpty ? "" : "\n\n" + signatureDelimiter + sig) + (d.quoted ?? "")
}

/// The HTML version of a draft: your text, the rich signature, then the quote. Nil when there's no rich signature.
public func composeHTML(_ d: Draft) -> String? {
    guard let sigHTML = d.signatureHTML, !sigHTML.isEmpty else { return nil }
    var html = "<div>\(plainToHTML(d.body))</div><br><div class=\"signature\">\(sigHTML)</div>"
    let after = (d.quoted ?? "").trimmingCharacters(in: .newlines)
    if !after.isEmpty {
        html += "<br><blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex;color:#555\">\(plainToHTML(after))</blockquote>"
    }
    return "<!doctype html><html><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\(html)</body></html>"
}

/// A saved signature as (plain text for the compose box, HTML for sending). Plain signatures have no HTML.
public func signatureParts(_ stored: String) -> (plain: String, html: String?) {
    let s = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.range(of: "<[a-zA-Z][^>]*>", options: .regularExpression) != nil else { return (s, nil) }
    return (plainFromHTML(s), s)
}

// MARK: Reply / forward

public func replySubject(_ s: String) -> String { s.lowercased().hasPrefix("re:") ? s : "Re: " + s }
public func forwardSubject(_ s: String) -> String { s.lowercased().hasPrefix("fwd:") ? s : "Fwd: " + s }

private func quoted(_ m: Message) -> String {
    let who = parseAddresses(m.from).first?.display ?? m.from
    let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
    let lines = m.plainText.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
    return "\n\nOn \(df.string(from: m.date)), \(who) wrote:\n" + lines
}

/// `mine`: every address of yours (aliases too), so a message you sent from an alias still counts as yours.
public func replyDraft(to m: Message, me: String, all: Bool, mine: Set<String> = []) -> Draft {
    let meL = me.lowercased()
    let mineL = Set(mine.map { $0.lowercased() }).union([meL])
    let sender = parseAddresses(m.from)
    // Replying to my own message goes to whoever I sent it to. Otherwise to Reply-To when the sender set one
    // (help desks, forms, mailing lists), else the sender.
    let fromMe = sender.contains { mineL.contains($0.email.lowercased()) }
    let replyTo = parseAddresses(m.replyTo ?? "").filter { !$0.email.isEmpty }
    let to = fromMe ? parseAddresses(m.to) : replyTo.isEmpty ? sender : replyTo
    var cc: [Address] = []
    if all {
        for a in parseAddresses(m.to) + parseAddresses(m.cc) {
            let e = a.email.lowercased()
            if !mineL.contains(e), !to.contains(where: { $0.email.lowercased() == e }), !cc.contains(where: { $0.email.lowercased() == e }) {
                cc.append(a)
            }
        }
    }
    var d = Draft(from: me, account: me)
    d.to = to.map(\.formatted).joined(separator: ", ")
    d.cc = cc.map(\.formatted).joined(separator: ", ")
    d.subject = replySubject(m.subject)
    d.inReplyTo = m.messageIdHeader
    d.references = (m.references + " " + m.messageIdHeader).trimmingCharacters(in: .whitespaces)
    d.threadId = m.threadId
    d.quoted = quoted(m)
    return d
}

public func forwardDraft(of m: Message, me: String) -> Draft {
    var d = Draft(from: me)
    d.subject = forwardSubject(m.subject)
    d.quoted = "\n\n---------- Forwarded message ---------\nFrom: \(m.from)\nDate: \(m.date)\nSubject: \(m.subject)\nTo: \(m.to)\n\n" + m.plainText
    return d
}

// MARK: OAuth helpers

public func pkceChallenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

/// Pulls query params out of the raw HTTP request line Google redirects to.
public func queryItems(fromRequest req: String) -> [String: String] {
    guard let line = req.components(separatedBy: "\r\n").first, line.hasPrefix("GET ") else { return [:] }
    let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    var out: [String: String] = [:]
    for q in URLComponents(string: "http://x" + path)?.queryItems ?? [] { out[q.name] = q.value ?? "" }
    return out
}

/// The sender designed a dark version (a prefers-color-scheme: dark style, or a color-scheme that includes dark).
public func emailHasOwnDarkMode(_ html: String) -> Bool {
    let h = html.lowercased()
    if h.range(of: #"prefers-color-scheme\s*:\s*dark"#, options: .regularExpression) != nil { return true }
    if h.range(of: #"<meta[^>]+name=["']?(supported-)?color-scheme["']?[^>]+content=["'][^"']*dark"#, options: .regularExpression) != nil { return true }
    return h.range(of: #"color-scheme\s*:\s*[^;"'}]*dark"#, options: .regularExpression) != nil
}
