import XCTest
import EmailCore
@testable import Email

final class SignOutTests: XCTestCase {
    func testSignOutForgetsEverythingForThatAccountOnly() {
        let a = "me@gmail.com", b = "other@gmail.com"
        var s = SavedState()
        s.accounts = [a, b]; s.icloud = [a]; s.icloudLogins = [a: "me"]
        s.aliases = [a: ["alias@me.com"]]; s.defaultFrom = [a: "alias@me.com"]; s.accountNames = [a: "Work"]
        s.historyIds = [a: "1", b: "2"]; s.activeAccount = a
        s.snoozes = [Snooze(account: a, threadId: "t", until: .now, ifNoReply: false),
                     Snooze(account: b, threadId: "t", until: .now, ifNoReply: false)]
        s.followUps = [FollowUp(account: a, threadId: "t", sentAt: .now, due: .now)]
        s.scheduled = [ScheduledSend(draft: Draft(from: "Me <alias@me.com>"), at: .now, remindDays: nil),
                       ScheduledSend(draft: Draft(from: a), at: .now, remindDays: nil),
                       ScheduledSend(draft: Draft(from: b), at: .now, remindDays: nil)]
        s.signatures = [a: "x", "alias@me.com": "y", b: "z"]
        s.bumped = [a + "|t": .now, b + "|t": .now]; s.importance = [a + "|t": true, "boss@x.com": true]
        s.muted = [a + "|t", b + "|t"]; s.autoArchived = [a + "|t"]

        s.forget(a)

        XCTAssertEqual(s.accounts, [b]); XCTAssertNil(s.activeAccount)
        XCTAssertTrue(s.icloud.isEmpty && s.icloudLogins.isEmpty && s.aliases.isEmpty && s.defaultFrom.isEmpty && s.accountNames.isEmpty)
        XCTAssertEqual(s.historyIds, [b: "2"])
        XCTAssertEqual(s.snoozes.map(\.account), [b]); XCTAssertTrue(s.followUps.isEmpty)
        XCTAssertEqual(s.scheduled.map(\.draft.from), [b])
        XCTAssertEqual(s.signatures, [b: "z"])
        XCTAssertEqual(Array(s.bumped.keys), [b + "|t"]); XCTAssertEqual(s.importance, ["boss@x.com": true])
        XCTAssertEqual(s.muted, [b + "|t"]); XCTAssertTrue(s.autoArchived.isEmpty)
        // Fails if a new field is added to SavedState that still mentions the account.
        let json = String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
        XCTAssertFalse(json.contains("me@gmail.com") || json.contains("alias@me.com"), json)
    }
}
