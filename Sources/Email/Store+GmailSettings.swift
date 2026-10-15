import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Gmail settings (out of office, signature sync, labels)

    var gmailAccounts: [String] { state.accounts.filter { isGmail($0) } }

    /// Runs a settings call; an account signed in before Keymail asked for settings access is flagged instead of erroring.
    /// A success doesn't clear the flag: Google lets you *read* settings without the permission, only saving needs it,
    /// so only the granted-scopes check (checkSettingsAccess) decides when the permission is really there.
    func settingsCall<T>(_ a: String, _ f: () async throws -> T) async -> T? {
        do { return try await f() }
        catch let e as HTTPError where e.needsMorePermission {
            AuthLog.log.notice("settings call 403 for \(a, privacy: .public): \(e.body.prefix(200), privacy: .public)")
            needsSettingsAccess.insert(a); return nil
        }
        catch { report(error); return nil }
    }

    /// Flags accounts whose sign-in predates the settings permission, so the Grant access button shows up front.
    func checkSettingsAccess(_ a: String) async {
        let scopes = await auth.grantedScopes(a)
        AuthLog.log.notice("tokeninfo \(a, privacy: .public): \(scopes.map { $0.components(separatedBy: "/").last ?? $0 }.sorted().joined(separator: ","), privacy: .public)")
        if !scopes.isEmpty, !scopes.contains(GoogleAuth.settingsScope) { needsSettingsAccess.insert(a) }
        else if scopes.contains(GoogleAuth.settingsScope) { needsSettingsAccess.remove(a) }
    }

    func loadVacations() async {
        for a in gmailAccounts { if let v = await settingsCall(a, { try await gmail(a).vacation() }) { vacations[a] = v } }
    }

    func saveVacation(_ v: Vacation, for a: String) async -> Bool {
        guard await settingsCall(a, { try await gmail(a).setVacation(v) }) != nil else { return false }
        vacations[a] = v
        banner = v.enabled ? "Out of office is on for \(label(a))." : "Out of office is off for \(label(a))."
        return true
    }

    /// Signs in again so Google can grant the settings permission (no mail reload needed).
    /// Asks Google again for `account` only, then trusts what Google says was granted in that same answer.
    func grantSettingsAccess(for account: String) {
        Task {
            busy = "Approve the new permission in your browser…"
            defer { busy = nil }
            do {
                let r = try await auth.signIn(hint: account)
                banner = settingsGrantOutcome(requested: account, signedIn: r.email, scopes: r.scopes)
                if r.email.lowercased() == account.lowercased() {
                    if r.scopes.contains(GoogleAuth.settingsScope) { needsSettingsAccess.remove(account) } else { needsSettingsAccess.insert(account) }
                }
                await loadVacations()
            } catch { report(error) }
        }
    }

    /// Email's signature → Gmail (so the phone app and gmail.com match).
    func pushSignature(_ address: String, account a: String) async -> String {
        let parts = signatureParts(signature(for: address))
        let html = parts.html ?? plainToHTML(parts.plain)
        if let problem = gmailSignatureProblem(html) { return problem }
        return await settingsCall(a, { try await gmail(a).setSignature(address, html: html) }) != nil ? "Sent to Gmail." : "Not synced."
    }

    /// Gmail's signature → Email.
    func pullSignature(_ address: String, account a: String) async -> String {
        guard let list = await settingsCall(a, { try await gmail(a).sendAs() }) else { return "Not synced." }
        guard let sig = list.first(where: { $0.email.lowercased() == address.lowercased() })?.signature, !sig.isEmpty else {
            return "Gmail has no signature for this address."
        }
        state.signatures[address.lowercased()] = sig
        return "Imported from Gmail."
    }

    func loadLabels(_ a: String) async {
        if let l = try? await gmail(a).userLabels() { gmailLabels[a] = l; labelNames.merge(Dictionary(l.map { ($0.id, $0.name) }) { $1 }) { $1 } }
    }

    func labelAction(_ a: String, _ f: @escaping () async throws -> Void) {
        Task { do { try await f(); await loadLabels(a) } catch { report(error) } }
    }

    /// Add or remove a Gmail label on a conversation.
    func setLabel(_ id: String, on c: Conversation, _ on: Bool) {
        on ? modify(c, add: [id]) : modify(c, remove: [id])
    }

    /// Mouse actions on a specific row: select it, then run the same action the keyboard would.
    func act(on c: Conversation, _ f: () -> Void) { selectedID = c.id; f() }

    func toggleStar() { if let c = selected { c.isStarred ? modify(c, remove: ["STARRED"]) : modify(c, add: ["STARRED"]) } }
    func toggleUnread() { if let c = selected { c.isUnread ? modify(c, remove: ["UNREAD"]) : modify(c, add: ["UNREAD"]) } }

    func remind(until date: Date, ifNoReply: Bool) {
        guard let c = selected else { return }
        advance(after: c)
        if !isGmail(c.account) {
            // iCloud and Microsoft reminders hide the thread locally; it stays in that account's inbox.
            state.snoozes.removeAll { $0.conversationId == c.id }
            state.snoozes.append(Snooze(account: c.account, threadId: c.threadId, until: date, ifNoReply: ifNoReply))
            state.bumped[c.id] = nil
            banner = "Reminder set for \(date.formatted(date: .abbreviated, time: .shortened))\(ifNoReply ? " if no one replies" : "")."
            return
        }
        Task {
            do {
                let label = try await gmail(c.account).snoozeLabelId(existing: labelNames)
                labelNames[label] = Gmail.snoozeLabel
                state.snoozes.removeAll { $0.conversationId == c.id }
                state.snoozes.append(Snooze(account: c.account, threadId: c.threadId, until: date, ifNoReply: ifNoReply))
                state.bumped[c.id] = nil
                modify(c, add: [label], remove: ["INBOX"])
                banner = "Reminder set for \(date.formatted(date: .abbreviated, time: .shortened))\(ifNoReply ? " if no one replies" : "")."
            } catch { report(error) }
        }
    }

    func removeReminder() {
        guard let c = selected, state.snoozes.contains(where: { $0.conversationId == c.id }) else { return }
        state.snoozes.removeAll { $0.conversationId == c.id }
        if !isGmail(c.account) { return }
        let snoozed = labelNames.first { $0.value == Gmail.snoozeLabel || Gmail.legacySnoozeLabels.contains($0.value) }?.key
        modify(c, add: ["INBOX"], remove: snoozed.map { [$0] } ?? [])
    }

    func setImportance(_ key: String, important: Bool) {
        state.importance[key] = important
        banner = ("Moved \(key.contains("|") ? "conversation" : key) to \(important ? importantTab : otherTab).")
    }

    func open(_ c: Conversation) {
        searchOpen = false
        // Only a standalone draft (nothing but unsent drafts) opens straight into compose. A reply you've started
        // inside a conversation must never block reading it: the thread opens and the draft shows as a card.
        if c.messages.allSatisfy({ $0.labelIds.contains("DRAFT") && !$0.labelIds.contains("SENT") }) { openDraft(c); return }
        selectedID = c.id
        threadOpen = true
        recentlyOpened.removeAll { $0 == c.id }
        recentlyOpened.insert(c.id, at: 0)
        if c.isUnread { modify(c, remove: ["UNREAD"]) }
        Task {
            // Pull the whole thread, including older messages that already left the inbox.
            if !isGmail(c.account) { await loadInlineImages(c.messages); return }
            if let msgs = try? await gmail(c.account).thread(c.threadId) {
                for m in msgs { messages[m.key] = m }
                await loadInlineImages(msgs)
            }
        }
    }

    func move(_ delta: Int) {
        searchOpen = false // leaving the search bar: Backspace deletes emails again
        let v = visible
        guard !v.isEmpty else { return }
        let i = v.firstIndex { $0.id == selected?.id } ?? 0
        let next = v[max(0, min(v.count - 1, i + delta))]
        selectedID = next.id
        if threadOpen { open(next) }
    }

    func switchTab(_ delta: Int) {
        let t = shownTabs
        let i = t.firstIndex(of: tabName) ?? 0
        goTab(t[(i + delta + t.count) % t.count])
    }

    func goTab(_ name: String) {
        searchResults = nil; folder = nil; searchOpen = false
        tabName = name; selectedID = nil; threadOpen = false
    }

    func unsubscribe() {
        guard let m = selected?.messages.last(where: { !$0.listUnsubscribe.isEmpty }) else { banner = "This sender has no unsubscribe link."; return }
        switch unsubscribeAction(header: m.listUnsubscribe, oneClickPost: m.listUnsubscribePost) {
        case .oneClick(let url):
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            Task {
                let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse).map { $0.statusCode < 400 } ?? false
                banner = ok ? "Unsubscribed." : "Unsubscribe failed. Opening the link instead."
                if !ok { NSWorkspace.shared.open(url) }
            }
            markDone()
        case .open(let url): NSWorkspace.shared.open(url); markDone()
        case .none: banner = "This sender has no unsubscribe link."
        }
    }
}

/// What to tell the person after a Grant access round trip. nil = it worked.
func settingsGrantOutcome(requested: String, signedIn: String, scopes: Set<String>) -> String? {
    if signedIn.lowercased() != requested.lowercased() {
        return "You approved \(signedIn), not \(requested). Click Grant access again and pick \(requested) in Google's account list."
    }
    if !scopes.contains(GoogleAuth.settingsScope) {
        return "Google didn't include the settings permission. On Google's screen, tick \"See, edit, create, or change your email settings and filters in Gmail\" (or Select all) before you press Continue."
    }
    return "Settings access granted for \(requested)."
}
