import Foundation

// MARK: Auto Archive

public enum AutoArchiveCategory: String, Codable, CaseIterable, Identifiable {
    case newsletters = "Newsletters & marketing", promotions = "Gmail Promotions tab", social = "Social notifications"
    public var id: String { rawValue }
}

/// Which auto-archive bucket a message falls in, if any. Starred mail is never auto-archived.
public func autoArchiveCategory(_ m: Message) -> AutoArchiveCategory? {
    if m.labelIds.contains("STARRED") { return nil }
    if m.labelIds.contains("CATEGORY_PROMOTIONS") { return .promotions }
    if m.labelIds.contains("CATEGORY_SOCIAL") { return .social }
    if !m.listUnsubscribe.isEmpty { return .newsletters }
    return nil
}
