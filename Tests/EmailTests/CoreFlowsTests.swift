import XCTest
import AppKit
import SwiftUI
import EmailCore
@testable import Email

/// BULLETPROOF: the flows that must never break. Every change must keep these green (./build.sh runs them, and the
/// pre-push hook refuses to push if they fail). If you add a keyboard command, add it here.
///  1. Send and receive email.
///  2. Every keyboard command and the mouse actions on rows work.
///  3. ⌘K puts the cursor straight into the palette's text box.
///  4. The calendar: G C / G I and the top-bar button switch views, and every calendar key works.
///  5. Clean up senders and Insights open from ⌘K, and their keys work; ready drafts send, edit and go away.
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
        store.agentPlans = [:]   // plans are saved to disk; don't carry one test's into the next
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
        store.closeCalendar(); store.closeTool()
        store.sidebarOpen = false
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

    func testJunkAndUndo() {
        let c = store.selected!
        press("!", code: 18, .shift)
        XCTAssertNil(store.allConversations.first { $0.id == c.id }, "! marks it as junk: out of the inbox")
        XCTAssertEqual(store.banner, "Marked as junk. ⌘Z to undo.")
        press("z", code: 6, .command)
        XCTAssertTrue(store.allConversations.first { $0.id == c.id }?.inInbox == true, "⌘Z puts it back in the inbox")
        XCTAssertTrue(store.commands.map(\.title).contains("Mark as junk"), "in the ⌘K palette")
        let menu = store.conversationEntries(c)
        XCTAssertTrue(menu.contains { $0.title == "Mark as junk" }, "in the right-click menu")
        XCTAssertTrue(menu.first { $0.title == "Move to" }?.submenu?.contains { $0.title == "Spam" } == true, "and under Move to")
        XCTAssertTrue(store.acceptsDrop("Spam"))
        XCTAssertTrue(store.drop(c.id, on: "Spam"))
        XCTAssertNil(store.allConversations.first { $0.id == c.id }, "dropped on Spam: junked")
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

    /// ⌘K must put the cursor in the palette's text box: typing right away has to land there, no click needed.
    func testCommandKPutsCursorInPaletteBox() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: PaletteHost().environmentObject(store)) // palette pops in over a live window, like MainView
        win.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        press("k", code: 40, .command); XCTAssertTrue(store.paletteOpen)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(win.firstResponder is NSTextView, "⌘K palette text box has the keyboard focus")
        win.orderOut(nil); resetUI()
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

    // MARK: Formatting in a draft (bold, italic, links; issue #13)

    func testDraftBoldItalicAndLinkKeys() {
        var body = "Hi Bob see the plan"
        let fmt = BodyFormatter()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: ComposeBody(text: Binding(get: { body }, set: { body = $0 }), fmt: fmt).frame(width: 560, height: 300))
        win.makeKeyAndOrderFront(nil)
        defer { win.orderOut(nil); resetUI() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let tv = try! XCTUnwrap(fmt.textView)
        XCTAssertEqual(tv.string, "Hi Bob see the plan")
        win.makeFirstResponder(tv)
        @discardableResult func cmd(_ c: String) -> Bool {
            tv.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: win.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!)
        }

        // ⌘K inside a draft is for links; it must not open the palette over it.
        store.composing = ComposeModel(draft: Draft(from: me), context: nil)
        XCTAssertFalse(press("k", code: 40, .command)); XCTAssertFalse(store.paletteOpen)

        tv.setSelectedRange(NSRange(location: 3, length: 3))   // "Bob"
        XCTAssertTrue(fmt.hasSelection, "selecting text shows the format bar")
        XCTAssertTrue(cmd("b")); XCTAssertEqual(body, "Hi **Bob** see the plan")
        XCTAssertTrue(cmd("i")); XCTAssertEqual(body, "Hi ***Bob*** see the plan")
        cmd("b"); cmd("i"); XCTAssertEqual(body, "Hi Bob see the plan", "pressing again turns it off")

        tv.setSelectedRange(NSRange(location: 11, length: 8))  // "the plan"
        XCTAssertTrue(cmd("k")); XCTAssertEqual(fmt.link?.text, "the plan", "⌘K opens the link card with the selected words")
        fmt.applyLink(text: "our plan", url: "x.com/p")
        XCTAssertEqual(body, "Hi Bob see [our plan](https://x.com/p)", "custom text, and https:// added")
        XCTAssertNil(fmt.link)

        tv.setSelectedRange(NSRange(location: 13, length: 0))  // caret inside the link
        cmd("k")
        XCTAssertEqual(fmt.link?.url, "https://x.com/p"); XCTAssertEqual(fmt.link?.existing, true, "⌘K on a link edits it")
        fmt.removeLink(); XCTAssertEqual(body, "Hi Bob see our plan")

        // Text written by AI, a snippet or an agent shows formatted.
        fmt.show("**Thanks** [Maya](mailto:maya@x.com)")
        XCTAssertEqual(tv.string, "Thanks Maya"); XCTAssertEqual(fmt.markup(), "**Thanks** [Maya](mailto:maya@x.com)")
    }

    /// Typing a name in To/Cc/Bcc: Tab moves through the people suggested (and wraps), Return adds the highlighted one.
    func testRecipientTabCyclesSuggestionsAndReturnAddsTheHighlightedOne() {
        let ann = Address(name: "Ann Lee", email: "ann@x.com"), andy = Address(name: "Andy Roe", email: "andy@y.com")
        var pick = 0
        for want in [1, 0, 1] {
            let r = recipientKey(.tab, field: "an", suggestions: [ann, andy], pick: pick)
            XCTAssertEqual(r?.field, "an", "Tab doesn't add anyone"); XCTAssertEqual(r?.pick, want); pick = r?.pick ?? 0
        }
        XCTAssertEqual(recipientKey(.enter, field: "sam@z.com, an", suggestions: [ann, andy], pick: pick)?.field,
                       "sam@z.com, Andy Roe <andy@y.com>, ", "Return adds the second person after tabbing to them")
        XCTAssertEqual(recipientKey(.enter, field: "an", suggestions: [ann, andy], pick: 0)?.field, "Ann Lee <ann@x.com>, ")
        XCTAssertNil(recipientKey(.tab, field: "zz", suggestions: [], pick: 0), "nothing suggested: Tab moves on as usual")
        XCTAssertNil(recipientKey(.enter, field: "zz", suggestions: [], pick: 0), "and Return turns what's typed into a chip")
    }

    func testFormattedDraftSendsAsHTMLWithTheLink() {
        var d = Draft(from: me); d.to = "maya@northwind.co"; d.subject = "Plan"; d.body = "See **this** [plan](https://x.com/p)."
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("multipart/alternative"))
        let html = composeHTML(d)!
        XCTAssertTrue(html.contains("See <b>this</b> <a href=\"https://x.com/p\">plan</a>."))
        XCTAssertEqual(fullBody(d), "See this plan (https://x.com/p).")
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

    func testReplyAndForwardAnEarlierEmailInTheThread() {
        let c = store.allConversations.first { $0.messages.count > 1 }!
        let older = c.messages.first { $0.id != c.latest.id && !$0.labelIds.contains("DRAFT") }!
        store.selectedID = c.id
        store.reply(all: false, to: older)
        XCTAssertEqual(store.composing?.draft.inReplyTo, older.messageIdHeader, "the reply answers the email you picked, not the newest")
        XCTAssertTrue(buildRaw(store.composing!.draft).contains("In-Reply-To: \(older.messageIdHeader)"))
        store.composing = nil
        store.forward(older)
        XCTAssertTrue(store.composing?.draft.quoted?.contains("From: \(older.from)\nDate: \(older.date)") ?? false, "forward carries the email you picked")
    }

    func testNamedFromAddressFindsItsAccount() {
        let a = store.state.accounts.first!
        XCTAssertEqual(store.account(for: "Danny Chait <\(a)>"), a, "a From with a name still belongs to its account")
        XCTAssertEqual(store.account(for: a.uppercased()), a)
    }

    func testAnAliasOnTwoAccountsSendsThroughTheOnePicked() {
        guard store.state.accounts.count >= 2 else { return }
        let a = store.state.accounts[0], b = store.state.accounts[1]
        store.state.aliases[a] = ["shared@alias.example"]; store.state.aliases[b] = ["shared@alias.example"]
        defer { store.state.aliases[a] = nil; store.state.aliases[b] = nil }
        let m = ComposeModel(draft: Draft(from: a, account: a), context: nil)
        store.changeFrom(m, to: "shared@alias.example", account: b)
        XCTAssertEqual(store.account(of: m.draft), b, "picked under the second account: saves and sends through it")
        store.changeFrom(m, to: "shared@alias.example", account: a)
        XCTAssertEqual(store.account(of: m.draft), a)
    }

    func testUnreadOnlyKeepsTheOpenedEmailInPlace() {
        store.unreadOnly = true; defer { store.unreadOnly = false }
        let v = store.visible
        XCTAssertGreaterThanOrEqual(v.count, 2, "the sample inbox has unread mail")
        guard v.count >= 2 else { return }
        store.open(v[0])                                   // opening marks it read
        XCTAssertEqual(store.visible.first?.id, v[0].id, "the email you're reading keeps its row")
        press("j", code: 38)
        XCTAssertEqual(store.selectedID, v[1].id, "J goes to the next unread email, not past it")
    }

    func testDraggingAnEmailOntoSidebarFolders() {
        let c = store.allConversations.first { $0.inInbox && !$0.isStarred }!
        XCTAssertTrue(store.acceptsDrop("Done") && store.acceptsDrop("Trash") && store.acceptsDrop("Inbox") && store.acceptsDrop("Starred"))
        XCTAssertFalse(store.acceptsDrop("Sent"), "folders Keymail fills itself don't take drops")
        XCTAssertTrue(store.drop(c.id, on: "Starred"))
        XCTAssertTrue(store.allConversations.first { $0.id == c.id }!.isStarred, "dropped on Starred: starred")
        XCTAssertTrue(store.drop(c.id, on: "Done"))
        XCTAssertFalse(store.allConversations.first { $0.id == c.id }!.inInbox, "dropped on Done: out of the inbox")
        XCTAssertTrue(store.drop(c.id, on: "Inbox"))
        XCTAssertTrue(store.allConversations.first { $0.id == c.id }!.inInbox, "dropped on Inbox: back in")
        XCTAssertTrue(store.drop(c.id, on: "Trash"))
        XCTAssertNil(store.allConversations.first { $0.id == c.id }, "dropped on Trash: deleted")
        XCTAssertFalse(store.drop("no-such-email", on: "Done"))
    }

    func testRightClickMenuHasMoveTo() {
        let c = store.allConversations.first { $0.inInbox }!
        let move = store.conversationEntries(c).first { $0.title == "Move to" }
        XCTAssertNotNil(move, "right-click menu has Move to")
        let places = move?.submenu?.map(\.title) ?? []
        XCTAssertTrue(places.contains("Done") && places.contains("Trash"))
        XCTAssertFalse(places.contains("Inbox"), "an email already in the inbox isn't offered the inbox")
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
        store.goTab(otherTab); store.goFolder("Inbox")
        XCTAssertEqual(store.tabName, inboxTab, "Go to Inbox lands on the one inbox, not an empty Important tab")
        XCTAssertEqual(AppStore().tabName, inboxTab, "and the app opens on it after a relaunch")
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

    // MARK: Finishing the last unread email

    func markAllRead(except keep: Set<String>) {
        for (k, m) in store.messages where !keep.contains(m.account + "|" + m.threadId) { store.messages[k]?.labelIds.removeAll { $0 == "UNREAD" } }
    }

    func testDoneOnTheLastUnreadEmailGoesBackToTheInbox() {
        let v = store.visible
        markAllRead(except: [v[0].id])
        store.selectedID = v[0].id; store.open(v[0])
        press("e", code: 14)
        XCTAssertFalse(store.threadOpen, "no unread left: back to the inbox")
    }

    func testDoneWithUnreadLeftOpensTheNextEmail() {
        let v = store.visible
        markAllRead(except: [v[0].id, v[2].id])
        store.selectedID = v[0].id; store.open(v[0])
        press("e", code: 14)
        XCTAssertTrue(store.threadOpen, "unread mail left: the next email opens")
    }

    func testTurningTheSettingOffKeepsOpeningTheNextEmail() {
        UserDefaults.standard.set(false, forKey: "backToInboxWhenDone")
        defer { UserDefaults.standard.removeObject(forKey: "backToInboxWhenDone") }
        let v = store.visible
        markAllRead(except: [v[0].id])
        store.selectedID = v[0].id; store.open(v[0])
        press("#", code: 20, .shift)
        XCTAssertTrue(store.threadOpen, "setting off: delete opens the next email as before")
    }

    /// Issue #4: mail you mark done must show in Done right away.
    func testDoneShowsJustArchivedMailRightAway() {
        let c = store.selected!
        press("e", code: 14)
        store.goFolder("Done")
        XCTAssertFalse(store.threadOpen, "Done leaves the open email at once")
        XCTAssertTrue(store.searchResults?.contains(c.id) ?? false, "the email you just marked done is listed")
        XCTAssertTrue(store.visible.contains { $0.id == c.id })
    }

    // MARK: Keyboard-only conversation actions

    func threadWithSeveral() -> Conversation {
        let c = store.allConversations.first { $0.messages.count > 2 }!
        store.selectedID = c.id; store.open(c); store.threadToggled = []
        return c
    }

    func testSpaceOpensTheNextCollapsedEmail() {
        let c = threadWithSeveral()
        let collapsed = c.messages.filter { !store.isOpen($0, in: c) }.count
        press(" ", code: 49)
        XCTAssertEqual(c.messages.filter { !store.isOpen($0, in: c) }.count, collapsed - 1, "Space opens one more")
    }

    func testShiftOOpensAndClosesAll() {
        let c = threadWithSeveral()
        press("O", code: 31, .shift)
        XCTAssertTrue(c.messages.allSatisfy { store.isOpen($0, in: c) }, "⇧O opens every email")
        press("O", code: 31, .shift)
        XCTAssertEqual(c.messages.filter { store.isOpen($0, in: c) }.map(\.key), [c.latest.key], "again: only the latest stays open")
    }

    func testDotTogglesEarlierMessages() {
        let c = threadWithSeveral()
        press(".", code: 47)
        XCTAssertTrue(store.quotedShown.contains(c.latest.key), ". shows earlier messages")
        press(".", code: 47)
        XCTAssertFalse(store.quotedShown.contains(c.latest.key), ". hides them again")
    }

    func testPaletteReachesAttachmentsAndPeople() {
        let c = store.allConversations.first { $0.messages.count > 1 }!
        var m = c.latest
        m.attachments = [AttachmentRef(id: "a1", name: "Q3 plan.pdf", mimeType: "application/pdf", size: 1000)]
        store.messages[m.key] = m
        store.selectedID = c.id
        let titles = store.commands.map(\.title)
        XCTAssertTrue(titles.contains("Open attachment: Q3 plan.pdf"))
        XCTAssertTrue(titles.contains("Save attachment: Q3 plan.pdf"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("Copy sender address") })
        XCTAssertTrue(titles.contains("Show or hide earlier messages"))
    }

    func testRContinuesYourDraftInsteadOfStartingAnother() {
        let c = store.allConversations.first { $0.messages.count > 1 }!
        let draft = Message(id: "d1", threadId: c.threadId, account: me, from: me, to: "sam@northwind.co", subject: "Re: x",
                            date: Date().addingTimeInterval(120), labelIds: ["DRAFT"], text: "Half-written reply")
        store.messages[draft.key] = draft
        store.selectedID = c.id
        press("r", code: 15)
        XCTAssertEqual(store.composing?.draft.body.contains("Half-written reply"), true, "R opens the draft you started")
    }

    // MARK: Split layout

    func testSplitLayoutKeysOpenWhatYouMoveTo() {
        store.setInboxLayout("split")
        defer { store.setInboxLayout("list") }
        let v = store.visible
        store.selectedID = v[0].id
        press("j", code: 38)
        XCTAssertEqual(store.selectedID, v[1].id, "J moves down in the split list")
        XCTAssertFalse(store.allConversations.first { $0.id == v[1].id }!.isUnread, "and opens it in the reading pane (marked read)")
        press("e", code: 14)
        XCTAssertFalse(store.allConversations.first { $0.id == v[1].id }!.inInbox, "E still marks done")
    }

    // MARK: Where replies open

    func testReplyInsideTheConversationWhenTurnedOn() {
        UserDefaults.standard.set(true, forKey: "replyInline")
        defer { UserDefaults.standard.removeObject(forKey: "replyInline") }
        store.open(store.selected!)
        press("r", code: 15)
        XCTAssertEqual(store.composing?.inline, true, "R replies under the conversation")
        XCTAssertEqual(store.composing?.context?.id, store.selectedID)
        XCTAssertTrue(store.composing?.draft.subject.hasPrefix("Re:") ?? false)
    }

    func testReplyOpensItsOwnWindowByDefault() {
        store.open(store.selected!)
        press("r", code: 15)
        XCTAssertEqual(store.composing?.inline, false, "default: a separate window")
        XCTAssertFalse(store.modalOpen, "the inbox isn't dimmed behind a compose card anymore")
    }

    // MARK: Stream and Filmstrip layouts

    func testStreamAndFilmstripKeysMoveAndRead() {
        for layout in ["stream", "film"] {
            resetUI()
            store.setInboxLayout(layout)
            let v = store.visible
            store.selectedID = v[0].id
            press("j", code: 38)
            XCTAssertEqual(store.selectedID, v[1].id, "\(layout): J moves to the next email")
            XCTAssertFalse(store.allConversations.first { $0.id == v[1].id }!.isUnread, "\(layout): and reads it")
        }
        store.setInboxLayout("stream")
        press(" ", code: 49); XCTAssertTrue(store.streamExpanded.contains(store.selectedID!), "stream: Space shows the full email")
        press(" ", code: 49); XCTAssertFalse(store.streamExpanded.contains(store.selectedID!), "Space again collapses it")
        store.setInboxLayout("film")
        let v = store.visible
        store.selectedID = v[1].id
        press("", code: 124); XCTAssertEqual(store.selectedID, v[2].id, "filmstrip: → flips forward")
        press("", code: 123); XCTAssertEqual(store.selectedID, v[1].id, "filmstrip: ← flips back")
        store.setInboxLayout("list")
        press("", code: 123); XCTAssertTrue(store.sidebarOpen, "list: ← still opens folders")
    }

    // MARK: Agentic layout (preview)

    func testAgenticKeysMoveAndApproveRunsThePlan() {
        store.setInboxLayout("agent")
        defer { store.setInboxLayout("list") }
        let v = store.visible
        store.selectedID = v[0].id
        press("j", code: 38)
        XCTAssertEqual(store.selectedID, v[1].id, "agentic: J moves to the next email")
        XCTAssertFalse(store.allConversations.first { $0.id == v[1].id }!.isUnread, "and reads it")

        let c = store.selected!
        XCTAssertFalse(press("\r", code: 36, .command), "⌘↵ does nothing until there's a plan")
        store.agentPlans[store.instantKey(c)] = .ready(AgentPlan(headline: "Confirm Thursday", summary: "", steps: [
            .init(kind: .reply, detail: "Say yes", body: "Thursday works. See you then."),
            .init(kind: .star, detail: ""), .init(kind: .archive, detail: ""),
        ]))
        XCTAssertTrue(press("\r", code: 36, .command), "⌘↵ approves the plan")
        let sent = store.pendingSends.last?.draft
        XCTAssertEqual(sent?.body.hasPrefix("Thursday works. See you then."), true, "the planned reply goes out (with Undo Send)")
        XCTAssertFalse(sent?.inReplyTo.isEmpty ?? true, "as a reply in the same thread")
        let after = store.allConversations.first { $0.id == c.id }!
        XCTAssertTrue(after.isStarred, "star ran")
        XCTAssertFalse(after.inInbox, "archive ran last")
        store.undo()
        XCTAssertTrue(store.pendingSends.isEmpty, "⌘Z still cancels the send")
    }

    func testAgenticDeclineAndEditReply() {
        store.setInboxLayout("agent")
        defer { store.setInboxLayout("list") }
        let c = store.selected!, key = store.instantKey(c)
        let plan = AgentPlan(headline: "Reply", summary: "", steps: [.init(kind: .reply, detail: "", body: "Sounds good."), .init(kind: .archive, detail: "")])
        store.agentPlans[key] = .ready(plan)
        store.editAgentReply()
        XCTAssertEqual(store.composing?.draft.body.hasPrefix("Sounds good."), true, "Edit opens the reply to change")
        XCTAssertEqual(store.composing?.inline, false, "in its own window: the pane shows the plan, not the thread")
        XCTAssertEqual(store.agentPlan(c), .ready(AgentPlan(headline: "Reply", summary: "", steps: [.init(kind: .archive, detail: "")])),
                       "and Approve then does only the rest")
        store.composing = nil
        store.declineAgentPlan()
        XCTAssertEqual(store.agentPlan(c), .declined)
        XCTAssertFalse(press("\r", code: 36, .command), "a declined plan can't be approved")
        XCTAssertTrue(store.allConversations.first { $0.id == c.id }!.inInbox, "declining leaves the email alone")
        store.openPalette("agentic")
        XCTAssertNotEqual(store.filteredCommands.first?.title.hasPrefix("Layout: agentic"), true, "the palette hides the layout you're on")
        store.paletteOpen = false
        store.setInboxLayout("list")
        store.openPalette("agentic")
        XCTAssertEqual(store.filteredCommands.first?.title.hasPrefix("Layout: agentic"), true, "⌘K reaches the Agentic layout")
        press("\r", code: 36)
        XCTAssertEqual(store.inboxLayout, "agent")
    }

    /// A plan (or a declined one) survives quitting and reopening, so it isn't planned again; half-finished ones don't.
    func testAgenticPlansAreKeptAfterQuittingAndDroppedWhenTheEmailLeaves() {
        store.setInboxLayout("agent")
        defer { store.setInboxLayout("list") }
        let v = store.visible
        let plan = AgentPlan(headline: "Archive it", summary: "", steps: [.init(kind: .archive, detail: "")])
        let (k0, k1, k2) = (store.instantKey(v[0]), store.instantKey(v[1]), store.instantKey(v[2]))
        store.agentPlans = [k0: .ready(plan), k1: .declined, k2: .loading]
        let reopened = AppStore()
        XCTAssertEqual(reopened.agentPlans[k0], .ready(plan), "the plan is still there after reopening")
        XCTAssertEqual(reopened.agentPlans[k1], .declined, "so is a declined one")
        XCTAssertNil(reopened.agentPlans[k2], "one still being planned starts over")
        store.selectedID = v[0].id
        XCTAssertTrue(press("\r", code: 36, .command), "⌘↵ approves the saved plan")
        store.pruneAgentPlans()
        XCTAssertNil(store.agentPlans[k0], "archived: its plan is forgotten")
        XCTAssertEqual(store.agentPlans[k1], .declined, "still in the inbox: kept")
    }

    // MARK: Folders beside the inbox

    func testPinnedFoldersNeverCloseAndArrowsOnlyMoveTheKeyboard() {
        store.setInboxLayout("list"); store.setFoldersPinned(true)
        defer { store.setFoldersPinned(false) }
        let v = store.visible
        store.selectedID = v[0].id
        let folderBefore = store.folder
        press("", code: 123)
        XCTAssertTrue(store.foldersVisible && store.sidebarFocused, "← moves the keyboard to the folders")
        press("", code: 125); press("", code: 125)
        XCTAssertEqual(store.folder, folderBefore, "↑/↓ only move the highlight")
        XCTAssertEqual(store.selectedID, v[0].id, "and leave the email selection alone")
        press("", code: 124)
        XCTAssertFalse(store.sidebarFocused, "→ goes back to the inbox")
        XCTAssertTrue(store.foldersVisible, "pinned: the folders stay")
        XCTAssertEqual(store.folder, folderBefore, "nothing was opened")
        press("", code: 123); press("", code: 123)
        XCTAssertTrue(store.foldersVisible, "pinned: ← never closes them")
        press("", code: 125); press("\r", code: 36)
        XCTAssertNotEqual(store.folder, folderBefore, "Return opens the highlighted folder")
        XCTAssertTrue(store.foldersVisible, "pinned: still visible after picking")
        XCTAssertFalse(store.sidebarFocused)
    }

    func testManualFoldersOpenWithLeftAndCloseAfterPicking() {
        store.setInboxLayout("list"); store.setFoldersPinned(false)
        XCTAssertFalse(store.foldersVisible, "off: hidden until you open them")
        press("", code: 123)
        XCTAssertTrue(store.foldersVisible && store.sidebarFocused, "← opens them")
        press("", code: 124)
        XCTAssertFalse(store.foldersVisible, "→ closes them")
        press("", code: 123); press("", code: 125); press("\r", code: 36)
        XCTAssertFalse(store.foldersVisible, "picking a folder with Return closes them")
        press("", code: 123); press("", code: 123)
        XCTAssertFalse(store.foldersVisible, "← again closes them")
    }

    func testPinnedContextPanelIgnoresRightArrow() {
        store.setContextPinned(true)
        press("", code: 124); XCTAssertTrue(store.contextVisible, "pinned: → never hides the context panel")
        store.setContextPinned(false)
        XCTAssertFalse(store.contextVisible)
        press("", code: 124); XCTAssertTrue(store.contextVisible, "off: → opens it")
        press("", code: 124); XCTAssertFalse(store.contextVisible, "and closes it")
        store.setContextPinned(true)
    }

    // MARK: Sender name and aliases

    func testSentMailCarriesYourNameAndChosenAlias() {
        store.state.senderNames[me] = "Dan Chait"
        store.state.aliases[me] = ["danchait@icloud.com"]
        store.state.defaultFrom[me] = "danchait@icloud.com"
        XCTAssertEqual(store.sendAddress(me), "danchait@icloud.com", "new email comes from the alias you picked")
        XCTAssertEqual(store.label(me), "danchait@icloud.com", "and that's the address shown for the account")
        XCTAssertEqual(store.namedFrom("danchait@icloud.com"), "Dan Chait <danchait@icloud.com>", "recipients see your Name")
        XCTAssertEqual(store.namedFrom("Other <x@y.co>"), "Other <x@y.co>", "a From that already has a name is left alone")
        store.state.accountNames[me] = "Personal"
        XCTAssertEqual(store.label(me), "Personal", "a Description wins for the label")
    }

    // MARK: Sent and Archive copies from other mail apps

    func testFolderCopiesJoinTheirConversationAndShowInSent() {
        let c = store.allConversations.first { $0.messages.count > 1 }!
        var sent = Message(id: "sent:42", threadId: c.threadId, account: me, from: me, to: "sam@northwind.co",
                           subject: "Re: \(c.latest.subject)", date: Date().addingTimeInterval(300), labelIds: ["SENT"],
                           messageIdHeader: "<from-mac-mail@x>", text: "Sent from Mac Mail")
        sent.references = c.latest.messageIdHeader
        store.messages[sent.key] = sent
        let joined = store.allConversations.first { $0.id == c.id }!
        XCTAssertTrue(joined.messages.contains { $0.id == "sent:42" }, "a reply sent from another app joins its conversation")
    }
}


