import Foundation
import EmailCore

/// Microsoft Graph mail client for one account (Outlook.com, Hotmail, Microsoft 365).
struct GraphMail {
    let account: String
    let auth: MicrosoftAuth
    static let base = "https://graph.microsoft.com/v1.0/me"

    /// One call with the account's token. Asks for immutable IDs so a message keeps its ID when it moves between
    /// folders (archive, delete, undo all rely on that). Waits and retries when Microsoft says "slow down".
    @discardableResult
    func call(_ pathOrURL: String, method: String = "GET", json: [String: Any]? = nil,
              raw: (body: Data, type: String)? = nil) async throws -> [String: Any] {
        let url = URL(string: pathOrURL.hasPrefix("https://") ? pathOrURL : Self.base + pathOrURL)!
        for attempt in 0..<4 {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(try await auth.accessToken(for: account))", forHTTPHeaderField: "Authorization")
            req.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
            } else if let raw {
                req.setValue(raw.type, forHTTPHeaderField: "Content-Type")
                req.httpBody = raw.body
            }
            let (data, resp) = try await GoogleNet.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { await auth.invalidate(account); continue }   // token went stale: refresh once
            if [429, 503, 504].contains(status), attempt < 3 {
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt + 1))
                try await Task.sleep(for: .seconds(min(wait, 30)))
                continue
            }
            guard (200..<300).contains(status) else {
                throw AppError(status == 403 ? "Microsoft didn't allow that for \(account)." : "Microsoft couldn't complete that (\(status)). Try again in a moment.")
            }
            return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        throw AppError("Microsoft is busy right now. Keymail will try again.")
    }

    /// Newest inbox messages from the last `days`, up to `limit`. Metadata only; bodies come from `message(_:)`.
    func inbox(days: Int = 30, limit: Int = 300) async throws -> [[String: Any]] {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86400))
        var next: String? = "/mailFolders/inbox/messages?$select=\(graphListFields)&$top=100&$orderby=receivedDateTime%20desc&$filter=receivedDateTime%20ge%20\(since)"
        var out: [[String: Any]] = []
        while let page = next, out.count < limit {
            let j = try await call(page)
            out += (j["value"] as? [[String: Any]]) ?? []
            next = j["@odata.nextLink"] as? String
        }
        return Array(out.prefix(limit))
    }

    /// A full message: body, raw headers, and its attachments' metadata.
    func message(_ id: String, inInbox: Bool) async throws -> Message? {
        let j = try await call("/messages/\(id)?$select=\(graphListFields),\(graphBodyFields)")
        guard var m = messageFromGraph(j, account: account, inInbox: inInbox) else { return nil }
        if j["hasAttachments"] as? Bool == true || (m.html?.contains("cid:") ?? false) {
            let a = try await call("/messages/\(id)/attachments?$select=id,name,contentType,size,isInline,contentId")
            m.attachments = ((a["value"] as? [[String: Any]]) ?? []).compactMap(attachmentFromGraph)
        }
        return m
    }

    func attachmentData(message: String, id: String) async throws -> Data {
        let j = try await call("/messages/\(message)/attachments/\(id)")
        guard let b64 = j["contentBytes"] as? String, let d = Data(base64Encoded: b64) else {
            throw AppError("That attachment couldn't be downloaded.")
        }
        return d
    }

    func setRead(_ id: String, _ read: Bool) async throws { try await call("/messages/\(id)", method: "PATCH", json: ["isRead": read]) }
    func setFlagged(_ id: String, _ on: Bool) async throws {
        try await call("/messages/\(id)", method: "PATCH", json: ["flag": ["flagStatus": on ? "flagged" : "notFlagged"]])
    }
    // MARK: Sending and drafts
    //
    // Microsoft takes a whole email in standard MIME form, base64-encoded: the same message Keymail builds for
    // Gmail, so signatures, inline logos, attachments, Cc/Bcc and reply threading all carry over unchanged.

    /// Graph caps a request at 4 MB, and base64 adds a third, so the email itself must stay under about 3 MB.
    static let maxMIMEBytes = 2_900_000

    /// Saves the email in Drafts. Returns its ID and the conversation it belongs to.
    func createDraft(mime: String) async throws -> (id: String, conversationId: String) {
        let bytes = Data(mime.utf8)
        guard bytes.count <= Self.maxMIMEBytes else {
            throw AppError("Attachments from Microsoft accounts can total about 2.5 MB for now. Remove some, or send a link instead.")
        }
        let j = try await call("/messages", method: "POST", raw: (Data(bytes.base64EncodedString().utf8), "text/plain"))
        guard let id = j["id"] as? String else { throw AppError("Microsoft didn't save the email. Try again.") }
        return (id, j["conversationId"] as? String ?? "")
    }

    /// Sends a saved draft. Microsoft files the copy in Sent Items.
    func sendDraft(_ id: String) async throws { try await call("/messages/\(id)/send", method: "POST") }

    func delete(_ id: String) async throws { try await call("/messages/\(id)", method: "DELETE") }

    /// Moves to a well-known folder: "inbox", "archive" or "deleteditems".
    func move(_ id: String, to folder: String) async throws { try await call("/messages/\(id)/move", method: "POST", json: ["destinationId": folder]) }
}
