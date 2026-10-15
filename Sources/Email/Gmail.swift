import AppKit
import Foundation
import Network
import Security
import EmailCore
import CryptoKit

// MARK: Gmail REST API

/// Labels Keymail creates for itself (snooze); never shown as label chips inside the app.
func isAppLabel(_ name: String) -> Bool { name.hasPrefix("Keymail/") || name.hasPrefix("Email/") }

struct Gmail {
    let account: String
    let auth: GoogleAuth

    /// Waits and retries when Gmail says "slow down" (429, or 403 rate/quota errors): 2s, 4s, 8s, 16s.
    func call(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do { return try await callOnce(path, method: method, query: query, json: json) }
            // Rate limits and Google's temporary 5xx errors: wait 2s, 4s, 8s, 16s and retry.
            catch let e as HTTPError where attempt < 4 && e.isTransient {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
    }

    private func callOnce(_ path: String, method: String, query: [URLQueryItem], json: [String: Any]?, retry: Bool = true) async throws -> [String: Any] {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken(for: account))", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await GoogleNet.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retry {
            await auth.invalidate(account)
            return try await callOnce(path, method: method, query: query, json: json, retry: false)
        }
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func listIds(_ q: String, max: Int) async throws -> [String] {
        var ids: [String] = [], page: String?
        repeat {
            var query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "maxResults", value: "100")]
            // Gmail leaves spam and trash out of results unless asked.
            if q.contains("in:spam") || q.contains("in:trash") { query.append(.init(name: "includeSpamTrash", value: "true")) }
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let j = try await call("messages", query: query)
            ids += (j["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            page = j["nextPageToken"] as? String
        } while page != nil && ids.count < max
        return Array(ids.prefix(max))
    }

    /// Fetches full messages 8 at a time. Messages that fail (e.g. deleted meanwhile) are skipped.
    func messages(_ ids: [String]) async -> [Message] {
        var out: [Message] = []
        for chunk in stride(from: 0, to: ids.count, by: 8).map({ Array(ids[$0..<min($0 + 8, ids.count)]) }) {
            await withTaskGroup(of: Message?.self) { g in
                for id in chunk {
                    g.addTask { (try? await call("messages/\(id)", query: [.init(name: "format", value: "full")])).flatMap { parseMessage($0, account: account) } }
                }
                for await m in g { if let m { out.append(m) } }
            }
        }
        return out
    }

