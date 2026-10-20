import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Triage actions (optimistic: update locally, then tell Gmail)

    func modify(_ c: Conversation, add: [String] = [], remove: [String] = []) {
        for m in c.messages {
            var labels = m.labelIds.filter { !remove.contains($0) }
            if m.id == c.latest.id || !add.contains("INBOX") { labels += add.filter { !labels.contains($0) } }
            messages[m.key]?.labelIds = labels
        }
        Task {
            do {
                if isICloud(c.account) { try await icloudModify(c, add: add, remove: remove) }
                else if isMicrosoft(c.account) { try await graphModify(c, add: add, remove: remove) }
                else { try await gmail(c.account).modifyThread(c.threadId, add: add, remove: remove) }
            } catch { report(error); try? await sync(c.account) }
        }
    }

    /// Gmail labels → Microsoft Graph: UNREAD = isRead, STARRED = flag, INBOX = Inbox vs Archive folder.
    func graphModify(_ c: Conversation, add: [String], remove: [String]) async throws {
        let g = graph(c.account), ids = c.messages.map(\.id)
        if remove.contains("UNREAD") { for id in ids { try await g.setRead(id, true) } }
        if add.contains("UNREAD") { try await g.setRead(c.latest.id, false) }
        if add.contains("STARRED") { try await g.setFlagged(c.latest.id, true) }
        if remove.contains("STARRED") { for id in ids { try await g.setFlagged(id, false) } }
        // Your copies in Sent Items stay put: only the inbox emails move to Archive.
        if remove.contains("INBOX") { for m in c.messages where !m.labelIds.contains("SENT") { try await g.move(m.id, to: "archive") } }
        if add.contains("INBOX") { try await g.move(c.latest.id, to: "inbox") }
    }

    /// Gmail labels → IMAP: INBOX removal = archive, UNREAD = \Seen, STARRED = \Flagged.
    func icloudModify(_ c: Conversation, add: [String], remove: [String]) async throws {
        // Only INBOX UIDs (plain numbers): Sent/Archive copies carry prefixed ids from their own mailbox.
        let ic = icloud(c.account), uids = c.messages.map(\.id).filter { Int($0) != nil }
        guard let last = uids.last else { return }
        if remove.contains("UNREAD") { try await ic.setFlag(uids, "\\Seen", on: true) }
        if add.contains("UNREAD") { try await ic.setFlag([last], "\\Seen", on: false) }
        if add.contains("STARRED") { try await ic.setFlag([last], "\\Flagged", on: true) }
        if remove.contains("STARRED") { try await ic.setFlag(uids, "\\Flagged", on: false) }
        if remove.contains("INBOX") { try await ic.move(uids, toTrash: false) }
    }

    /// Removes the selection from the list and picks the next row, like Superhuman.
    func advance(after c: Conversation) {
        let v = visible
        if let i = v.firstIndex(where: { $0.id == c.id }) {
            selectedID = i + 1 < v.count ? v[i + 1].id : (i > 0 ? v[i - 1].id : nil)
        } else { selectedID = nil } // opened from outside the list (context panel): back to the list
        if selectedID == nil { threadOpen = false }
        // Settings → General: finishing the last unread email (done, delete, remind…) goes back to the inbox
        // instead of opening the next, already-read one.
        if threadOpen, UserDefaults.standard.object(forKey: "backToInboxWhenDone") as? Bool ?? true,
           !v.contains(where: { $0.id != c.id && $0.isUnread }) { threadOpen = false }
    }

    // MARK: Undo (⌘Z) for delete and Done

    enum UndoKind { case trash, done }

    // MARK: Undo send

    struct PendingSend { let id = UUID(); let draft: Draft; let remindDays: Int?; let task: Task<Void, Never> }

    /// Closes compose, waits the undo window, then sends. A failure reopens the draft so nothing is lost.
    func sendWithUndo(_ d: Draft, remindDays: Int?) {
        var d = d
        if d.messageId == nil {
            let domain = d.from.split(separator: "@").last.map(String.init) ?? "email.local"
            d.messageId = "<\(UUID().uuidString)@\(domain)>"
        }
        composing = nil
        let delay = state.undoSendSeconds
        let task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            guard let self, !Task.isCancelled else { return }
            self.pendingSends.removeAll { $0.draft.messageId == d.messageId }
            do {
                try await self.send(d, remindDays: remindDays)
                self.banner = "Sent."
                await self.tick()
            } catch {
                let m = ComposeModel(draft: d, context: nil); m.remindDays = remindDays
                m.error = "Not sent: \(error.localizedDescription)"
                self.composing = m
            }
        }
        pendingSends.append(PendingSend(draft: d, remindDays: remindDays, task: task))
        banner = delay > 0 ? "Sending in \(delay)s… ⌘Z to undo." : nil
    }

    func undo() {
        if let p = pendingSends.popLast() {
            p.task.cancel()
            let m = ComposeModel(draft: p.draft, context: nil); m.remindDays = p.remindDays
            composing = m
            banner = "Send cancelled. Your draft is back."
            return
        }
        guard let (c, kind) = undoStack.popLast() else { banner = "Nothing to undo."; return }
        // Put it back on screen right away, then tell the server.
        for var m in c.messages {
            if !m.labelIds.contains("INBOX"), m.id == c.latest.id { m.labelIds.append("INBOX") }
            messages[m.key] = m
        }
        selectedID = c.id
        banner = kind == .trash ? "Restored from Trash." : "Moved back to inbox."
        Task {
            do {
                if isICloud(c.account) {
                    try await icloud(c.account).restore(messageIds: c.messages.map(\.messageIdHeader), fromTrash: kind == .trash)
                    // UIDs change when iCloud moves mail, so drop the old copies and re-fetch.
                    for m in c.messages { messages[m.key] = nil }
                    try await syncICloud(c.account)
                } else if isMicrosoft(c.account) {
                    // IDs are immutable (see GraphMail), so the same IDs work after the move.
                    for m in c.messages { try await graph(c.account).move(m.id, to: "inbox") }
                } else if kind == .trash {
                    try await gmail(c.account).untrashThread(c.threadId)
                } else {
                    try await gmail(c.account).modifyThread(c.threadId, add: ["INBOX"], remove: [])
                }
            } catch { report(error); try? await sync(c.account) }
        }
    }

    func markDone() {
        guard let c = selected else { return }
        advance(after: c)
        undoStack.append((c, .done))
        modify(c, remove: ["INBOX"])
        state.bumped[c.id] = nil
        if threadOpen, let s = selected { open(s) }
    }

    func trash() {
        guard let c = selected else { return }
        if c.messages.allSatisfy({ $0.labelIds.contains("DRAFT") }) { discardDrafts(c); return }
        advance(after: c)
        undoStack.append((c, .trash))
        banner = "Moved to Trash. ⌘Z to undo."
        for m in c.messages { messages[m.key] = nil }
        state.readyDrafts[c.id] = nil   // a reply Keymail wrote for it goes too
        Task {
            do {
                if isICloud(c.account) { try await icloud(c.account).move(c.messages.map(\.id).filter { Int($0) != nil }, toTrash: true) }
                else if isMicrosoft(c.account) { for m in c.messages where !m.labelIds.contains("SENT") { try await graph(c.account).move(m.id, to: "deleteditems") } }
                else { try await gmail(c.account).trashThread(c.threadId) }
            } catch { report(error) }
        }
    }
}
