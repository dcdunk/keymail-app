import Foundation

// MARK: Gmail settings: out of office (vacation responder)

public struct Vacation: Equatable {
    public var enabled = false
    public var subject = ""
    public var message = ""
    public var contactsOnly = false
    public var domainOnly = false
    public var start: Date?
    public var end: Date?
    public init() {}

    /// From Gmail's `users.settings.getVacation` response.
    public init(json j: [String: Any]) {
        enabled = j["enableAutoReply"] as? Bool ?? false
        subject = j["responseSubject"] as? String ?? ""
        message = (j["responseBodyPlainText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (j["responseBodyHtml"] as? String).map(plainFromHTML) ?? ""
        contactsOnly = j["restrictToContacts"] as? Bool ?? false
        domainOnly = j["restrictToDomain"] as? Bool ?? false
        func date(_ k: String) -> Date? {
            (j[k] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        start = date("startTime"); end = date("endTime")
    }

    /// Body for `users.settings.updateVacation`. Gmail wants times as millisecond strings.
    public var json: [String: Any] {
        var j: [String: Any] = ["enableAutoReply": enabled, "responseSubject": subject,
                                "responseBodyPlainText": message, "responseBodyHtml": plainToHTML(message),
                                "restrictToContacts": contactsOnly, "restrictToDomain": domainOnly]
        if let s = start { j["startTime"] = String(Int64(s.timeIntervalSince1970 * 1000)) }
        if let e = end { j["endTime"] = String(Int64(e.timeIntervalSince1970 * 1000)) }
        return j
    }

    /// On right now: enabled and inside the date window (if any).
    public func isActive(at now: Date = Date()) -> Bool {
        enabled && (start.map { now >= $0 } ?? true) && (end.map { now <= $0 } ?? true)
    }
}

/// Gmail's allowed label colors (background, text). Gmail rejects colors outside its palette.
public let gmailLabelColors: [(bg: String, text: String)] = [
    ("#fb4c2f", "#ffffff"), ("#ffad47", "#ffffff"), ("#fad165", "#000000"), ("#16a766", "#ffffff"),
    ("#43d692", "#000000"), ("#4a86e8", "#ffffff"), ("#a479e2", "#ffffff"), ("#f691b3", "#000000"), ("#666666", "#ffffff"),
]

/// Gmail stores signatures as HTML and drops embedded (data:) images; those need a hosted https:// image.
public func gmailSignatureProblem(_ html: String) -> String? {
    html.contains("data:image") ? "Gmail can't store a logo embedded in the signature. Host the image online and use its https:// address in the HTML, then sync again." : nil
}