// MARK: Calendar (G C)

extension CoreFlowsTests {
    func openCalendarWithEvents() async {
        press("g", code: 5); press("c", code: 8)
        await store.loadCalendar()
    }

    func testGCOpensTheCalendarAndGIGoesBackToTheInbox() async {
        await openCalendarWithEvents()
        XCTAssertTrue(store.calendarOpen, "G then C opens the calendar")
        XCTAssertFalse(store.calEvents.isEmpty, "this week's events load")
        press("g", code: 5); press("i", code: 34)
        XCTAssertFalse(store.calendarOpen, "G then I goes back to mail")
        XCTAssertNil(store.folder, "to the inbox")
        await openCalendarWithEvents()
        press("g", code: 5); press("s", code: 1)
        XCTAssertFalse(store.calendarOpen); XCTAssertEqual(store.folder, "Starred", "other G keys still go to their folder")
    }

    func testTopBarButtonAndPaletteSwitchViews() async {
        XCTAssertTrue(store.commands.contains { $0.title == "Go to Calendar" }, "⌘K offers the calendar")
        store.commands.first { $0.title == "Go to Calendar" }!.run()
        XCTAssertTrue(store.calendarOpen)
        XCTAssertTrue(store.commands.contains { $0.title == "Go to Inbox" }, "and the way back")
        store.openCalendar(); store.closeCalendar()       // what the top-bar Calendar / Mail button runs
        XCTAssertFalse(store.calendarOpen)
    }

