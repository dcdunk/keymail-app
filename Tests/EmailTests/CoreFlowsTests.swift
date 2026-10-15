import XCTest
import AppKit
import EmailCore
@testable import Email

/// BULLETPROOF: the flows that must never break. Every change must keep these green (./build.sh runs them, and the
/// pre-push hook refuses to push if they fail). If you add a keyboard command, add it here.
///  1. Send and receive email.
///  2. Every keyboard command and the mouse actions on rows work.
/// Runs against an isolated store (temp folder, throwaway Keymail key; see AppFlavor.isTesting), never real mail.
@MainActor
final class CoreFlowsTests: XCTestCase {
    let me = "you@gmail.com"
    var store: AppStore!

    override func setUp() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "xctest")
        store = AppStore()
        store.messages = [:]
        store.state = SavedState()
        store.state.accounts = [me]; store.state.onboarded = true
        store.state.undoSendSeconds = 5
        for m in store.demoMessages(me) { store.messages[m.key] = m }
        store.goTab(store.shownTabs.first ?? "")
        store.selectedID = store.visible.first?.id
    }

    // MARK: Keyboard

    @discardableResult
    func press(_ ch: String, code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = []) -> Bool {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        return store.handleKey(e)
    }
    func resetUI() {
        store.composing = nil; store.paletteOpen = false; store.searchOpen = false; store.closePopup()
        store.threadOpen = false; store.folder = nil; store.searchResults = nil; store.summary = nil
        store.goTab(store.shownTabs.first ?? ""); store.selectedID = store.visible.first?.id
    }

    func testNextAndPreviousEmail() {
        let v = store.visible
        XCTAssertGreaterThan(v.count, 2, "the inbox needs several emails for this test")
        store.selectedID = v[0].id
        press("j", code: 38); XCTAssertEqual(store.selectedID, v[1].id, "J moves down")
        press("", code: 125); XCTAssertEqual(store.selectedID, v[2].id, "↓ moves down")
        press("k", code: 40); XCTAssertEqual(store.selectedID, v[1].id, "K moves up")
        press("", code: 126); XCTAssertEqual(store.selectedID, v[0].id, "↑ moves up")
    }

    func testOpenAndCloseEmail() {
        press("\r", code: 36); XCTAssertTrue(store.threadOpen, "Return opens the email")
        press("\u{1b}", code: 53); XCTAssertFalse(store.threadOpen, "Esc goes back")
        press("o", code: 31); XCTAssertTrue(store.threadOpen, "O opens the email")
    }

    func testDoneAndUndo() {
        let c = store.selected!
        press("e", code: 14)
        XCTAssertFalse(store.allConversations.first { $0.id == c.id }!.inInbox, "E marks done (archives)")
        XCTAssertNotEqual(store.selectedID, c.id, "the next email is selected")
        press("z", code: 6, .command)
        XCTAssertTrue(store.allConversations.first { $0.id == c.id }!.inInbox, "⌘Z puts it back")
    }

    func testTrashAndUndo() {
        let c = store.selected!
        press("#", code: 20, .shift)
        XCTAssertNil(store.allConversations.first { $0.id == c.id }, "# trashes")
        press("z", code: 6, .command)
        XCTAssertNotNil(store.allConversations.first { $0.id == c.id }, "⌘Z restores from trash")
    }

    func testStarAndUnread() {
        let id = store.selectedID!
        let starred = store.selected!.isStarred, unread = store.selected!.isUnread
        press("s", code: 1); XCTAssertNotEqual(store.allConversations.first { $0.id == id }!.isStarred, starred, "S stars")
        press("u", code: 32); XCTAssertNotEqual(store.allConversations.first { $0.id == id }!.isUnread, unread, "U toggles unread")
    }

    func testComposeReplyReplyAllForward() {
        press("c", code: 8); XCTAssertNotNil(store.composing, "C composes"); resetUI()
        let subject = store.selected!.latest.subject
        press("r", code: 15); XCTAssertEqual(store.composing?.draft.subject.hasPrefix("Re:"), true, "R replies"); resetUI()
        press("a", code: 0); XCTAssertNotNil(store.composing, "A replies all"); resetUI()
        press("f", code: 3); XCTAssertEqual(store.composing?.draft.subject, "Fwd: \(subject)", "F forwards")
    }

    func testSearchRemindLabelPaletteAndGoTo() {
        press("/", code: 44); XCTAssertTrue(store.searchOpen, "/ opens search"); resetUI()
        press("h", code: 4); XCTAssertTrue(store.paletteOpen && store.paletteText.contains("remind"), "H opens Remind me"); resetUI()
        press("l", code: 37); XCTAssertTrue(store.paletteOpen && store.paletteText == "label", "L opens Label in the palette"); resetUI()
        press("k", code: 40, .command); XCTAssertTrue(store.paletteOpen, "⌘K opens the palette")
        press("k", code: 40, .command); XCTAssertFalse(store.paletteOpen, "⌘K closes it"); resetUI()
        press("g", code: 5); press("s", code: 1); XCTAssertEqual(store.folder, "Starred", "G then S goes to Starred")
    }

    func testTabSwitchesSplitAndAccountShortcuts() {
        let tabs = store.shownTabs
        if tabs.count > 1 { press("\t", code: 48); XCTAssertEqual(store.tabName, tabs[1], "Tab goes to the next split") }
        store.state.accounts.append("other@gmail.com")
        press("2", code: 19, .command); XCTAssertEqual(store.state.activeAccount, "other@gmail.com", "⌘2 switches account")
        press("0", code: 29, .command); XCTAssertNil(store.state.activeAccount, "⌘0 shows all accounts")
    }

    /// Fails when a command is added to Hotkeys without wiring it into the keyboard handler.
    func testEveryHotkeyIsHandled() {
        // B (calendar) and I (summarize) start outside work: Calendar permission and the AI app. They're checked as palette commands below.
        for (key, title) in Hotkeys.commands where !["b", "i"].contains(key) {
            resetUI()
            XCTAssertTrue(press(key), "\(title) (\(key)) isn't handled")
        }
        resetUI()
        let titles = store.commands.map(\.title)
        XCTAssertTrue(titles.contains("Create calendar event from email"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("Summarize thread") })
    }

    func testRemappedKeyRunsTheCommandAndTheOldKeyDoesNot() {
        UserDefaults.standard.set("n", forKey: "hotkey.c")
        defer { UserDefaults.standard.removeObject(forKey: "hotkey.c") }
        press("c", code: 8); XCTAssertNil(store.composing, "the old key is free")
        press("n", code: 45); XCTAssertNotNil(store.composing, "the new key composes")
    }

    func testPaletteRunsWhatYouPick() {
        let id = store.selectedID!
        store.openPalette("mark done")
        XCTAssertEqual(store.filteredCommands.first?.title, "Mark done")
        press("\r", code: 36)
        XCTAssertFalse(store.allConversations.first { $0.id == id }!.inInbox, "Return runs the picked command")
    }

    // MARK: Mouse (row buttons and menus call these same store actions)

    func testRowButtonsActOnThatRowNotTheSelection() {
        let v = store.visible
        store.selectedID = v[0].id
        store.act(on: v[2]) { store.markDone() }
        XCTAssertFalse(store.allConversations.first { $0.id == v[2].id }!.inInbox, "the clicked row is done")
        XCTAssertTrue(store.allConversations.first { $0.id == v[0].id }!.inInbox, "the selected row is untouched")
        store.open(v[1]); XCTAssertTrue(store.threadOpen); XCTAssertEqual(store.selectedID, v[1].id, "clicking a row opens it")
    }

    // MARK: Send and receive

    func testSendWithUndoThenUndoBringsTheDraftBack() {
        var d = Draft(from: me); d.to = "maya@northwind.co"; d.subject = "Plan"; d.body = "Looks good."
        store.composing = ComposeModel(draft: d, context: nil)
        store.sendWithUndo(d, remindDays: nil)
        XCTAssertNil(store.composing, "compose closes on send")
        XCTAssertEqual(store.pendingSends.count, 1, "the send waits out the undo window")
        store.undo()
        XCTAssertTrue(store.pendingSends.isEmpty, "undo cancels the send")
        XCTAssertEqual(store.composing?.draft.body, "Looks good.", "and the draft comes back intact")
    }

    func testReplyStaysInTheConversation() {
        let c = store.allConversations.first { $0.messages.count > 1 }!
        store.selectedID = c.id
        store.reply(all: false)
        let d = store.composing!.draft
        XCTAssertEqual(d.inReplyTo, c.latest.messageIdHeader, "In-Reply-To points at the latest message")
        XCTAssertTrue(d.references.contains(c.latest.messageIdHeader), "References carries the thread")
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("In-Reply-To: \(c.latest.messageIdHeader)"), "the sent email carries the threading headers")
        XCTAssertTrue(raw.contains("To: "), "and a recipient")
    }

    func testScheduledSendIsKept() {
        var d = Draft(from: me); d.to = "a@b.co"; d.subject = "Later"
        store.schedule(d, at: Date().addingTimeInterval(3600), remindDays: 2)
        XCTAssertEqual(store.state.scheduled.last?.draft.subject, "Later")
        XCTAssertEqual(store.state.scheduled.last?.remindDays, 2)
    }

    func testNewMailArrivesAtTheTopUnreadAndJoinsItsThread() {
        let thread = store.allConversations.first { $0.messages.count > 1 }!
        let before = thread.messages.count
        let fresh = Message(id: "new-1", threadId: thread.threadId, account: me, from: "Sam Okafor <sam@northwind.co>", to: me,
                            subject: "Re: \(thread.latest.subject)", snippet: "One more thing", date: Date().addingTimeInterval(60),
                            labelIds: ["INBOX", "UNREAD", "IMPORTANT"], messageIdHeader: "<new-1@x>", text: "One more thing")
        store.messages[fresh.key] = fresh
        let c = store.allConversations.first { $0.id == thread.id }!
        XCTAssertEqual(c.messages.count, before + 1, "a reply joins its conversation")
        XCTAssertTrue(c.isUnread, "and shows as unread")
        store.goTab(store.shownTabs.first ?? "")
        XCTAssertEqual(store.visible.first?.id, thread.id, "newest conversation is on top")
    }

    // MARK: Inbox modes

    func testSingleInboxShowsEverythingAndStillNavigates() {
        let inboxCount = store.allConversations.filter(\.inInbox).count
        store.setSplitImportance(false)
        defer { store.setSplitImportance(true) }
        XCTAssertEqual(store.shownTabs, [inboxTab], "one tab when Important and Other is off")
        XCTAssertEqual(store.visible.count, inboxCount, "every inbox conversation is in it")
        store.selectedID = store.visible[0].id
        press("j", code: 38); XCTAssertEqual(store.selectedID, store.visible[1].id, "J still works")
        XCTAssertFalse(store.commands.contains { $0.title.hasPrefix("Move to") }, "no Move to Important/Other in a single inbox")
    }

    func testMovingImportanceMatchesTheRightMail() {
        let c = store.allConversations.first { $0.latest.from.contains("northwind.co") }!
        XCTAssertTrue(store.importanceKey("northwind.co", matches: c), "domain")
        XCTAssertTrue(store.importanceKey("maya@northwind.co", matches: store.allConversations.first { $0.messages[0].from.contains("maya@") }!), "sender")
        XCTAssertFalse(store.importanceKey("wind.co", matches: c), "a different domain that only ends the same way")
        XCTAssertTrue(store.importanceKey(c.id, matches: c)); XCTAssertFalse(store.importanceKey("x|y", matches: c))
        store.setImportance(c.id, important: false)
        XCTAssertTrue(store.tabMembers[otherTab]?.contains { $0.id == c.id } ?? false, "moved to Other")
    }
}
