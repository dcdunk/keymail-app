import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Sync


    /// One sync at a time. Overlapping syncs multiplied Gmail requests and hit the per-minute quota.
    /// scheduled: the 15-second timer. ⌘R, Fetch now and after-send ticks check every account right away.
    func tick(scheduled: Bool = false) async {
        guard !ticking else { return }
        ticking = true; syncing = true
        defer { ticking = false; syncing = false }
        await processDue()
        let known = Set(messages.keys)
        for a in state.accounts where !AppFlavor.isDemo {
            if let until = cooldown[a], until > Date() { continue }
            // Gmail checks every 15s (one cheap "what changed" request). iCloud, Yahoo and Outlook stay at 30s:
            // each of their checks signs in again or lists the inbox, and providers throttle frequent polling.
            if scheduled, !isGmail(a), let last = lastSynced[a], Date().timeIntervalSince(last) < 28 { continue }
            lastSynced[a] = Date()
            do { try await sync(a); quotaHits[a] = 0 }
            catch where (error as? HTTPError)?.isTransient == true || error is URLError {
                // Rate limits, Google 5xx and network blips: sit this account out a minute, quietly.
                // Only speak up if it keeps happening.
                cooldown[a] = Date().addingTimeInterval(65)
                quotaHits[a, default: 0] += 1
                log("\(a): temporary error, pausing 65s (\(quotaHits[a]!) in a row): \(error.localizedDescription.prefix(200))")
                if quotaHits[a]! >= 3 { report(error) }
            }
            catch { log("\(a): sync error: \(error.localizedDescription.prefix(300))"); report(error) }
        }
        applyInboxRules()
        saveCache()
        notifyArrivals(known: known)
        Notifier.shared.updateBadge() // also covers launches where nothing changed in this sync
    }

    /// Notifications for mail that arrived in this sync (still in the inbox after Mute and Auto Archive ran).
    func notifyArrivals(known: Set<String>) {
        guard !known.isEmpty, Notifier.notifyMode != "off" else { return } // first sync ever: everything is "new"
        let fresh = freshArrivals(Array(messages.values), knownKeys: known, me: me, muted: Set(state.muted))
        guard !fresh.isEmpty else { return }
        let all = allConversations, ctx = context(all)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = fresh.compactMap { m -> (message: Message, conversationId: String)? in
            let id = m.account + "|" + m.threadId
            guard let c = byId[id], c.inInbox else { return nil }
            if Notifier.notifyMode == "important", !isImportant(c, ctx) { return nil }
            return (m, id)
        }
        if !picked.isEmpty { log("notify: \(picked.count) notification(s) sent") }
        Notifier.shared.notify(picked)
    }

    /// Mute and Auto Archive: quietly archive matching new mail after each sync.
    func applyInboxRules() {
        let muted = Set(state.muted), since = state.autoArchiveSince ?? .distantFuture, cats = Set(state.autoArchive)
        for c in allConversations where c.inInbox && !c.isStarred && state.bumped[c.id] == nil {
            if muted.contains(c.id) { modify(c, remove: ["INBOX"]); continue }
            if !cats.isEmpty, c.latest.date > since, let cat = autoArchiveCategory(c.latest), cats.contains(cat),
               !state.autoArchived.contains(c.id) {
                modify(c, remove: ["INBOX"])
                state.autoArchived.append(c.id)
                if state.autoArchived.count > 500 { state.autoArchived.removeFirst(state.autoArchived.count - 500) }
            }
        }
    }

    func toggleMute() {
        guard let c = selected else { return }
        if state.muted.contains(c.id) {
            state.muted.removeAll { $0 == c.id }; banner = "Unmuted."
        } else {
            advance(after: c)
            state.muted.append(c.id)
            modify(c, remove: ["INBOX"])
            banner = "Muted. New replies in this thread will skip your inbox."
        }
    }

    func sync(_ a: String) async throws {
        if isICloud(a) { return try await syncICloud(a) }
        if isMicrosoft(a) { return try await syncMicrosoft(a) }
        let g = gmail(a)
        if let h = state.historyIds[a], let result = try await g.history(since: h) {
            let delta = parseHistory(result.pages)
            for id in delta.deleted { messages["\(a)|\(id)"] = nil }
            let cachedThreads = Set(messages.values.filter { $0.account == a }.map(\.threadId))
            var toFetch: [String] = []
            for (id, info) in delta.changed {
                if messages["\(a)|\(id)"] != nil { messages["\(a)|\(id)"]?.labelIds = info.labels }
                else if info.labels.contains("INBOX") || cachedThreads.contains(info.threadId) { toFetch.append(id) }
            }
            for m in await g.messages(toFetch) { messages[m.key] = m }
            state.historyIds[a] = result.latest
        } else {
            log("\(a): \(state.historyIds[a] == nil ? "no bookmark" : "bookmark expired"), full sync needed")
            try await fullSync(a)
        }
    }

    /// Reloads the inbox list, downloading only messages not already cached, then saves the history bookmark.
    func fullSync(_ a: String) async throws {
        let g = gmail(a)
        busy = "Loading \(a)…"
        defer { busy = nil }
        log("\(a): full sync start")
        let history = try await g.historyId()
        labelNames.merge(try await g.labels()) { $1 }
        let ids = try await g.listIds("in:inbox", max: 300)
        let have = Set(messages.values.filter { $0.account == a }.map(\.id))
        let fetched = await g.messages(ids.filter { !have.contains($0) })
        let keep = Set(ids)
        // Drop cached messages that left the inbox, unless they belong to a thread still in it.
        let inboxThreads = Set(messages.values.filter { $0.account == a && keep.contains($0.id) }.map(\.threadId) + fetched.map(\.threadId))
        messages = messages.filter { $0.value.account != a || keep.contains($0.value.id) || inboxThreads.contains($0.value.threadId) }
        for m in fetched { messages[m.key] = m }
        state.historyIds[a] = history
        log("\(a): full sync done, \(ids.count) in inbox, \(fetched.count) new, \(ids.count - have.intersection(keep).count - fetched.count) failed")
    }

    /// Plain-text sync log in Application Support/Email/sync.log. Never contains message content or secrets.
    func log(_ line: String) {
        let url = Disk.dir.appendingPathComponent("sync.log")
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? Data(entry.utf8).write(to: url) }
    }

    /// iCloud has no change feed: compare the last 30 days of INBOX with the cache and fetch only new messages.
    func syncICloud(_ a: String) async throws {
        let mine = messages.values.filter { $0.account == a }
        let result = try await icloud(a).syncInbox(cached: Set(mine.compactMap { Int($0.id) }))
        for m in mine {
            guard let uid = Int(m.id), let flags = result.flags[uid] else { messages[m.key] = nil; continue } // left the inbox
            var labels = m.labelIds.filter { !["UNREAD", "STARRED"].contains($0) }
            if !flags.contains("\\Seen") { labels.append("UNREAD") }
            if flags.contains("\\Flagged") { labels.append("STARRED") }
            messages[m.key]?.labelIds = labels
        }
        for m in result.new { messages[m.key] = m }
    }

    /// Microsoft: the newest 300 inbox emails from the last 30 days. Read/flag/Focused changes come from the list;
    /// full bodies are fetched only for emails not cached yet; emails that left the inbox are dropped.
    func syncMicrosoft(_ a: String) async throws {
        let g = graph(a)
        let list = try await g.inbox()
        let byId = Dictionary(list.compactMap { j in (j["id"] as? String).map { ($0, j) } }, uniquingKeysWith: { x, _ in x })
        for m in messages.values where m.account == a {
            guard let j = byId[m.id], let fresh = messageFromGraph(j, account: a, inInbox: true) else {
                messages[m.key] = nil // left the inbox (archived, deleted or moved anywhere)
                continue
            }
            if messages[m.key]?.labelIds != fresh.labelIds { messages[m.key]?.labelIds = fresh.labelIds }
        }
        let missing = byId.keys.filter { messages[a + "|" + $0] == nil }
        // A few at a time: fast on first load without tripping Microsoft's rate limits.
        for chunk in stride(from: 0, to: missing.count, by: 8).map({ Array(missing[$0..<min($0 + 8, missing.count)]) }) {
            let fetched = await withTaskGroup(of: Message?.self) { group in
                for id in chunk { group.addTask { try? await g.message(id, inInbox: true) } }
                var out: [Message] = []
                for await m in group { if let m { out.append(m) } }
                return out
            }
            for m in fetched { messages[m.key] = m }
        }
    }

    // MARK: Timed jobs: snooze wake-ups, scheduled sends, follow-up reminders

    func processDue() async {
        let now = Date()
        for s in state.snoozes {
            let cached = messages.values.filter { $0.account == s.account && $0.threadId == s.threadId }
            let repliedEarly = s.ifNoReply && gotReply(Array(cached), me: s.account, after: s.setAt)
            guard s.until <= now || repliedEarly else { continue }
            if !isGmail(s.account) {
                state.snoozes.removeAll { $0 == s }
                if !repliedEarly { state.bumped[s.conversationId] = now }
                continue
            }
            do {
                let g = gmail(s.account)
                let snoozedId = try await g.snoozeLabelId(existing: labelNames)
                labelNames[snoozedId] = Gmail.snoozeLabel
                let msgs = try await g.thread(s.threadId)
                if s.ifNoReply && gotReply(msgs, me: s.account, after: s.setAt) {
                    // Someone replied, so the reminder is cancelled; the reply already brought it back.
                    try await g.modifyThread(s.threadId, add: [], remove: [snoozedId])
                } else {
                    try await g.modifyThread(s.threadId, add: ["INBOX"], remove: [snoozedId])
                    state.bumped[s.conversationId] = now
                }
                state.snoozes.removeAll { $0 == s }
                for m in try await g.thread(s.threadId) { messages[m.key] = m }
            } catch { report(error) }
        }
        for job in state.scheduled where job.at <= now {
            do {
                try await send(job.draft, remindDays: job.remindDays)
                state.scheduled.removeAll { $0.id == job.id }
            } catch { report(AppError("Scheduled send failed, will retry: \(error.localizedDescription)")) }
        }
        for f in state.followUps where f.due <= now {
            if !isGmail(f.account) {
                let msgs = messages.values.filter { $0.account == f.account && $0.threadId == f.threadId }
                if !gotReply(Array(msgs), me: f.account, after: f.sentAt) { banner = "No reply yet to your email from \(f.account)." }
                state.followUps.removeAll { $0 == f }
                continue
            }
            do {
                let msgs = try await gmail(f.account).thread(f.threadId)
                if !gotReply(msgs, me: f.account, after: f.sentAt) {
                    try await gmail(f.account).modifyThread(f.threadId, add: ["INBOX"], remove: [])
                    state.bumped["\(f.account)|\(f.threadId)"] = now
                    for var m in msgs { if m.id == msgs.last?.id { m.labelIds.append("INBOX") }; messages[m.key] = m }
                    banner = "No reply yet: \(msgs.last?.subject ?? "")"
                }
                state.followUps.removeAll { $0 == f }
            } catch { report(error) }
        }
    }
}
