import Foundation

// MARK: Microsoft (Outlook.com, Hotmail, Microsoft 365) via Microsoft Graph

/// The account's email address from Graph's `/me` profile. Work accounts fill `mail`; personal Outlook.com
/// accounts often leave it empty and only have `userPrincipalName`. Guest sign-in names like
/// "bob_gmail.com#EXT#@contoso.onmicrosoft.com" aren't real mailboxes, so they're rejected.
public func microsoftAccountEmail(profile: [String: Any]) -> String? {
    for key in ["mail", "userPrincipalName"] {
        if let v = (profile[key] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
           v.contains("@"), !v.contains("#ext#") { return v }
    }
    return nil
}

/// Microsoft's sign-in errors in plain words. Codes from the `error_description` text (AADSTS…).
public func friendlyMicrosoftSignInError(_ description: String?) -> String {
    let d = description ?? ""
    if d.contains("AADSTS65001") || d.contains("AADSTS90094") || d.contains("AADSTS65004") {
        return "Your organization needs an administrator to approve Keymail before you can sign in. Ask your IT team."
    }
    if d.contains("AADSTS50020") { return "This Microsoft account can't sign in to Keymail. Try a different account." }
    if d.contains("AADSTS70008") || d.contains("AADSTS700082") || d.contains("AADSTS50173") {
        return "Your Microsoft sign-in expired. Add the account again in Settings → Accounts."
    }
    if d.contains("AADSTS50126") || d.contains("AADSTS50034") { return "Microsoft didn't recognize that account. Try again." }
    return "Microsoft sign-in didn't finish. Try again in a moment."
}

/// Fields Keymail asks Graph for when listing a folder: enough for the inbox row and threading, no body.
public let graphListFields = "id,conversationId,from,toRecipients,ccRecipients,replyTo,subject,bodyPreview,receivedDateTime,isRead,flag,inferenceClassification,internetMessageId,hasAttachments,isDraft"
/// Extra fields for a full message: the body and the raw headers (for unsubscribe and the spoofing check).
public let graphBodyFields = "body,internetMessageHeaders"

/// Graph's {"emailAddress":{"name","address"}} as "Name <address>", the header form the rest of the app reads.
func graphAddress(_ any: Any?) -> String? {
    guard let ea = (any as? [String: Any])?["emailAddress"] as? [String: Any],
          let address = (ea["address"] as? String)?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return nil }
    let name = (ea["name"] as? String ?? "").replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
    return name.isEmpty || name.lowercased() == address.lowercased() ? address : "\"\(name)\" <\(address)>"
}
func graphAddresses(_ any: Any?) -> String { ((any as? [Any]) ?? []).compactMap(graphAddress).joined(separator: ", ") }

/// A Graph message as Keymail's Message. Folders and flags map onto the same labels Gmail uses, so everything
/// built on labels (unread dots, stars, Important/Other, Split Inbox) works unchanged:
///   in Inbox → INBOX · not read → UNREAD · flagged → STARRED · Focused (Microsoft's own sorting) → IMPORTANT.
public func messageFromGraph(_ j: [String: Any], account: String, inInbox: Bool) -> Message? {
    guard let id = j["id"] as? String, let thread = j["conversationId"] as? String else { return nil }
    var labels: [String] = []
    if inInbox { labels.append("INBOX") }
    if j["isRead"] as? Bool == false { labels.append("UNREAD") }
    if ((j["flag"] as? [String: Any])?["flagStatus"] as? String) == "flagged" { labels.append("STARRED") }
    if (j["inferenceClassification"] as? String) == "focused" { labels.append("IMPORTANT") }
    if j["isDraft"] as? Bool == true { labels.append("DRAFT") }
    let date = (j["receivedDateTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    var m = Message(id: id, threadId: thread, account: account, from: graphAddress(j["from"]) ?? "",
                    to: graphAddresses(j["toRecipients"]), cc: graphAddresses(j["ccRecipients"]),
                    subject: (j["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)",
                    snippet: (j["bodyPreview"] as? String ?? "").replacingOccurrences(of: "\r\n", with: " "),
                    date: date, labelIds: labels, messageIdHeader: j["internetMessageId"] as? String ?? "")
    let replyTo = graphAddresses(j["replyTo"])
    if !replyTo.isEmpty { m.replyTo = replyTo }
    if let body = j["body"] as? [String: Any], let content = body["content"] as? String {
        if (body["contentType"] as? String)?.lowercased() == "html" { m.html = content } else { m.text = content }
    }
    // Raw headers arrive top to bottom, so the first Authentication-Results is the one Microsoft's server added.
    var first: [String: String] = [:]
    for h in (j["internetMessageHeaders"] as? [[String: Any]]) ?? [] {
        if let n = (h["name"] as? String)?.lowercased(), let v = h["value"] as? String, first[n] == nil { first[n] = v }
    }
    m.listUnsubscribe = first["list-unsubscribe"] ?? ""
    m.listUnsubscribePost = first["list-unsubscribe-post"] != nil
    m.references = first["references"] ?? ""
    m.authFailed = authenticationFailed(first["authentication-results"])
    return m
}

/// Graph attachment metadata as Keymail's AttachmentRef. Inline images keep their Content-ID so `cid:` works.
public func attachmentFromGraph(_ j: [String: Any]) -> AttachmentRef? {
    guard let id = j["id"] as? String, (j["@odata.type"] as? String ?? "#microsoft.graph.fileAttachment") == "#microsoft.graph.fileAttachment" else { return nil }
    let cid = (j["contentId"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    return AttachmentRef(id: id, name: j["name"] as? String ?? "attachment", mimeType: (j["contentType"] as? String ?? "application/octet-stream").lowercased(),
                         size: j["size"] as? Int ?? 0, contentId: (j["isInline"] as? Bool == true && cid?.isEmpty == false) ? cid : nil)
}