    func testCalendarKeysMoveBetweenEventsAndViews() async {
        await openCalendarWithEvents()
        let order = store.calShown.sorted { $0.start < $1.start }
        XCTAssertGreaterThan(order.count, 2)
        press("j", code: 38); XCTAssertEqual(store.calSelected, order[0].id, "J selects the first event and opens its card")
        press("j", code: 38); XCTAssertEqual(store.calSelected, order[1].id, "J moves to the next")
        press("", code: 125); XCTAssertEqual(store.calSelected, order[2].id, "↓ too")
        press("k", code: 40); XCTAssertEqual(store.calSelected, order[1].id, "K moves back")
        press("\u{1b}", code: 53); XCTAssertNil(store.calSelected, "Esc closes the card")
        XCTAssertTrue(store.calendarOpen, "but stays in the calendar")

        press("m", code: 46); XCTAssertEqual(store.calView, .month, "M: month")
        press("d", code: 2); XCTAssertEqual(store.calView, .day, "D: day")
        press("w", code: 13); XCTAssertEqual(store.calView, .week, "W: week")
        let start = store.calDate
        press("l", code: 37); XCTAssertEqual(store.calDate, stepDate(start, .week, by: 1), "L: next week")
        press("h", code: 4); press("h", code: 4); XCTAssertEqual(store.calDate, stepDate(start, .week, by: -1), "H: previous week")
        press("t", code: 17); XCTAssertTrue(Calendar.current.isDateInToday(store.calDate), "T: today")

        press("c", code: 8); XCTAssertTrue(store.quickAddOpen, "C: new event")
        store.quickAddOpen = false
        press("\u{1b}", code: 53); XCTAssertFalse(store.calendarOpen, "Esc with nothing open goes back to mail")
    }

