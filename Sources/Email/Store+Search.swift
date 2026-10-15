import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Search


    /// Backspace in an empty search bar: drop the most recently shown chip (words, then filters, dates, subject, people).
    func removeLastSearchToken() {
        if !search.words.isEmpty { search.words = "" }
        else if search.unreadOnly { search.unreadOnly = false }
        else if search.hasAttachment { search.hasAttachment = false }
        else if search.after != nil || search.before != nil { search.after = nil; search.before = nil }
        else if !search.subject.isEmpty { search.subject = "" }
        else if !search.to.isEmpty { search.to = "" }
        else if !search.from.isEmpty { search.from = "" }
        if search.isEmpty { searchResults = nil; folder = nil; selectedID = nil; threadOpen = false } else { runSearch() }
        searchOpen = true
    }

    /// Words from the search box plus any filters (person, subject, dates, attachment, unread).
    func runSearch() {
        // Text left in the box becomes a "words" chip, joining whatever's already locked in.
        let typed = searchText.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { search = apply(.words(typed), to: search); searchText = "" }
        guard !search.isEmpty else { return }
        searchFiltersOpen = false
        runQuery(gmailQuery(search), title: "Search: " + search.chips.joined(separator: " · "), local: search)
    }

    func goFolder(_ name: String) {
        switch name {
        case "Inbox": goTab(importantTab)
        case "Starred": runQuery("is:starred", title: name)
        case "Sent": runQuery("in:sent", title: name)
        case "Done": runQuery("-in:inbox -in:sent -in:spam -in:trash -in:draft", title: name)
        case "Drafts": runQuery("in:drafts", title: name)
        case "Spam": runQuery("in:spam", title: name)
        case "Trash": runQuery("in:trash", title: name)
        case "Scheduled": openPalette("cancel scheduled")
        case "Muted", "Auto Archived":
            folder = name; searchOpen = false; threadOpen = false; selectedID = nil
            searchResults = Set(name == "Muted" ? state.muted : state.autoArchived)
        case "Snippets": openSettings()
        case "Reminders":
            folder = name; searchOpen = false; threadOpen = false; selectedID = nil
            searchResults = Set(state.snoozes.map(\.conversationId))
            Task {
                for s in state.snoozes where isGmail(s.account) && !messages.values.contains(where: { $0.account == s.account && $0.threadId == s.threadId }) {
                    for m in (try? await gmail(s.account).thread(s.threadId)) ?? [] { messages[m.key] = m }
                }
            }
        default: break
        }
    }

    func runQuery(_ q: String, title: String, local: SearchQuery? = nil) {
        folder = title
        Task {
            busy = "Searching…"
            var ids: Set<String> = []
            for a in state.accounts where state.activeAccount == nil || state.activeAccount == a {
                if !isGmail(a) {
                    // No Gmail search on iCloud or Microsoft (yet): search what's cached locally.
                    let words = q.lowercased().split(separator: " ").map(String.init)
                    for m in messages.values where m.account == a {
                        let hay = (m.from + " " + m.to + " " + m.subject + " " + m.plainText).lowercased()
                        let hit: Bool
                        if let local { hit = matchesSearch(m, local) }
                        else if q == "is:starred" { hit = m.labelIds.contains("STARRED") }
                        else if q.hasPrefix("-in:inbox") || q == "in:sent" { hit = false } // folders iCloud's cache doesn't have
                        else { hit = words.allSatisfy { hay.contains($0) } }
                        if hit { ids.insert(a + "|" + m.threadId) }
                    }
                    continue
                }
                do {
                    let g = gmail(a)
                    let found = try await g.listIds(q, max: 50)
                    let missing = found.filter { messages["\(a)|\($0)"] == nil }
                    for m in await g.messages(missing) { messages[m.key] = m }
                    for id in found { if let m = messages["\(a)|\(id)"] { ids.insert(a + "|" + m.threadId) } }
                } catch { report(error) }
            }
            busy = nil
            searchResults = ids; selectedID = nil; threadOpen = false
        }
    }

    func clearSearch() {
        searchOpen = false; searchFiltersOpen = false; searchText = ""; search = SearchQuery()
        searchResults = nil; folder = nil; selectedID = nil; threadOpen = false
    }
}
