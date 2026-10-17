import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Compose / send

    var defaultAccount: String { selected?.account ?? state.activeAccount ?? state.accounts.first ?? "" }

    func signature(for address: String) -> String {
        (state.signatures[address.lowercased()] ?? state.signatures[account(for: address).lowercased()] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opens compose, adding the From address's signature if Settings says this kind of email gets one.
    @discardableResult
    func openCompose(_ d: Draft, context: Conversation?, isReply: Bool = false) -> ComposeModel {
        var d = d
        let use = state.signatureUse
        if use == "all" || (use == "new" && !isReply) || (use == "replies" && isReply) { applySignature(&d, from: d.from) }
        let m = ComposeModel(draft: d, context: context)
        composing = m
        return m
    }

    /// Sets the draft's signature to `address`'s, or removes it when nil.
    func applySignature(_ d: inout Draft, from address: String?) {
        guard let address else { d.signaturePlain = nil; d.signatureHTML = nil; return }
        let sig = signatureParts(signature(for: address))
        d.signaturePlain = sig.plain.isEmpty ? nil : sig.plain
        d.signatureHTML = sig.html
    }

    func plainSignature(for address: String) -> String { EmailCore.signatureParts(signature(for: address)).plain }

    /// Addresses that have a signature saved, for compose's Signature menu.
    var addressesWithSignatures: [String] { fromAddresses.filter { !signature(for: $0).isEmpty } }

    /// Changing From swaps to that address's signature, if the email has one.
    func changeFrom(_ model: ComposeModel, to address: String) {
        model.draft.from = address
        if model.draft.signaturePlain != nil { applySignature(&model.draft, from: address) }
    }

    func compose() { openCompose(Draft(from: sendAddress(defaultAccount)), context: nil) }
    func reply(all: Bool) {
        guard let c = selected else { return }
        var d = replyDraft(to: c.latest, me: c.account, all: all)
        let mine = me
        // Keep your own aliases out of the To/Cc of a reply-all.
        d.cc = parseAddresses(d.cc).filter { !mine.contains($0.email.lowercased()) }.map(\.formatted).joined(separator: ", ")
        d.from = replyFrom(c.latest, account: c.account)
        // Settings → General → Reply inside the conversation: the reply sits under the thread you're reading.
        let inline = UserDefaults.standard.bool(forKey: "replyInline") && (threadOpen || inboxLayout == "split" || inboxLayout == "film")
        if inline { threadOpen = true }
        let m = ComposeModel(draft: d, context: c); m.inline = inline
        var dd = d
        let use = state.signatureUse
        if use == "all" || use == "replies" { applySignature(&dd, from: dd.from); m.draft = dd }
        composing = m
    }
    func forward() {
        guard let c = selected else { return }
        let model = openCompose(forwardDraft(of: c.latest, me: replyFrom(c.latest, account: c.account)), context: c, isReply: true)
        let m = c.latest
        let files = m.attachments.filter { !$0.isInline }
        guard !files.isEmpty else { return }
        // Forwarding carries the original attachments along.
        Task {
            model.busy = true
            defer { model.busy = false }
            for a in files {
                do {
                    let data = try await fetchAttachment(account: m.account, messageId: m.id, id: a.id)
                    model.draft.files.append(OutgoingFile(name: a.name, mimeType: a.mimeType, data: data))
                } catch { model.error = "Couldn't attach \(a.name): \(error.localizedDescription)" }
            }
        }
    }

    /// "Dan Chait <danchait@icloud.com>": adds the account's Name (Settings → Accounts) when From is a bare address.
    func namedFrom(_ from: String) -> String {
        guard let a = parseAddresses(from).first, a.name.isEmpty else { return from }
        let n = state.senderNames[account(for: a.email)]?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? from : Address(name: n, email: a.email).formatted
    }

    func send(_ d: Draft, remindDays: Int?) async throws {
        if let bad = invalidRecipients(d).first {
            throw AppError("\"\(bad)\" isn't a complete email address. Fix it and send again.")
        }
        var d = d
        d.from = namedFrom(d.from)
        let domain = d.from.split(separator: "@").last.map(String.init) ?? "email.local"
        if d.messageId == nil { d.messageId = "<\(UUID().uuidString)@\(domain)>" }
        if AppFlavor.isDemo { demoSend(d); return }
        let acct = account(for: d.from)
        if isMicrosoft(acct) {
            // Save as a draft, then send it: the draft step tells us the conversation for "remind me if no reply".
            // The autosaved draft (if any) is replaced, not left behind.
            let g = graph(acct)
            if let old = d.draftId { try? await g.delete(old) }
            let sent = try await g.createDraft(mime: buildRaw(d))
            try await g.sendDraft(sent.id)
            if let days = remindDays, !sent.conversationId.isEmpty {
                state.followUps.append(FollowUp(account: acct, threadId: sent.conversationId, sentAt: Date().addingTimeInterval(-5),
                                                due: Date().addingTimeInterval(Double(days) * 86400)))
            }
            return
        }
        defer { Task { await self.deleteDraft(d) } }
        if isICloud(acct) {
            try await icloud(acct).send(d)
            if let days = remindDays {
                let thread = d.references.split(separator: " ").first.map(String.init) ?? d.messageId!
                state.followUps.append(FollowUp(account: acct, threadId: thread, sentAt: Date().addingTimeInterval(-5),
                                                due: Date().addingTimeInterval(Double(days) * 86400)))
            }
            return
        }
        let j: [String: Any]
        do { j = try await gmail(acct).send(d) }
        catch let e as HTTPError where e.body.contains("Invalid To header") || e.body.contains("Invalid Cc header") {
            // Show exactly what Gmail refused, so a report can name the cause (issue #5).
            let line = buildRaw(d).components(separatedBy: "\r\n").filter { $0.hasPrefix("To:") || $0.hasPrefix("Cc:") }.joined(separator: " · ")
            throw AppError("Gmail rejected the recipients. It received: \(line)")
        }
        if let days = remindDays, let thread = j["threadId"] as? String {
            state.followUps.append(FollowUp(account: acct, threadId: thread, sentAt: Date().addingTimeInterval(-5),
                                            due: Date().addingTimeInterval(Double(days) * 86400)))
        }
    }

    // MARK: Drafts (synced to Gmail / iCloud Drafts)

    /// Debounced autosave: 2 seconds after the last edit.
    func scheduleDraftSave(_ model: ComposeModel) {
        model.saveTask?.cancel()
        model.saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveDraft(model)
        }
    }

    func saveDraft(_ model: ComposeModel) async {
        var d = model.draft
        d.from = namedFrom(d.from)
        let isEmpty = d.to.trimmingCharacters(in: .whitespaces).isEmpty && d.subject.isEmpty
            && d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !isEmpty, !AppFlavor.isDemo else { return }
        if d.messageId == nil {
            let domain = d.from.split(separator: "@").last.map(String.init) ?? "email.local"
            d.messageId = "<\(UUID().uuidString)@\(domain)>"; model.draft.messageId = d.messageId
        }
        let acct = account(for: d.from)
        do {
            if isMicrosoft(acct) {
                // Microsoft can't edit a draft's raw contents, so each save replaces the previous copy.
                let g = graph(acct)
                let saved = try await g.createDraft(mime: buildRaw(d))
                if let old = model.draft.draftId { try? await g.delete(old) }
                model.draft.draftId = saved.id
                model.savedNote = "Draft saved"
                return
            }
            if isICloud(acct) { try await icloud(acct).saveDraft(d) }
            else { model.draft.draftId = try await gmail(acct).saveDraft(d) }
            model.savedNote = "Draft saved"
        } catch { model.savedNote = "Draft not saved: \(error.localizedDescription.prefix(80))" }
    }

    /// The compose trash can. Removes the draft from the screen at once (thread card and Drafts folder), then from
    /// the server, finding its ID first if a reopened draft's ID hadn't been looked up yet.
    func discardCompose(_ model: ComposeModel) {
        model.saveTask?.cancel()
        var d = model.draft
        let acct = account(for: d.from), shown = model.draftMessage
        if let shown { messages[shown.key] = nil }
        if isMicrosoft(acct), let id = d.draftId { messages[acct + "|" + id] = nil } // Microsoft draft IDs are message IDs
        banner = "Draft discarded."
        Task {
            if d.draftId == nil, let shown {
                if isMicrosoft(acct) { d.draftId = shown.id }
                else if isGmail(acct) { d.draftId = (try? await gmail(acct).draftIds())?[shown.id] }
            }
            if d.messageId == nil, let shown, !shown.messageIdHeader.isEmpty { d.messageId = shown.messageIdHeader } // iCloud finds drafts by Message-ID
            await deleteDraft(d)
        }
    }

    func deleteDraft(_ d: Draft) async {
        let acct = account(for: d.from)
        if isICloud(acct) { if let mid = d.messageId { try? await icloud(acct).deleteDraft(messageId: mid) } }
        else if isMicrosoft(acct), let id = d.draftId { try? await graph(acct).delete(id) }
        else if isGmail(acct), let id = d.draftId { try? await gmail(acct).deleteDraft(id) }
    }

    /// Drafts can't go to Trash (Gmail answers 404), so they're discarded with the drafts API instead.
    /// Like Gmail's own "Discard draft", this can't be undone.
    func discardDrafts(_ c: Conversation) {
        advance(after: c)
        for m in c.messages { messages[m.key] = nil }
        banner = "Draft discarded."
        Task {
            do {
                if isICloud(c.account) {
                    for m in c.messages where !m.messageIdHeader.isEmpty { try await icloud(c.account).deleteDraft(messageId: m.messageIdHeader) }
                } else if isMicrosoft(c.account) {
                    for m in c.messages { try await graph(c.account).delete(m.id) }
                } else if isGmail(c.account) {
                    let ids = try await gmail(c.account).draftIds()
                    for m in c.messages { if let d = ids[m.id] { try await gmail(c.account).deleteDraft(d) } }
                }
            } catch { report(error) }
        }
    }

    /// Opening a Gmail draft from the Drafts folder continues editing it.
    func openDraft(_ c: Conversation, message: Message? = nil) {
        let m = message ?? c.latest
        var d = Draft(from: m.account)
        d.to = m.to; d.cc = m.cc; d.subject = m.subject; d.body = m.plainText
        d.threadId = c.messages.count > 1 ? m.threadId : nil
        d.messageId = m.messageIdHeader.isEmpty ? nil : m.messageIdHeader
        d.references = m.references
        let model = ComposeModel(draft: d, context: c.messages.count > 1 ? c : nil)
        model.draftMessage = m
        composing = model
        guard isGmail(m.account) else { return }
        Task { model.draft.draftId = (try? await gmail(m.account).draftIds())?[m.id] }
    }

    func schedule(_ d: Draft, at: Date, remindDays: Int?) {
        state.scheduled.append(ScheduledSend(draft: d, at: at, remindDays: remindDays))
        banner = "Scheduled for \(at.formatted(date: .abbreviated, time: .shortened))."
    }
}