    func testJoinEditAndDeleteFromTheKeyboard() async {
        await openCalendarWithEvents()
        let call = store.calShown.first { $0.conference != nil }!
        store.calSelected = call.id
        press("J", code: 38, .shift); XCTAssertEqual(store.banner, "Opening \(call.conference!.kind.rawValue)…", "Shift J joins the video call")
        press("e", code: 14); XCTAssertEqual(store.calEditing, call.id, "E edits the event right in its card")
        press("\u{1b}", code: 53); XCTAssertNil(store.calEditing, "Esc leaves editing first")
        XCTAssertEqual(store.calSelected, call.id, "and keeps the card open")
        press("", code: 51)
        XCTAssertFalse(store.calEvents.contains { $0.id == call.id }, "⌫ deletes the selected event")
        XCTAssertNil(store.calSelected)
        demoCalendarEvents.append(call)   // leave the shared sample week as it was
    }

    func testQuickAddPutsTheEventOnTheCalendar() async {
        await openCalendarWithEvents()
        store.quickAdd("Lunch with Priya tomorrow 1pm at Tartine")
        await store.loadCalendar()
        let added = store.calEvents.first { $0.title == "Lunch with Priya" }
        XCTAssertNotNil(added, "the typed event is added")
        XCTAssertEqual(added?.location, "Tartine")
        demoCalendarEvents.removeAll { $0.title == "Lunch with Priya" }
    }

