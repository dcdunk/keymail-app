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
        // Hand the keyboard to the results: ↑↓ browse them, ← → open the side panels. Click the bar or press / to type again.
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    func goFolder(_ name: String) {
        switch name {
        case "Inbox": goTab(splitImportance ? importantTab : inboxTab)
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
        // Issue #4: Done used to sit on the previous email for ~10s while Gmail searched, looking empty.
        // Leave the email now and show archived mail already on this Mac at once; Gmail's results add to it.
        threadOpen = false; selectedID = nil
        let isDone = q.hasPrefix("-in:inbox")
        let localDone = isDone ? doneHere() : []
        // Empty right away, not the previous list: E on what looked like Starred archived an inbox email you never saw.
        // A search shows the matching mail already on this Mac at once; the server's results join as they arrive.
        let localHits = local.map { q in Set(allConversations.filter { c in
            (state.activeAccount == nil || c.account == state.activeAccount) && c.messages.contains { matchesSearch($0, q) } }.map(\.id)) } ?? []
        // Sent, Trash and the other folders show what's already on this Mac at once; the server only adds to it.
        let label = ["in:sent": "SENT", "is:starred": "STARRED", "in:trash": "TRASH", "in:spam": "SPAM", "in:drafts": "DRAFT"][q]
        let accounts = state.accounts.filter { state.activeAccount == nil || state.activeAccount == $0 }
        var found: [String: Set<String>] = [:]
        for a in accounts { found[a] = cachedHits(label, account: a) }
        func show() { searchResults = found.values.reduce(localHits) { $0.union($1) }.union(isDone ? doneHere() : localDone) }
        show()
        Task {
            busy = "Searching…"
            // Every account at once, each one's results shown as soon as it answers (one slow account used to hold up all).
            await withTaskGroup(of: (String, Set<String>?).self) { g in
                for a in accounts { g.addTask { await (a, self.serverHits(q, account: a, isDone: isDone, local: local)) } }
                for await (a, ids) in g {
                    guard let ids else { continue }
                    // Sent and Starred keep older cached mail past the server's newest 50; Trash, Spam and Drafts follow the server.
                    found[a] = label == "SENT" || label == "STARRED" ? ids.union(found[a] ?? []) : ids
                    if folder == title { show() }   // the person may have moved on while this searched
                }
            }
            busy = nil
        }
    }

    /// Conversations already on this Mac with `label` (SENT, TRASH…).
    func cachedHits(_ label: String?, account a: String) -> Set<String> {
        guard let label else { return [] }
        return Set(messages.values.filter { $0.account == a && $0.labelIds.contains(label) }.map { a + "|" + $0.threadId })
    }

    /// One account's results from its server. Nil when it couldn't be reached (what's cached stays on screen).
    func serverHits(_ q: String, account a: String, isDone: Bool, local: SearchQuery?) async -> Set<String>? {
        var ids: Set<String> = []
        if !isGmail(a), q == "in:sent" || q == "in:drafts" || q == "in:trash" || q == "in:spam" || isDone {
            // Sent, Drafts, Trash, Spam and Done read those folders on the server (iCloud, Yahoo, Outlook), then list
            // what's here. Drafts and Trash used to search the cache for the words "in:drafts"/"in:trash" and showed nothing.
            let box = isDone ? "archive" : ["in:drafts": "drafts", "in:trash": "trash", "in:spam": "junk"][q] ?? "sent"
            await fetchFolder(box, account: a)
            let label = ["drafts": "DRAFT", "trash": "TRASH", "junk": "SPAM"][box] ?? "SENT"
            return isDone ? [] : cachedHits(label, account: a)
        }
        if !isGmail(a) {
            // No Gmail search on iCloud or Microsoft (yet): search what's cached locally.
            let words = q.lowercased().split(separator: " ").map(String.init)
            for m in messages.values where m.account == a {
                let hay = (m.from + " " + m.to + " " + m.subject + " " + m.plainText).lowercased()
                let hit: Bool
                if let local { hit = matchesSearch(m, local) }
                else if q == "is:starred" { hit = m.labelIds.contains("STARRED") }
                else if isDone { hit = false }        // doneHere() already covers it
                else { hit = words.allSatisfy { hay.contains($0) } }
                if hit { ids.insert(a + "|" + m.threadId) }
            }
            return ids
        }
        do {
            let g = gmail(a)
            let found = try await g.listIds(q, max: 50)
            let missing = found.filter { messages["\(a)|\($0)"] == nil }
            for m in await g.messages(missing) { messages[m.key] = m }
            for id in found { if let m = messages["\(a)|\(id)"] { ids.insert(a + "|" + m.threadId) } }
            return ids
        } catch { report(error); return nil }
    }

    /// Pulls the newest emails from Sent or Archive on the server into Keymail, skipping ones already here.
    func fetchFolder(_ which: String, account a: String) async {
        // Drafts are re-read in full each time, so ones sent or deleted elsewhere drop out of the folder.
        let have = which == "drafts" ? [] : Set(messages.values.filter { $0.account == a }.map(\.id))
        do {
            let found = isMicrosoft(a) ? try await graph(a).recent(which, skip: have) : try await icloud(a).recent(which, skip: have)
            if which == "drafts" {
                log("\(a): drafts folder has \(found.count)")
                let keep = Set(found.map(\.key))
                messages = messages.filter { $0.value.account != a || !$0.value.labelIds.contains("DRAFT") || keep.contains($0.key) }
            }
            for m in found { messages[m.key] = m }
        } catch { log("\(a): \(which) folder: \(error.localizedDescription.prefix(200))") }
    }

    /// Archived conversations already on this Mac (in scope of the account picker): not in the inbox, not trash,
    /// spam or drafts, and not only mail you sent.
    func doneHere() -> Set<String> {
        Set(allConversations.filter { c in
            (state.activeAccount == nil || state.activeAccount == c.account) && !c.inInbox
                && !c.labels.contains("TRASH") && !c.labels.contains("SPAM")
                && !c.messages.allSatisfy { $0.labelIds.contains("DRAFT") || $0.labelIds == ["SENT"] }
        }.map(\.id))
    }

    func clearSearch() {
        searchOpen = false; searchFiltersOpen = false; searchText = ""; search = SearchQuery()
        searchResults = nil; folder = nil; selectedID = nil; threadOpen = false
    }
}
