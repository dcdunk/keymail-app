import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    /// When a panel covering the inbox goes away, macOS doesn't tell the rows underneath where the mouse is until
    /// something like a click, so hover highlights stay dead. Rebuild the window's mouse tracking and replay a
    /// mouse move at the current position.
    func refreshHover(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let w = NSApp.keyWindow ?? NSApp.mainWindow, let root = w.contentView else { return }
            func walk(_ v: NSView) { v.updateTrackingAreas(); v.subviews.forEach(walk) }
            walk(root)
            let p = w.mouseLocationOutsideOfEventStream
            guard root.bounds.contains(root.convert(p, from: nil)),
                  let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            w.sendEvent(e)
        }
    }

    // MARK: Derived lists

    var allConversations: [Conversation] {
        if let c = convCache { return c }
        let a = state.activeAccount
        let c = conversations(from: a == nil ? Array(messages.values) : messages.values.filter { $0.account == a }, bumped: state.bumped)
        convCache = c
        return c
    }

    /// Like Superhuman: one account's inbox at a time. ⌘1…⌘9 picks an account, ⌘0 shows all.
    func switchAccount(_ a: String?) {
        state.activeAccount = a
        goTab(splitImportance ? importantTab : inboxTab)
    }

    /// Threads a reminder brought back that have no newer message since.
    func reminded(_ all: [Conversation]) -> Set<String> {
        Set(all.filter { c in state.bumped[c.id].map { c.latest.date <= $0 } ?? false }.map(\.id))
    }

    func context(_ all: [Conversation]) -> QueryContext {
        let freeMail: Set<String> = ["gmail.com", "googlemail.com"]
        let domains = Set(state.accounts.compactMap { $0.lowercased().split(separator: "@").last.map(String.init) }).subtracting(freeMail)
        return QueryContext(labelNames: labelNames, teamDomains: domains, reminded: reminded(all), importance: state.importance)
    }

    /// Inbox conversations grouped by tab, computed once per render.
    var tabMembers: [String: [Conversation]] {
        if let t = tabCache { return t }
        let all = allConversations, ctx = context(all)
        var out: [String: [Conversation]] = [:]
        let snoozed = Set(state.snoozes.map(\.conversationId))
        for c in all where c.inInbox && !snoozed.contains(c.id) {
            for t in tabs(for: c, splits: state.splits, ctx: ctx, splitImportance: splitImportance) { out[t, default: []].append(c) }
        }
        tabCache = out
        return out
    }

    var shownTabs: [String] {
        let members = tabMembers
        return state.splits.filter { $0.enabled && !($0.hideWhenEmpty && members[$0.name] == nil && $0.name != tabName) }.map(\.name)
            + (splitImportance ? [importantTab, otherTab] : [inboxTab])
    }

    /// Settings → Inbox: Important and Other tabs, or one inbox.
    var splitImportance: Bool { UserDefaults.standard.object(forKey: "splitImportance") as? Bool ?? true }

    var visible: [Conversation] {
        var list: [Conversation]
        if let r = searchResults { list = allConversations.filter { r.contains($0.id) } }
        else { list = tabMembers[tabName] ?? [] }
        return unreadOnly ? list.filter(\.isUnread) : list
    }

    func count(_ name: String, in members: [String: [Conversation]]) -> String {
        let n = members[name]?.count ?? 0
        return n == 0 || n > 999 ? "" : "\(n)"
    }

    var selected: Conversation? {
        let v = visible
        // A conversation opened from outside the current list (the context panel, a reminder) is still the one shown;
        // falling back to the list's first row showed an unrelated email.
        if let id = selectedID { if let c = v.first(where: { $0.id == id }) ?? allConversations.first(where: { $0.id == id }) { return c } }
        return v.first
    }
}