    func testCalendarPanelsFollowTheSameArrows() async {
        await openCalendarWithEvents()
        store.setFoldersPinned(false)
        press("", code: 123); XCTAssertTrue(store.foldersVisible, "← opens the calendar list")
        press("", code: 123); XCTAssertFalse(store.foldersVisible, "← again closes it")
        store.setContextPinned(false)
        press("", code: 124); XCTAssertTrue(store.contextVisible, "→ opens the context panel")
        press("", code: 124); XCTAssertFalse(store.contextVisible)
        store.setContextPinned(true)
        press("", code: 124); XCTAssertTrue(store.contextVisible, "pinned in Settings: → never hides it")
    }

    func waitForInviteAnswer() async { for _ in 0..<50 where store.inviteSending != nil { await Task.yield() }; await Task.yield() }

    func testYMaybeNAnswerTheInviteYouAreReading() async throws {
        let c = try XCTUnwrap(store.allConversations.first { $0.latest.calendar != nil }, "the sample inbox has an invite")
        let m = c.latest, inv = try XCTUnwrap(m.calendar.flatMap(parseInvite))
        store.selectedID = c.id; store.open(c)
        await store.loadInviteDay(inv, message: m)
        XCTAssertEqual(store.inviteDay?.uid, inv.uid, "the invite's day loads for the strip")
        XCTAssertTrue(store.inviteDay!.events.contains { $0.start < inv.end! && $0.end > inv.start! }, "and shows what it clashes with")
        press("y", code: 16); await waitForInviteAnswer()
        XCTAssertEqual(store.inviteAnswers[inv.uid], .accepted, "Y says yes")
        press("?", code: 44, .shift); await waitForInviteAnswer()
        XCTAssertEqual(store.inviteAnswers[inv.uid], .tentative, "? says maybe")
        press("n", code: 45); await waitForInviteAnswer()
        XCTAssertEqual(store.inviteAnswers[inv.uid], .declined, "N says no")
    }

