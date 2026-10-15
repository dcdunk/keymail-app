import Foundation

/// Converts a Gmail API `users.messages.get?format=full` JSON object into a Message.
public func parseMessage(_ j: [String: Any], account: String) -> Message? {
    guard let id = j["id"] as? String, let threadId = j["threadId"] as? String else { return nil }
    let payload = j["payload"] as? [String: Any] ?? [:]
    var headers: [String: String] = [:], authResults: [String] = []
    for h in payload["headers"] as? [[String: Any]] ?? [] {
        guard let n = h["name"] as? String, let v = h["value"] as? String else { continue }
        let key = n.lowercased()
        if key == "authentication-results" { authResults.append(v) }
        if headers[key] == nil { headers[key] = v } // first wins: later duplicates are the sender's, not the server's
    }
    var html: String?, text: String?, calendar: String?
    var files: [AttachmentRef] = []
    var embedded: [String: String] = [:]   // content id → data URL, for small images Gmail sends inside the message
    func walk(_ p: [String: Any]) {
        let mime = (p["mimeType"] as? String ?? "").lowercased()
        let filename = p["filename"] as? String ?? ""
        var partHeaders: [String: String] = [:]
        for h in p["headers"] as? [[String: Any]] ?? [] {
            if let n = h["name"] as? String, let v = h["value"] as? String { partHeaders[n.lowercased()] = v }
        }
        let cid = partHeaders["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        let body = p["body"] as? [String: Any] ?? [:]
        let isText = mime.hasPrefix("text/") && filename.isEmpty
        if !isText, !mime.hasPrefix("multipart/") {
            if let attId = body["attachmentId"] as? String {
                // Inline logos often have no file name; they still count.
                let name = filename.isEmpty ? (cid.map { "image-\($0.prefix(8))" } ?? "attachment") : filename
                files.append(AttachmentRef(id: attId, name: name, mimeType: mime, size: body["size"] as? Int ?? 0, contentId: cid))
            } else if let cid, let data = body["data"] as? String, let bytes = base64urlDecode(data) {
                embedded[cid] = "data:\(mime);base64,\(bytes.base64EncodedString())"
            }
        }
        if isText, let data = body["data"] as? String,
           let decoded = base64urlDecode(data).flatMap({ String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }) {
            if mime == "text/html", html == nil { html = decoded }
            if mime == "text/plain", text == nil { text = decoded }
            if mime == "text/calendar", calendar == nil { calendar = decoded }
        }
        for child in p["parts"] as? [[String: Any]] ?? [] { walk(child) }
    }
    walk(payload)
    if let h = html { html = inlineImages(h, embedded) }
    // A part is "inline" when the HTML actually shows it, whatever its Content-Disposition says.
    files = files.map { f in
        var f = f
        if let c = f.contentId, !(html?.contains("cid:" + c) ?? false) { f.contentId = nil }
        return f
    }
    let ms = Double(j["internalDate"] as? String ?? "") ?? 0
    var msg = Message(id: id, threadId: threadId, account: account,
                   from: headers["from"] ?? "", to: headers["to"] ?? "", cc: headers["cc"] ?? "",
                   subject: headers["subject"] ?? "(no subject)", snippet: decodeEntities(j["snippet"] as? String ?? ""),
                   date: Date(timeIntervalSince1970: ms / 1000), labelIds: j["labelIds"] as? [String] ?? [],
                   messageIdHeader: headers["message-id"] ?? "", references: headers["references"] ?? "",
                   listUnsubscribe: headers["list-unsubscribe"] ?? "",
                   listUnsubscribePost: headers["list-unsubscribe-post"] != nil, html: html, text: text, attachments: files)
    msg.replyTo = headers["reply-to"]
    msg.calendar = calendar
    msg.authFailed = authenticationFailed(providerAuthResults(authResults, server: "mx.google.com"))
    return msg
}

public struct HistoryDelta {
    public var changed: [String: (threadId: String, labels: [String])] = [:]
    public var deleted: Set<String> = []
}

/// Folds `users.history.list` pages (in order) into the latest known state per message.
public func parseHistory(_ pages: [[String: Any]]) -> HistoryDelta {
    var d = HistoryDelta()
    for page in pages {
        for rec in page["history"] as? [[String: Any]] ?? [] {
            for key in ["messagesAdded", "labelsAdded", "labelsRemoved"] {
                for item in rec[key] as? [[String: Any]] ?? [] {
                    guard let m = item["message"] as? [String: Any], let id = m["id"] as? String else { continue }
                    d.changed[id] = (m["threadId"] as? String ?? "", m["labelIds"] as? [String] ?? [])
                    d.deleted.remove(id)
                }
            }
            for item in rec["messagesDeleted"] as? [[String: Any]] ?? [] {
                if let id = (item["message"] as? [String: Any])?["id"] as? String { d.deleted.insert(id); d.changed[id] = nil }
            }
        }
    }
    return d
}
