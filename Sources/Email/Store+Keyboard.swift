import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Keyboard

    // MARK: Menus and cards

    var modalOpen: Bool { composing != nil || editingSnippet != nil || splitSettingsOpen || eventDraft != nil || claudeTask != nil || agentApproval != nil || summary != nil || linkPrompt != nil }

    func showPopup(_ entries: [MenuEntry], anchor: CGRect, width: CGFloat = 290, trailing: Bool = false, custom: AnyView? = nil) {
        if let p = popup, p.anchor == anchor { closePopup(); return } // clicking the same button again closes it
        popup = Popup(entries: entries, anchor: anchor, width: width, trailing: trailing, custom: custom)
        popupIndex = nil
    }
    func closePopup() { popup = nil; popupIndex = nil }

    var selectable: [Int] {
        guard let p = popup else { return [] }
        return p.entries.indices.filter { p.entries[$0].kind == .item && !p.entries[$0].disabled }
    }

    func activatePopup(_ i: Int) {
        guard var p = popup, p.entries.indices.contains(i) else { return }
        let e = p.entries[i]
        guard e.kind == .item, !e.disabled else { return }
        if let sub = e.submenu {
            p.back.append(p.entries)
            p.entries = [MenuEntry(title: "Back", icon: "chevron.left", keepsOpen: true) { [weak self] in self?.popupBack() }, .header(e.title)] + sub
            popup = p; popupIndex = nil
            return
        }
        if !e.keepsOpen { closePopup() }
        e.action()
    }

    func popupBack() {
        guard var p = popup, let prev = p.back.popLast() else { return }
        p.entries = prev; popup = p; popupIndex = nil
    }

    /// Right-click on an email row opens Keymail's menu at the mouse. Elsewhere (text, links) the normal Mac menu stays.
    func rightClick(_ e: NSEvent) -> Bool {
        guard let c = rightClickTarget, !modalOpen, let h = e.window?.contentView?.bounds.height else { return false }
        let p = CGPoint(x: e.locationInWindow.x - mainFrame.minX, y: h - e.locationInWindow.y - mainFrame.minY)
        popup = nil
        showPopup(conversationEntries(c), anchor: CGRect(origin: p, size: .zero), width: 260)
        return true
    }

    func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let ch = e.charactersIgnoringModifiers ?? ""
        let code = e.keyCode // 125 down, 126 up, 36 return, 53 esc
        if popup != nil {
            let sel = selectable
            switch code {
            case 125: popupIndex = sel.first { $0 > (popupIndex ?? -1) } ?? sel.first
            case 126: popupIndex = sel.last { $0 < (popupIndex ?? Int.max) } ?? sel.last
            case 36, 76: if let i = popupIndex { activatePopup(i) }
            case 124: if let i = popupIndex, popup?.entries[i].submenu != nil { activatePopup(i) }
            case 123: popupBack()
            case 53: if popup?.back.isEmpty == false { popupBack() } else { closePopup() }
            default: if cmd { closePopup(); return false } // let ⌘ shortcuts through
            }
            return true
        }
        if settingsOpen { // Settings sits above everything, including an open draft
            if Hotkeys.recording { return false } // Settings → Hotkeys is capturing this key
            if code == 53 { settingsOpen = false; return true } // Esc
            if cmd, ch == "," { settingsOpen = false; return true }
            // ⌘K jumps to settings search, except in the signature editor where it adds a link.
            if cmd, ch == "k", (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor != false { settingsSearchFocus += 1; return true }
            // ↑/↓ move through the Settings sidebar, unless a text box or a list inside the page has the keyboard.
            if code == 125 || code == 126, !cmd {
                let fr = NSApp.keyWindow?.firstResponder
                if !(fr is NSTextView || fr is NSTableView) {
                    let ids = SettingsPanel.sections.map(\.id)
                    let cur = ids.firstIndex(of: UserDefaults.standard.string(forKey: "settingsTab") ?? "general") ?? 0
                    UserDefaults.standard.set(ids[max(0, min(ids.count - 1, cur + (code == 125 ? 1 : -1)))], forKey: "settingsTab")
                    return true
                }
            }
            return false // typing in settings fields must never trigger inbox shortcuts
        }
        if let lp = linkPrompt { // Esc / Return = don't open; ⌘Return = open anyway (deliberate, never the default)
            if cmd, code == 36 { NSWorkspace.shared.open(lp.url); linkPrompt = nil } else if code == 53 || code == 36 { linkPrompt = nil }
            return true
        }
        if summary != nil { if code == 53 { summary = nil; return true }; return false }
        if splitSettingsOpen { if code == 53 { splitSettingsOpen = false; return true }; return false }
        if composing != nil, code == 51, !cmd, let removeChip = chipBackspace, removeChip() { return true }
        if composing != nil || editingSnippet != nil || eventDraft != nil || claudeTask != nil || agentApproval != nil || state.accounts.isEmpty { return false }
        if cmd && ch == "k" { paletteOpen ? (paletteOpen = false) : openPalette(); return true }
        if paletteOpen {
            switch code {
            case 125: paletteIndex = min(paletteIndex + 1, max(filteredCommands.count - 1, 0)); return true
            case 126: paletteIndex = max(paletteIndex - 1, 0); return true
            case 36: runPalette(); return true
            case 53: paletteOpen = false; return true
            default: return false
            }
        }
        if cmd, !state.accounts.isEmpty, let n = Int(ch), !e.modifierFlags.contains(.shift) {
            if n == 0 { switchAccount(nil); return true }
            if n <= state.accounts.count { switchAccount(state.accounts[n - 1]); return true }
        }
        if cmd, ch == "r" { Task { await tick() }; return true }
        if cmd, ch == "z", !e.modifierFlags.contains(.shift), !(NSApp.keyWindow?.firstResponder is NSTextView) { undo(); return true }
        if cmd { return false }
        if code == 51, searchOpen, searchText.isEmpty, !search.isEmpty { removeLastSearchToken(); return true }
        if sidebarOpen, !(NSApp.keyWindow?.firstResponder is NSTextView) {
            switch (code, ch) {
            case (125, _), (_, "j"): panelIndex = min(panelIndex + 1, panelCount - 1); return true
            case (126, _), (_, "k"): panelIndex = max(panelIndex - 1, 0); return true
            case (36, _), (124, _): activatePanel(panelIndex); return true   // Return, or →
            case (53, _), (123, _): sidebarOpen = false; return true         // Esc, or ← again
            default: break
            }
        }
        if NSApp.keyWindow?.firstResponder is NSTextView {
            if code == 53, searchOpen { clearSearch(); return true }
            return false
        }
        if e.modifierFlags.contains(.shift), ch.lowercased() == "u" { unsubscribe(); return true }
        if threadOpen, e.modifierFlags.contains(.shift), ch.lowercased() == "o" { toggleAllMessages(); return true }
        if threadOpen, code == 49 { expandNext(); return true }        // Space
        if threadOpen, ch == "." { toggleQuoted(); return true }
        if e.modifierFlags.contains(.shift), ch.lowercased() == "m" { toggleMute(); return true }
        if e.modifierFlags.contains(.shift), ch.lowercased() == "r" { instantReply(); return true }
        if let n = Int(ch), (1...3).contains(n), let c = selected, instantReplies[c.id] != nil { useInstantReply(n - 1); return true }
        if code == 48 { switchTab(e.modifierFlags.contains(.shift) ? -1 : 1); return true } // Tab
        if let g = pendingG, Date().timeIntervalSince(g) < 1.5 {
            pendingG = nil
            let dest = ["i": "Inbox", "s": "Starred", "t": "Sent", "e": "Done", "h": "Reminders", "d": "Drafts"][ch]
            if let dest { goFolder(dest); return true }
        }
        switch (code, Hotkeys.resolve(ch)) {
        case (53, _) where sidebarOpen: sidebarOpen = false
        case (53, _):
            if threadOpen { threadOpen = false } else if searchResults != nil { clearSearch() } else { banner = nil }
        case (36, _), (_, "o"): if let c = selected { open(c) }
        case (125, _), (_, "j"): move(1)
        case (126, _), (_, "k"): move(-1)
        case (123, _): sidebarOpen.toggle()
        case (124, _): contextOpen.toggle()
        case (_, "g"): pendingG = Date()
        case (_, "e"): markDone()
        case (_, "c"): compose()
        case (_, "r"): if let c = selected, let d = myDraft(in: c) { openDraft(c, message: d) } else { reply(all: false) }
        case (_, "a"): reply(all: true)
        case (_, "f"): forward()
        case (_, "s"): toggleStar()
        case (_, "u"): toggleUnread()
        case (_, "#"), (51, _), (117, _): trash() // # like Superhuman, plus Backspace / Delete
        case (_, "h"): openPalette("remind")
        case (_, "b"): createEventFromEmail()
        case (_, "l"): openPalette("label")
        case (_, "i"): summarize()
        case (_, "/"): searchOpen = true
        default: return false
        }
        return true
    }
}