    func testAnswerKeysLeaveOtherEmailsAlone() {
        let c = store.allConversations.first { $0.latest.calendar == nil }!
        store.selectedID = c.id; store.open(c)
        store.openInvite = nil
        press("y", code: 16)
        XCTAssertTrue(store.inviteAnswers.isEmpty, "Y does nothing on an email without an invite")
    }

    func testAnsweringAnInviteInTheCalendar() async {
        await openCalendarWithEvents()
        let e = store.calShown.first { $0.unanswered }!
        store.calSelected = e.id
        press("y", code: 16)
        XCTAssertFalse(store.calEvents.first { $0.id == e.id }!.unanswered, "Y answers the selected invite in the calendar")
        for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id { demoCalendarEvents[i].unanswered = true }
    }

    func testInviteEventsLinkToTheirEmailAndOOpensIt() async {
        await openCalendarWithEvents()
        let e = store.calShown.first { $0.uid == "q4-roadmap@demo.keymail" }!
        let c = store.linkedConversation(e)
        XCTAssertNotNil(c, "an invite's event links to the invite email")
        store.calSelected = e.id
        press("o", code: 31)
        XCTAssertFalse(store.calendarOpen, "O opens the linked email")
        XCTAssertTrue(store.threadOpen); XCTAssertEqual(store.selectedID, c?.id)
    }

    func testBlockingTimeForAnEmailLinksTheNewEvent() async {
        let c = store.selected!
        store.startPlacing(c.id)
        XCTAssertTrue(store.calendarOpen); XCTAssertEqual(store.placingEmail, c.id, "the calendar waits for a time")
        press("\u{1b}", code: 53)
        XCTAssertNil(store.placingEmail, "Esc cancels"); XCTAssertTrue(store.calendarOpen)
        store.startPlacing(c.id)
        let when = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        store.placeEmail(at: when)
        await store.loadCalendar()
        let e = store.calEvents.first { $0.start == when && $0.title == c.latest.subject }
        XCTAssertNotNil(e, "clicking a time adds a 30-minute block")
        XCTAssertEqual(e.flatMap(store.linkedConversation)?.id, c.id, "linked to the email")
        store.calSelected = e?.id
        XCTAssertTrue(store.commands.contains { $0.title.hasPrefix("Open email:") }, "⌘K offers the email from the event")
        demoCalendarEvents.removeAll { $0.start == when && $0.title == c.latest.subject }
    }

    func testReturnHashAndTheOtherAnswerKeysInTheCalendar() async {
        await openCalendarWithEvents()
        press("\r", code: 36)
        XCTAssertEqual(store.calSelected, store.calShown.sorted { $0.start < $1.start }.first?.id, "Return opens the first event")
        let invite = store.calShown.first { $0.unanswered }!
        store.calSelected = invite.id
        press("?", code: 44, .shift)
        XCTAssertFalse(store.calEvents.first { $0.id == invite.id }!.unanswered, "? answers maybe")
        for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == invite.id { demoCalendarEvents[i].unanswered = true }
        await store.loadCalendar()
        store.calSelected = invite.id
        press("n", code: 45)
        XCTAssertFalse(store.calEvents.first { $0.id == invite.id }!.unanswered, "N answers no")
        for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == invite.id { demoCalendarEvents[i].unanswered = true }
        await store.loadCalendar()
        let victim = store.calShown.first { !$0.unanswered }!
        store.calSelected = victim.id
        press("#", code: 20, .shift)
        XCTAssertFalse(store.calEvents.contains { $0.id == victim.id }, "# deletes the selected event")
        demoCalendarEvents.append(victim)
    }