    func thread(_ id: String) async throws -> [Message] {
        let j = try await call("threads/\(id)", query: [.init(name: "format", value: "full")])
        return (j["messages"] as? [[String: Any]] ?? []).compactMap { parseMessage($0, account: account) }
    }

    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        _ = try await call("threads/\(id)/modify", method: "POST", json: ["addLabelIds": add, "removeLabelIds": remove])
    }

    func trashThread(_ id: String) async throws { _ = try await call("threads/\(id)/trash", method: "POST") }
    func untrashThread(_ id: String) async throws { _ = try await call("threads/\(id)/untrash", method: "POST") }

    /// Gmail's upload endpoint (35 MB limit) with JSON metadata + the raw message. Used for send and drafts.
    private func upload(_ path: String, method: String = "POST", meta: [String: Any], raw: Data) async throws -> [String: Any] {
        let boundary = "email_" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += try JSONSerialization.data(withJSONObject: meta)
        body += Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8)
        body += raw
        body += Data("\r\n--\(boundary)--".utf8)
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/\(path)?uploadType=multipart")!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken(for: account))", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await GoogleNet.session.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func send(_ d: Draft) async throws -> [String: Any] {
        var meta: [String: Any] = [:]
        if let t = d.threadId { meta["threadId"] = t }
        return try await upload("messages/send", meta: meta, raw: Data(buildRaw(d).utf8))
    }

    /// Creates or updates a Gmail draft; returns its draft id.
    func saveDraft(_ d: Draft) async throws -> String {
        var message: [String: Any] = [:]
        if let t = d.threadId { message["threadId"] = t }
        let raw = Data(buildRaw(d).utf8)
        if let id = d.draftId {
            do { return try await upload("drafts/\(id)", method: "PUT", meta: ["id": id, "message": message], raw: raw)["id"] as? String ?? id }
            catch let e as HTTPError where e.status == 404 { /* deleted elsewhere: fall through and recreate */ }
        }
        return try await upload("drafts", meta: ["message": message], raw: raw)["id"] as? String ?? ""
    }

    func deleteDraft(_ id: String) async throws { _ = try await call("drafts/\(id)", method: "DELETE") }

    /// Message id → draft id, so opening a draft from the Drafts folder edits the same draft.
    func draftIds() async throws -> [String: String] {
        var out: [String: String] = [:], page: String?
        repeat {
            var q = [URLQueryItem(name: "maxResults", value: "100")]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            let j = try await call("drafts", query: q)
            for d in j["drafts"] as? [[String: Any]] ?? [] {
                if let id = d["id"] as? String, let mid = (d["message"] as? [String: Any])?["id"] as? String { out[mid] = id }
            }
            page = j["nextPageToken"] as? String
        } while page != nil
        return out
    }

    func attachment(message: String, id: String) async throws -> Data {
        let j = try await call("messages/\(message)/attachments/\(id)")
        guard let d = (j["data"] as? String).flatMap(base64urlDecode) else { throw AppError("Couldn't download the attachment.") }
        return d
    }

    func historyId() async throws -> String { try await call("profile")["historyId"] as? String ?? "" }

    /// Returns nil when Google says the history id is too old (needs a full resync).
    func history(since start: String) async throws -> (pages: [[String: Any]], latest: String)? {
        var pages: [[String: Any]] = [], page: String?, latest = start
        repeat {
            var q = [URLQueryItem(name: "startHistoryId", value: start)]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            do {
                let j = try await call("history", query: q)
                pages.append(j); page = j["nextPageToken"] as? String
                latest = j["historyId"] as? String ?? latest
            } catch let e as HTTPError where e.status == 404 { return nil }
        } while page != nil
        return (pages, latest)
    }

    // MARK: Settings: out of office, send-as signatures, labels

    /// One Keymail-made filter per sender or domain: "always" or "never mark as important". Replaces an earlier one.
    func setImportanceFilter(from: String, important: Bool) async throws {
        let filters = try await call("settings/filters")["filter"] as? [[String: Any]] ?? []
        for f in filters where ((f["criteria"] as? [String: Any])?["from"] as? String)?.lowercased() == from.lowercased() {
            let action = f["action"] as? [String: Any] ?? [:]
            let labels = (action["addLabelIds"] as? [String] ?? []) + (action["removeLabelIds"] as? [String] ?? [])
            if labels == ["IMPORTANT"], let id = f["id"] as? String { _ = try await call("settings/filters/\(id)", method: "DELETE") }
        }
        _ = try await call("settings/filters", method: "POST", json: [
            "criteria": ["from": from],
            "action": important ? ["addLabelIds": ["IMPORTANT"]] : ["removeLabelIds": ["IMPORTANT"]],
        ])
    }

    func vacation() async throws -> Vacation { Vacation(json: try await call("settings/vacation")) }
    func setVacation(_ v: Vacation) async throws { _ = try await call("settings/vacation", method: "PUT", json: v.json) }

    struct SendAs: Identifiable { var id: String { email }; let email: String, name: String, signature: String, isPrimary: Bool }
    func sendAs() async throws -> [SendAs] {
        (try await call("settings/sendAs")["sendAs"] as? [[String: Any]] ?? []).compactMap { j in
            guard let e = j["sendAsEmail"] as? String else { return nil }
            return SendAs(email: e, name: j["displayName"] as? String ?? "", signature: j["signature"] as? String ?? "",
                          isPrimary: j["isPrimary"] as? Bool ?? false)
        }
    }
    func setSignature(_ address: String, html: String) async throws {
        let path = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        _ = try await call("settings/sendAs/\(path)", method: "PATCH", json: ["signature": html])
    }

    struct Label: Identifiable, Hashable { let id: String; var name: String; var bg: String?; var text: String? }
    func userLabels() async throws -> [Label] {
        (try await call("labels")["labels"] as? [[String: Any]] ?? []).compactMap { l in
            guard l["type"] as? String == "user", let id = l["id"] as? String, let name = l["name"] as? String else { return nil }
            let c = l["color"] as? [String: Any]
            return Label(id: id, name: name, bg: c?["backgroundColor"] as? String, text: c?["textColor"] as? String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func createLabel(_ name: String) async throws {
        _ = try await call("labels", method: "POST", json: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
    }
    func updateLabel(_ id: String, name: String? = nil, color: (bg: String, text: String)? = nil) async throws {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let color { body["color"] = ["backgroundColor": color.bg, "textColor": color.text] }
        _ = try await call("labels/\(id)", method: "PATCH", json: body)
    }
    func deleteLabel(_ id: String) async throws { _ = try await call("labels/\(id)", method: "DELETE") }

    func labels() async throws -> [String: String] {
        let j = try await call("labels")
        var out: [String: String] = [:]
        for l in j["labels"] as? [[String: Any]] ?? [] where l["type"] as? String == "user" {
            if let id = l["id"] as? String, let name = l["name"] as? String { out[id] = name }
        }
        return out
    }

    /// The hidden Gmail label snoozed threads wear while out of the inbox. Users can see it on those emails in
    /// Gmail itself, so it carries the app's name. Older builds used "Email/Snoozed": that label is renamed in
    /// place, so threads already snoozed keep it.
    static let snoozeLabel = "Keymail/Snoozed", legacySnoozeLabels = ["Email/Snoozed"]
    func snoozeLabelId(existing: [String: String]) async throws -> String {
        if let id = existing.first(where: { $0.value == Self.snoozeLabel })?.key { return id }
        if let old = existing.first(where: { Self.legacySnoozeLabels.contains($0.value) })?.key {
            try await updateLabel(old, name: Self.snoozeLabel)
            return old
        }
        return try await labelId(named: Self.snoozeLabel, existing: existing)
    }

    func labelId(named name: String, existing: [String: String]) async throws -> String {
        if let id = existing.first(where: { $0.value == name })?.key { return id }
        return try await call("labels", method: "POST", json: ["name": name, "labelListVisibility": "labelHide"])["id"] as? String ?? ""
    }
}
