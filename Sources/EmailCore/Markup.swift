import Foundation

/// Formatting from the compose box, kept inside the plain-text body so drafts, AI, snippets and agents keep working
/// with a String: **bold**, *italic* and [text](https://link). A star only counts when it hugs a word and has a
/// partner later on the same line, so "5 * 3" or a lone "*" stays as typed.
public enum Markup {
    public struct Span: Equatable {
        public var range: NSRange          // UTF-16, into the text without markers
        public var bold = false, italic = false
        public var link: String?
        public init(range: NSRange, bold: Bool = false, italic: Bool = false, link: String? = nil) {
            self.range = range; self.bold = bold; self.italic = italic; self.link = link
        }
        func sameStyle(_ o: Span) -> Bool { bold == o.bold && italic == o.italic && link == o.link }
    }

    public static func has(_ s: String) -> Bool { s.contains("*") || s.contains("](") ? !parse(s).spans.isEmpty : false }

    /// The text without markers, plus how each stretch of it is formatted (unformatted stretches have no span).
    public static func parse(_ s: String) -> (text: String, spans: [Span]) {
        let c = Array(s)
        var out = "", spans: [Span] = []
        var bold = false, italic = false, link: String?, linkEnd = 0, linkClose = 0
        func ws(_ i: Int) -> Bool { i < 0 || i >= c.count || c[i].isWhitespace }
        func stars(at i: Int) -> Int { i + 1 < c.count && c[i + 1] == "*" ? 2 : 1 }
        // A closing run of `n` stars later on this line, right after a non-space.
        func closer(after i: Int, _ n: Int) -> Bool {
            var j = i
            while j < c.count, c[j] != "\n" {
                if c[j] == "*", !ws(j - 1), n == 1 || (j + 1 < c.count && c[j + 1] == "*") { return true }
                j += 1
            }
            return false
        }
        // [text](scheme:url) starting at i: where the text ends, the URL, and the closing parenthesis.
        func linkAt(_ i: Int) -> (end: Int, url: String, close: Int)? {
            guard let j = c[(i + 1)...].firstIndex(where: { $0 == "]" || $0 == "\n" }), c[j] == "]", j > i + 1,
                  j + 1 < c.count, c[j + 1] == "(",
                  let k = c[(j + 2)...].firstIndex(where: { $0 == ")" || $0.isWhitespace }), c[k] == ")" else { return nil }
            let url = String(c[(j + 2)..<k])
            guard ["http://", "https://", "mailto:"].contains(where: { url.lowercased().hasPrefix($0) }), url.count > 8 else { return nil }
            return (j, url, k)
        }
        func emit(_ ch: Character) {
            let span = Span(range: NSRange(location: out.utf16.count, length: ch.utf16.count), bold: bold, italic: italic, link: link)
            out.append(ch)
            guard bold || italic || link != nil else { return }
            if let last = spans.last, last.sameStyle(span), NSMaxRange(last.range) == span.range.location {
                spans[spans.count - 1].range.length += span.range.length
            } else { spans.append(span) }
        }
        var i = 0
        while i < c.count {
            if link != nil, i == linkEnd { link = nil; i = linkClose + 1; continue }
            if link == nil, c[i] == "[", let l = linkAt(i) { link = l.url; linkEnd = l.end; linkClose = l.close; i += 1; continue }
            if c[i] == "\n" { bold = false; italic = false }
            if c[i] == "*" {
                let n = stars(at: i)
                if n == 2, bold, !ws(i - 1) { bold = false; i += 2; continue }
                if n == 2, !bold, !ws(i + 2), c[i + 2] != "*" || !ws(i + 3), closer(after: i + 2, 2) { bold = true; i += 2; continue }
                if n == 2 { emit("*"); emit("*"); i += 2; continue }   // an unmatched "**" is just two stars
                if italic, !ws(i - 1) { italic = false; i += 1; continue }
                if !italic, !ws(i + 1), closer(after: i + 1, 1) { italic = true; i += 1; continue }
            }
            emit(c[i]); i += 1
        }
        return (out, spans)
    }