    func testBlockTimePaletteCommandWaitsForATime() {
        let cmd = store.commands.first { $0.title == "Block time on the calendar for this email" }
        XCTAssertNotNil(cmd, "⌘K offers blocking time for the selected email")
        cmd?.run()
        XCTAssertTrue(store.calendarOpen); XCTAssertEqual(store.placingEmail, store.selectedID)
    }

    func testOpenQuickAddNeverLetsKeysReachTheHiddenInbox() async {
        let c = store.selected!
        await openCalendarWithEvents()
        press("c", code: 8); XCTAssertTrue(store.quickAddOpen)
        press("e", code: 14)
        XCTAssertTrue(store.allConversations.first { $0.id == c.id }!.inInbox, "E while quick add is open doesn't mark the hidden email done")
        press("\u{1b}", code: 53)
        XCTAssertFalse(store.quickAddOpen, "Esc still closes quick add"); XCTAssertTrue(store.calendarOpen)
    }

    func testJPastTheLastEventMovesToTheNextWeek() async {
        await openCalendarWithEvents()
        let nextWeek = stepDate(store.calDate, .week, by: 1)
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: nextWeek)!
        let later = CalEvent(id: "demo:next-week", calendarId: "demo:work", title: "Next week thing", start: start, end: start.addingTimeInterval(3600))
        demoCalendarEvents.append(later)
        defer { demoCalendarEvents.removeAll { $0.id == later.id } }
        store.calSelected = store.calShown.sorted { $0.start < $1.start }.last?.id
        press("j", code: 38)
        for _ in 0..<20 where store.calSelected != later.id { await Task.yield() }
        XCTAssertEqual(store.calSelected, later.id, "J on the week's last event goes to next week's first")
    }

    func testMovingAnEventToAnotherCalendarAndChangingItsPlace() async {
        await openCalendarWithEvents()
        let e = store.calShown.first { $0.title == "Errands" }!
        let original = e.calendarId, place = e.location
        let dest = store.moveTargets(e).first { $0.id != e.calendarId }!
        store.calSelected = e.id
        let cmd = store.commands.first { $0.title == "Move Errands to \(dest.title)" }
        XCTAssertNotNil(cmd, "⌘K offers every calendar it can move to")
        cmd?.run()
        XCTAssertEqual(store.calEvents.first { $0.id == e.id }?.calendarId, dest.id, "the event moves")
        XCTAssertTrue(store.commands.contains { $0.title.hasPrefix("Directions to ") }, "and Apple Maps directions are offered for its place")
        store.setLocation(e, "Tartine, 18th St")
        XCTAssertEqual(store.calEvents.first { $0.id == e.id }?.location, "Tartine, 18th St", "the place changes")
        for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id {
            demoCalendarEvents[i].calendarId = original; demoCalendarEvents[i].location = place
        }
    }

    func testEditingAnEventInItsCardSavesIt() async {
        await openCalendarWithEvents()
        let e = store.calShown.first { $0.title == "Deep Work" }!
        let newStart = e.start.addingTimeInterval(3600)
        store.updateEvent(e, title: "Deep Work (moved)", start: newStart, end: newStart.addingTimeInterval(5400), notes: "No meetings")
        let saved = store.calEvents.first { $0.id == e.id }
        XCTAssertEqual(saved?.title, "Deep Work (moved)"); XCTAssertEqual(saved?.start, newStart); XCTAssertEqual(saved?.notes, "No meetings")
        store.updateEvent(e, title: "x", start: newStart, end: newStart, notes: "")
        XCTAssertEqual(store.calEvents.first { $0.id == e.id }?.title, "Deep Work (moved)", "an end before the start is refused")
        for i in demoCalendarEvents.indices where demoCalendarEvents[i].id == e.id { demoCalendarEvents[i] = e }
    }

    func testChangingACalendarsColor() async {
        await openCalendarWithEvents()
        let src = store.calSources.first!
        store.setCalendarColor(src.id, "#EE6AA6")
        XCTAssertEqual(store.calSource(src.id)?.colorHex, "#EE6AA6", "the chosen color is used")
        await store.loadCalendar()
        XCTAssertEqual(store.calSource(src.id)?.colorHex, "#EE6AA6", "and kept after reloading")
    }

    func testHidingACalendarHidesItsEvents() async {
        await openCalendarWithEvents()
        let id = store.calShown.first!.calendarId
        store.toggleCalendarHidden(id)
        XCTAssertFalse(store.calShown.contains { $0.calendarId == id })
        store.toggleCalendarHidden(id)
        XCTAssertTrue(store.calShown.contains { $0.calendarId == id })
    }
}

/// Same shape as MainView: the palette is an overlay that appears when paletteOpen flips.
private struct PaletteHost: View {
    @EnvironmentObject var store: AppStore
    var body: some View { Color.clear.overlay(alignment: .top) { if store.paletteOpen { PaletteView() } } }

}

@MainActor
extension CoreFlowsTests {
    // MARK: Clean up senders, Insights, ready drafts

    func runCommand(_ title: String) {
        store.openPalette(title)
        guard let i = store.filteredCommands.firstIndex(where: { $0.title == title }) else { return XCTFail("⌘K has \"\(title)\"") }
        store.runPalette(i)
    }

