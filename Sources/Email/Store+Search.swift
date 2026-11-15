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

    func runQuery(_ q: String, title: String, local: SearchQuery? = nil, limit: Int = AppStore.searchPage) {
        let more = limit > AppStore.searchPage   // "Show more results": same search, bigger page; keep your place
        let before = more ? (searchResults ?? []) : []
        folder = title
        lastQuery = (q, title, local); searchLimit = limit; searchMayHaveMore = false
        searchRun += 1
        let run = searchRun
        // Issue #4: Done used to sit on the previous email for ~10s while Gmail searched, looking empty.
        // Leave the email now and show archived mail already on this Mac at once; Gmail's results add to it.
        if !more { threadOpen = false; selectedID = nil }
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
        for a in accounts { found[a] = cachedHits(label, account: a).union(before.filter { $0.hasPrefix(a + "|") }) }
        func show() { searchResults = found.values.reduce(localHits) { $0.union($1) }.union(isDone ? doneHere() : localDone) }
        show()
        Task {
            busy = "Searching…"
            // Every account at once, each one's results shown as soon as it answers (one slow account used to hold up all).
            await withTaskGroup(of: (String, (ids: Set<String>, more: Bool)?).self) { g in
                for a in accounts { g.addTask { await (a, self.serverHits(q, account: a, isDone: isDone, local: local, limit: limit)) } }
                for await (a, hits) in g {
                    guard let hits, searchRun == run else { continue }   // a newer search started: drop this one's answers
                    // Sent and Starred keep older cached mail past the server's page; Trash, Spam and Drafts follow the server.
                    found[a] = label == "SENT" || label == "STARRED" || more ? hits.ids.union(found[a] ?? []) : hits.ids
                    if hits.more { searchMayHaveMore = true }
                    show()
                }
            }
            if searchRun == run { busy = nil }
        }
    }

    /// The same search again with another page of results from each account's server.
    func showMoreResults() {
        guard let l = lastQuery, searchResults != nil else { return }
        runQuery(l.q, title: l.title, local: l.local, limit: searchLimit + AppStore.searchPage)
    }

    /// Conversations already on this Mac with `label` (SENT, TRASH…).
    func cachedHits(_ label: String?, account a: String) -> Set<String> {
        guard let label else { return [] }
        return Set(messages.values.filter { $0.account == a && $0.labelIds.contains(label) }.map { a + "|" + $0.threadId })
    }

    /// One account's results from its server, and whether it had more than `limit`. Nil when it couldn't be reached
    /// (what's cached stays on screen).
    func serverHits(_ q: String, account a: String, isDone: Bool, local: SearchQuery?, limit: Int) async -> (ids: Set<String>, more: Bool)? {
        if !isGmail(a), q == "in:sent" || q == "in:drafts" || q == "in:trash" || q == "in:spam" || isDone {
            // Sent, Drafts, Trash, Spam and Done read those folders on the server (iCloud, Yahoo, Outlook), then list
            // what's here. Drafts and Trash used to search the cache for the words "in:drafts"/"in:trash" and showed nothing.
            let box = isDone ? "archive" : ["in:drafts": "drafts", "in:trash": "trash", "in:spam": "junk"][q] ?? "sent"
            await fetchFolder(box, account: a, limit: limit)
            let label = ["drafts": "DRAFT", "trash": "TRASH", "junk": "SPAM"][box] ?? "SENT"
            let ids = isDone ? [] : cachedHits(label, account: a)
            // ponytail: a full page on this Mac means there may be more; an exact 50 shows one "Show more" that adds nothing.
            return (ids, ids.count >= limit)
        }
        if !isGmail(a), let local {
            // A search on iCloud, Yahoo or Outlook asks their server, so older mail that isn't on this Mac is found too.
            // If the server can't be reached, the cached matches already on screen stay.
            do { return isMicrosoft(a) ? try await graphSearch(local, account: a, limit: limit) : try await icloudSearch(local, account: a, limit: limit) }
            catch { log("\(a): search: \(error.localizedDescription.prefix(200))"); return nil }
        }
        if !isGmail(a) {
            // Starred and labels on iCloud and Outlook: what's cached.
            var ids: Set<String> = []
            for m in messages.values where m.account == a && (q == "is:starred" ? m.labelIds.contains("STARRED") : false) { ids.insert(a + "|" + m.threadId) }
            return (ids, false)
        }
        do {
            let g = gmail(a)
            let found = try await g.listIds(q, max: limit)
            let missing = found.filter { messages["\(a)|\($0)"] == nil }
            for m in await g.messages(missing) { messages[m.key] = m }
            var ids: Set<String> = []
            for id in found { if let m = messages["\(a)|\(id)"] { ids.insert(a + "|" + m.threadId) } }
            return (ids, found.count >= limit)
        } catch { report(error); return nil }
    }

    /// iCloud and Yahoo: the IMAP server searches Inbox, Archive and Sent.
    func icloudSearch(_ q: SearchQuery, account a: String, limit: Int) async throws -> (ids: Set<String>, more: Bool) {
        let have = Set(messages.values.filter { $0.account == a }.map(\.id))
        let r = try await icloud(a).search(imapSearchCriteria(q), limit: limit, have: have)
        for m in r.new { messages[m.key] = m }
        log("\(a): search matched \(r.ids.count) on the server, downloaded \(r.new.count)")
        let hits = r.ids.compactMap { messages[a + "|" + $0] }
            .filter { !q.hasAttachment || $0.attachments.contains { !$0.isInline } }   // IMAP can't search for attachments
        return (Set(hits.map { a + "|" + $0.threadId }), r.more)
    }

    /// Outlook: Microsoft searches the words; Keymail checks sender, recipient, subject, dates, unread and attachments.
    func graphSearch(_ q: SearchQuery, account a: String, limit: Int) async throws -> (ids: Set<String>, more: Bool) {
        let text = graphSearchText(q)
        guard !text.isEmpty else { return ([], false) }   // filters only (dates, unread): the cached matches are shown
        let g = graph(a)
        let found = try await g.search(text, limit: limit)
        var check = q; check.words = ""; check.hasAttachment = false   // words were matched in the body too, by Microsoft
        var hits: [(id: String, folder: String)] = []
        for (j, box) in found {
            guard let m = messageFromGraph(j, account: a, inInbox: box == "inbox"), matchesSearch(m, check),
                  !q.hasAttachment || j["hasAttachments"] as? Bool == true else { continue }
            hits.append((m.id, box))
        }
        let missing = hits.filter { messages[a + "|" + $0.id] == nil }
        for chunk in stride(from: 0, to: missing.count, by: 8).map({ Array(missing[$0..<min($0 + 8, missing.count)]) }) {
            let got = await withTaskGroup(of: Message?.self) { group in
                for h in chunk { group.addTask { try? await g.message(h.id, inInbox: h.folder == "inbox") } }
                var out: [Message] = []
                for await m in group { if let m { out.append(m) } }
                return out
            }
            for var m in got {
                if hits.first(where: { $0.id == m.id })?.folder == "sent" { m.labelIds = m.labelIds.filter { $0 != "UNREAD" } + ["SENT"] }
                messages[m.key] = m
            }
        }
        return (Set(hits.compactMap { messages[a + "|" + $0.id].map { a + "|" + $0.threadId } }), found.count >= limit)
    }

    /// Pulls the newest emails from Sent or Archive on the server into Keymail, skipping ones already here.
    func fetchFolder(_ which: String, account a: String, limit: Int = AppStore.searchPage) async {
        // Drafts are re-read in full each time, so ones sent or deleted elsewhere drop out of the folder.
        let have = which == "drafts" ? [] : Set(messages.values.filter { $0.account == a }.map(\.id))
        do {
            let found = isMicrosoft(a) ? try await graph(a).recent(which, limit: limit, skip: have) : try await icloud(a).recent(which, limit: limit, skip: have)
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
        searchResults = nil; folder = nil; selectedID = nil; threadOpen = false; searchMayHaveMore = false
    }
}
