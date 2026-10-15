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