    func testCleanUpAndInsightsOpenFromThePaletteAndEscGoesBack() {
        runCommand("Clean up senders")
        XCTAssertEqual(store.toolScreen, .cleanup, "⌘K → Clean up senders")
        press("\u{1b}", code: 53); XCTAssertNil(store.toolScreen, "Esc goes back to the inbox")
        runCommand("Insights")
        XCTAssertEqual(store.toolScreen, .insights, "⌘K → Insights")
        runCommand("Clean up senders"); XCTAssertEqual(store.toolScreen, .cleanup, "and from there to Clean up")
        press("c", code: 8); XCTAssertNil(store.composing, "inbox keys don't leak into Clean up")
        press("g", code: 5); press("c", code: 8)
        XCTAssertTrue(store.calendarOpen, "G C still goes to the calendar"); XCTAssertNil(store.toolScreen)
        store.closeCalendar(); store.openTool(.insights)
        press("g", code: 5); press("i", code: 34); XCTAssertNil(store.toolScreen, "G I goes back to the inbox")
    }

    func testCleanUpKeysSelectArchiveKeepAndUndo() {
        let news = "hello@productweekly.example"
        store.openTool(.cleanup)
        let list = store.cleanupSenders
        let i = try! XCTUnwrap(list.firstIndex { $0.email == news }, "the sample newsletter is listed")
        store.cleanupIndex = 0
        for _ in 0..<i { press("j", code: 38) }
        XCTAssertEqual(store.cleanupIndex, i, "J moves down the senders")
        press("k", code: 40); press("j", code: 38); XCTAssertEqual(store.cleanupIndex, i, "K moves up")
        press("x", code: 7); XCTAssertEqual(store.cleanupSelected, [news], "X selects")
        press("x", code: 7); XCTAssertTrue(store.cleanupSelected.isEmpty, "X again unselects")
        press("e", code: 14)
        XCTAssertTrue(store.inboxConversations(from: news).isEmpty, "E archives everything from the sender")
        press("z", code: 6, .command)
        XCTAssertFalse(store.inboxConversations(from: news).isEmpty, "⌘Z puts it back")
        press("u", code: 32)
        XCTAssertTrue(store.inboxConversations(from: news).isEmpty, "U unsubscribes and archives")
        XCTAssertEqual(store.cleanupDone[news]?.hasPrefix("Unsubscribed"), true)
        press("z", code: 6, .command)
        let sender = store.cleanupSenders[0].email
        store.cleanupIndex = 0
        press("s", code: 1)
        XCTAssertTrue(store.state.cleanupKept.contains(sender), "S keeps a sender")
        XCTAssertFalse(store.cleanupSenders.contains { $0.email == sender }, "kept senders leave the list")
        press("\t", code: 48); XCTAssertEqual(store.cleanupFilter, .never, "Tab switches the filter")
    }

    func testReadyDraftSendsEditsAndGoesAway() throws {
        let c = try XCTUnwrap(store.allConversations.first { needsReply($0, me: store.me) }, "the sample inbox has an email that needs a reply")
        store.state.readyDrafts[c.id] = ReadyDraft(messageId: c.latest.id, text: "Sounds good, see you then.", why: ["Your writing style"], written: Date())
        store.selectedID = c.id; store.open(c)
        XCTAssertNotNil(store.readyDraft(c))
        XCTAssertTrue(store.commands.contains { $0.title == "Send ready draft" }, "⌘K offers the ready draft")
        press("r", code: 15)
        XCTAssertEqual(store.composing?.draft.body.hasPrefix("Sounds good, see you then."), true, "R opens the ready draft to edit")
        XCTAssertNil(store.readyDraft(c), "and it moves into the reply")
        store.composing = nil
        store.state.readyDrafts[c.id] = ReadyDraft(messageId: c.latest.id, text: "On it.", why: [], written: Date())
        press("\r", code: 36, .command)
        XCTAssertEqual(store.pendingSends.last?.draft.body.hasPrefix("On it."), true, "⌘↵ sends it, with Undo Send")
        press("z", code: 6, .command); store.composing = nil
        store.state.readyDrafts[c.id] = ReadyDraft(messageId: c.latest.id, text: "Maybe.", why: [], written: Date())
        press("#", code: 20, .shift)
        XCTAssertNil(store.state.readyDrafts[c.id], "deleting the email deletes its ready draft")
        press("z", code: 6, .command)
        store.state.readyDrafts[c.id] = ReadyDraft(messageId: c.latest.id, text: "Maybe.", why: [], written: Date())
        store.selectedID = c.id
        runCommand("Throw away ready draft")
        XCTAssertNil(store.readyDraft(c), "Throw away removes it")
        XCTAssertTrue(store.state.readyDrafts[c.id]?.discarded == true, "and Keymail won't write another for this email")
    }

    func testAfterASearchArrowsBrowseResultsAndOpenPanels() async {
        press("/", code: 44); XCTAssertTrue(store.searchOpen, "/ opens search")
        store.searchText = "launch"
        store.runSearch()
        for _ in 0..<50 where store.busy != nil { await Task.yield() }
        let v = store.visible
        XCTAssertFalse(v.isEmpty, "the search finds the sample email")
        store.selectedID = v.first?.id
        if v.count > 1 { press("", code: 125); XCTAssertEqual(store.selectedID, v[1].id, "↓ browses the results") }
        press("", code: 126); XCTAssertEqual(store.selectedID, v.first?.id, "↑ goes back up")
        press("", code: 123); XCTAssertTrue(store.foldersVisible, "← opens the folders panel")
        press("", code: 124); store.sidebarFocused = false
        press("/", code: 44); XCTAssertTrue(store.searchOpen, "/ goes back to the search box")
        let before = store.searchFocus
        press("/", code: 44); XCTAssertEqual(store.searchFocus, before + 1, "/ with the bar already open puts the cursor back in it")
    }

    func testEmailsWithADraftStayInTheInbox() throws {
        let c = try XCTUnwrap(store.allConversations.first { needsReply($0, me: store.me) })
        let before = store.shownTabs.first { (store.tabMembers[$0] ?? []).contains { $0.id == c.id } }
        store.state.splits.append(Split(name: "Needs reply", query: "is:drafted"))   // as first shipped, without "also in inbox"
        store.state = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(store.state))   // reload, like a relaunch
        store.state.readyDrafts[c.id] = ReadyDraft(messageId: c.latest.id, text: "Yes.", why: [], written: Date())
        XCTAssertTrue((store.tabMembers["Needs reply"] ?? []).contains { $0.id == c.id }, "it's in Needs reply")
        let tab = try XCTUnwrap(before)
        XCTAssertTrue((store.tabMembers[tab] ?? []).contains { $0.id == c.id }, "and still in \(tab)")
    }
}
