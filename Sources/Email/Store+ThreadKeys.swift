import AppKit
import EmailCore

/// Keyboard and ⌘K paths for everything in an open conversation that used to need a click.
extension AppStore {
    func isOpen(_ m: Message, in c: Conversation) -> Bool { (m.key == (shownMessages(c).last ?? c.latest).key) != threadToggled.contains(m.key) }

    /// The thread's emails, minus the autosaved copy of a reply you're writing here: the reply box already shows it,
    /// and each autosave swaps that copy, which would collapse the email you're reading and move the thread.
    func shownMessages(_ c: Conversation) -> [Message] {
        guard composing?.context?.id == c.id else { return c.messages }
        let kept = c.messages.filter { !$0.labelIds.contains("DRAFT") || $0.labelIds.contains("SENT") }
        return kept.isEmpty ? c.messages : kept
    }

    /// The conversation's messages in the order they're shown (Settings → Messages in a thread).
    func shownOrder(_ c: Conversation) -> [Message] {
        UserDefaults.standard.bool(forKey: "threadNewestFirst") ? shownMessages(c).reversed() : shownMessages(c)
    }

    /// Space: open the next collapsed email, in reading order.
    func expandNext() {
        guard let c = selected, let m = shownOrder(c).first(where: { !isOpen($0, in: c) }) else { return }
        threadToggled.formSymmetricDifference([m.key])
    }

    /// ⇧O: open every email, or close all but the latest when they're all open already.
    func toggleAllMessages() {
        guard let c = selected else { return }
        let allOpen = c.messages.allSatisfy { isOpen($0, in: c) }
        for m in c.messages {
            let wantOpen = !allOpen || m.key == c.latest.key
            if isOpen(m, in: c) != wantOpen { threadToggled.formSymmetricDifference([m.key]) }
        }
    }

    /// ".": show or hide the earlier quoted history in every open email.
    func toggleQuoted() {
        guard let c = selected else { return }
        let open = c.messages.filter { isOpen($0, in: c) }.map(\.key)
        if open.allSatisfy(quotedShown.contains) { quotedShown.subtract(open) } else { quotedShown.formUnion(open) }
    }

    /// The thread's unsent draft, if you started one (R continues it instead of starting another reply).
    func myDraft(in c: Conversation) -> Message? {
        c.messages.last { $0.labelIds.contains("DRAFT") && !$0.labelIds.contains("SENT") }
    }

    /// ⌘K commands for the open conversation: attachments, quoted text, images, invites, drafts, order, the person.
    var threadCommands: [Command] {
        guard let c = selected else { return [] }
        var list: [Command] = []
        if let d = myDraft(in: c) { list.append(Command(title: "Continue editing draft", key: Hotkeys.label("r")) { self.openDraft(c, message: d) }) }
        if c.messages.count > 1 {
            list.append(Command(title: "Open next collapsed email", key: "Space") { self.expandNext() })
            list.append(Command(title: "Open or close all emails", key: "⇧O") { self.toggleAllMessages() })
            list.append(Command(title: "Reverse message order") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "threadNewestFirst"), forKey: "threadNewestFirst")
            })
        }
        list.append(Command(title: "Show or hide earlier messages", key: ".") { self.toggleQuoted() })
        if !UserDefaults.standard.bool(forKey: "loadRemoteImages"), c.messages.contains(where: { hasRemoteContent($0.html ?? "") }) {
            list.append(Command(title: "Load images in this conversation") { self.imagesShown.formUnion(c.messages.map(\.key)) })
        }
        for m in c.messages {
            for f in m.attachments where !f.isInline {
                list.append(Command(title: "Open attachment: \(f.name)") { self.preview(account: m.account, messageId: m.id, attachmentId: f.id, name: f.name) })
                list.append(Command(title: "Save attachment: \(f.name)") { self.download(account: m.account, messageId: m.id, attachmentId: f.id, name: f.name) })
            }
        }
        if let m = c.messages.last(where: { $0.calendar != nil }), let inv = m.calendar.flatMap(parseInvite), !inv.isCancelled {
            if let conf = inv.conference { list.append(Command(title: "Join \(conf.kind.rawValue)") { NSWorkspace.shared.open(conf.url) }) }
            for (r, word) in [(RSVP.accepted, "Going"), (.tentative, "Maybe"), (.declined, "Not going")] {
                list.append(Command(title: "RSVP: \(word)") {
                    Task {
                        do { self.banner = try await self.rsvp(inv, r, message: m) }
                        catch is NeedsCalendarAccess { self.banner = "Keymail needs your OK to update your calendar. Use Allow calendar access on the invite." }
                        catch { self.report(error) }
                    }
                })
            }
        }
        if let p = parseAddresses(c.latest.from).first {
            list.append(Command(title: "Copy sender address: \(p.email)") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.email, forType: .string); self.banner = "Copied \(p.email)."
            })
            let e = p.email.lowercased()
            for other in allConversations.filter({ $0.id != c.id && $0.messages.contains { parseAddresses($0.from + "," + $0.to).contains { $0.email.lowercased() == e } } })
                .sorted(by: { $0.latest.date > $1.latest.date }).prefix(5) {
                list.append(Command(title: "Open earlier conversation: \(other.latest.subject)") { self.selectedID = other.id; self.open(other) })
            }
            let w = senderWarnings(c.latest, known: knownContacts)
            if !w.isEmpty { list.append(Command(title: "Why is this sender flagged?") { self.banner = "Possible phishing: " + w.joined(separator: " ") }) }
        }
        return list
    }
}