    /// The reverse of `parse`: markers around each formatted stretch. Styles close before a line break and never
    /// start or end on a space, so what this writes always parses back the same.
    public static func render(_ text: String, _ spans: [Span]) -> String {
        var out = "", pos = 0
        var cur = Span(range: NSRange()), si = 0
        let chars = Array(text)
        func style(at p: Int) -> Span {
            while si < spans.count, NSMaxRange(spans[si].range) <= p { si += 1 }
            if si < spans.count, spans[si].range.location <= p { return spans[si] }
            return Span(range: NSRange())
        }
        func close() {
            if cur.italic { out += "*" }
            if cur.bold { out += "**" }
            cur.bold = false; cur.italic = false
        }
        var styles = [Span]()
        for ch in chars { styles.append(style(at: pos)); pos += ch.utf16.count }
        for (n, ch) in chars.enumerated() {
            var want = ch == "\n" ? Span(range: NSRange()) : styles[n]
            if ch.isWhitespace {   // a space stays inside bold/italic only when the next character continues it
                let next = n + 1 < chars.count && chars[n + 1] != "\n" ? styles[n + 1] : Span(range: NSRange())
                let same = next.link == want.link && cur.link == want.link
                want.bold = want.bold && cur.bold && next.bold && same
                want.italic = want.italic && cur.italic && next.italic && same
            }
            if want.link != cur.link {
                close()
                if let l = cur.link { out += "](\(l))" }
                if want.link != nil { out += "[" }
                cur.link = want.link
            }
            if cur.italic, !want.italic { out += "*"; cur.italic = false }
            if cur.bold, !want.bold { out += "**"; cur.bold = false }
            if !cur.bold, want.bold { out += "**"; cur.bold = true }
            if !cur.italic, want.italic { out += "*"; cur.italic = true }
            out.append(ch)
        }
        close()
        if let l = cur.link { out += "](\(l))" }
        return out
    }

    /// For the plain-text part of an email: no stars, and a link reads "text (url)".
    public static func toPlain(_ s: String) -> String {
        guard has(s) else { return s }
        let (text, spans) = parse(s)
        let ns = NSMutableString(string: text)
        for (range, url) in links(spans).reversed() {
            let label = ns.substring(with: range)
            if label == url || "mailto:" + label == url { continue }
            ns.insert(" (\(url.hasPrefix("mailto:") ? String(url.dropFirst(7)) : url))", at: NSMaxRange(range))
        }
        return ns as String
    }

    /// For the HTML part: <b>, <i> and <a>, with plain web addresses still made clickable.
    public static func toHTML(_ s: String) -> String {
        let (text, spans) = parse(s)
        let ns = text as NSString
        var html = "", pos = 0
        func plain(_ end: Int) {
            if end > pos { html += linkify(escapeHTML(ns.substring(with: NSRange(location: pos, length: end - pos)))) }
        }
        for sp in spans {
            plain(sp.range.location)
            var part = escapeHTML(ns.substring(with: sp.range))
            if sp.link == nil { part = linkify(part) }
            if sp.italic { part = "<i>\(part)</i>" }
            if sp.bold { part = "<b>\(part)</b>" }
            if let l = sp.link { part = "<a href=\"\(escapeHTML(l))\">\(part)</a>" }
            html += part
            pos = NSMaxRange(sp.range)
        }
        plain(ns.length)
        return html.replacingOccurrences(of: "\n", with: "<br>\n")
    }

    /// Each link once, even when part of its text is bold.
    static func links(_ spans: [Span]) -> [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        for sp in spans {
            guard let l = sp.link else { continue }
            if let last = out.last, last.1 == l, NSMaxRange(last.0) == sp.range.location {
                out[out.count - 1].0.length += sp.range.length
            } else { out.append((sp.range, l)) }
        }
        return out
    }
}
