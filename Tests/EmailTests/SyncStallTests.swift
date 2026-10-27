import XCTest
import Network
@testable import Email
import EmailCore

/// A mail server that accepts the connection and then says nothing (what a dead connection looks like after sleep).
/// Keymail must give up and move on; before, it waited forever and all mail stopped until Keymail was quit.
final class SyncStallTests: XCTestCase {
    func testSilentMailServerTimesOutInsteadOfHangingSync() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { c in c.start(queue: .global()) }   // accept, never reply
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let old = IMAPConnection.silence
        IMAPConnection.silence = 1
        defer { IMAPConnection.silence = old }
        let start = Date()
        do {
            try await IMAPConnection(host: "127.0.0.1", port: listener.port!.rawValue).open()
            XCTFail("a silent server can't succeed")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "gave up instead of waiting forever")
    }
}

final class ICloudSignInTests: XCTestCase {
    /// Only a real password refusal signs an account out; a busy or throttling server is retried later.
    func testOnlyARealRefusalSignsTheAccountOut() {
        XCTAssertTrue(imapLoginRefusal("Mail server: NO [AUTHENTICATIONFAILED] Authentication failed."))
        XCTAssertTrue(imapLoginRefusal("Mail server: NO LOGIN failed"))
        XCTAssertFalse(imapLoginRefusal("Mail server: NO [UNAVAILABLE] Service temporarily unavailable"))
        XCTAssertFalse(imapLoginRefusal("Mail server: NO [LIMIT] Too many simultaneous connections"))
        XCTAssertFalse(imapLoginRefusal("Mail server: NO Please try again later"))
    }

    /// One stray "Authentication Failed" from iCloud no longer signs the account out: it takes 3 in a row,
    /// and a good sign-in in between starts the count over.
    func testOneStrayRefusalDoesNotSignOut() {
        let a = "test-refusal@icloud.com", t = Date()
        ICloud.setRejected(a, false); ICloud.refusals(reset: a)
        XCTAssertEqual(ICloud.refused(a, now: t), 1)
        XCTAssertEqual(ICloud.refused(a, now: t.addingTimeInterval(5)), 1, "more sign-ins in the same bad moment don't add strikes")
        XCTAssertEqual(ICloud.refused(a, now: t.addingTimeInterval(300)), 2)
        ICloud.refusals(reset: a)   // signed in fine
        XCTAssertEqual(ICloud.refused(a, now: t.addingTimeInterval(600)), 1, "the count starts over after a good sign-in")
        XCTAssertEqual(ICloud.refused(a, now: t.addingTimeInterval(900)), 2)
        XCTAssertEqual(ICloud.refused(a, now: t.addingTimeInterval(1200)), 3, "the third, minutes apart, is the one that signs out")
        ICloud.setRejected(a, false)
    }
}

@MainActor
final class ICloudTrashTests: XCTestCase {
    func testTrashReadsICloudsDeletedMessagesFolder() {
        XCTAssertEqual(ICloud.mailbox("trash").use, "\\Trash")
        XCTAssertEqual(ICloud.mailbox("trash").fallback, "Deleted Messages", "where Apple Mail and iCloud.com put deleted mail")
        XCTAssertEqual(ICloud.mailbox("sent").fallback, "Sent Messages")
        XCTAssertEqual(ICloud.mailbox("archive").fallback, "Archive")
        XCTAssertEqual(ICloud.mailbox("junk").use, "\\Junk", "Mark as junk goes to iCloud's Junk folder")
    }

    func testTrashFolderListsICloudDeletedMail() async throws {
        let store = AppStore()
        store.messages = [:]
        store.state = SavedState()
        let a = "me@icloud.com"
        store.state.accounts = [a]; store.state.icloud = [a]; store.state.onboarded = true
        var m = Message(id: "trash:7", threadId: "t7", account: a, from: "Ann <ann@x.com>", to: a, subject: "Deleted one", date: Date())
        m.labelIds = ["TRASH"]
        store.messages[m.key] = m
        store.goFolder("Trash")
        // The server fetch starts on the next turn of the main loop and fails fast here (no real account); wait it out.
        for _ in 0..<100 where store.searchResults?.isEmpty ?? true { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(store.searchResults, [a + "|t7"], "an iCloud email in Deleted Messages shows in Trash")
    }

    /// Clicking Sent or Trash lists what's already on this Mac straight away, every account, before any server answers.
    func testFoldersShowCachedMailInstantly() {
        let store = AppStore()
        store.messages = [:]
        store.state = SavedState()
        let g = "me@gmail.com", i = "me@icloud.com"
        store.state.accounts = [g, i]; store.state.icloud = [i]; store.state.onboarded = true
        for (acct, id, label) in [(g, "s1", "SENT"), (i, "sent:2", "SENT"), (i, "trash:3", "TRASH")] {
            var m = Message(id: id, threadId: "t-" + id, account: acct, from: acct, to: "ann@x.com", subject: id, date: Date())
            m.labelIds = [label]
            store.messages[m.key] = m
        }
        store.goFolder("Sent")
        XCTAssertEqual(store.searchResults, [g + "|t-s1", i + "|t-sent:2"], "no wait for the network")
        store.goFolder("Trash")
        XCTAssertEqual(store.searchResults, [i + "|t-trash:3"])
    }
}

@MainActor
final class NotificationRouteTests: XCTestCase {
    func testNotchStyleNeverFallsBackToCornerBannersWhileThereIsANotch() {
        XCTAssertEqual(Notifier.route(notchStyle: true, hasNotch: true, appActive: false, count: 1), .notch)
        XCTAssertEqual(Notifier.route(notchStyle: true, hasNotch: true, appActive: false, count: 9), .notchSummary, "a burst is one notch summary, not a system banner")
        XCTAssertEqual(Notifier.route(notchStyle: true, hasNotch: true, appActive: true, count: 1), .none, "in Keymail already: nothing pops up")
        XCTAssertEqual(Notifier.route(notchStyle: true, hasNotch: false, appActive: false, count: 1), .system, "lid closed: normal notifications")
        XCTAssertEqual(Notifier.route(notchStyle: false, hasNotch: true, appActive: false, count: 1), .system, "Banner style")
    }
}
