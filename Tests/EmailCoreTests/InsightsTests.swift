import XCTest
@testable import EmailCore

final class InsightsTests: XCTestCase {
    let me: Set<String> = ["me@example.com"]
    let now = Date()
    func m(_ id: String, _ from: String, thread: String? = nil, hoursAgo: Double = 1, unread: Bool = false, sent: Bool = false,
           list: Bool = false, to: String = "me@example.com") -> Message {
        var labels = sent ? ["SENT"] : ["INBOX"]
        if unread { labels.append("UNREAD") }
        return Message(id: id, threadId: thread ?? id, account: "me@example.com", from: from, to: to, subject: id,
                       date: now.addingTimeInterval(-hoursAgo * 3600), labelIds: labels, listUnsubscribe: list ? "<https://x.example/u>" : "")
    }

    func testSendersAreRankedByVolumeWithHowMuchYouRead() {
        let list = [m("1", "News <news@paper.example>", unread: true, list: true), m("2", "News <news@paper.example>", unread: true, list: true),
                    m("3", "News <news@paper.example>", unread: true, list: true), m("4", "Ann <ann@x.example>"),
                    m("5", "Ann <ann@x.example>", unread: true), m("6", "Me <me@example.com>")]
        let s = senderStats(list, me: me, since: now.addingTimeInterval(-86400))
        XCTAssertEqual(s.map(\.email), ["news@paper.example", "ann@x.example"], "most mail first; your own address is left out")
        XCTAssertTrue(s[0].neverRead && s[0].canUnsubscribe && s[0].isNewsletter)
        XCTAssertEqual(s[1].read, 1); XCTAssertEqual(s[1].count, 2)
        XCTAssertTrue(senderStats(list, me: me, since: now).isEmpty, "only the chosen period counts")
    }

    func testOnlyMailFromAPersonWrittenToYouNeedsAReply() {
        func conv(_ ms: Message...) -> Conversation { Conversation(account: "me@example.com", threadId: ms[0].threadId, messages: ms) }
        XCTAssertTrue(needsReply(conv(m("a", "Ann <ann@x.example>")), me: me))
        XCTAssertFalse(needsReply(conv(m("b", "News <news@paper.example>", list: true)), me: me), "newsletters never")
        XCTAssertFalse(needsReply(conv(m("c", "Billing <billing@shop.example>")), me: me), "receipts and bills never")
        XCTAssertFalse(needsReply(conv(m("d", "Bot <noreply@x.example>")), me: me))
        XCTAssertFalse(needsReply(conv(m("e", "Ann <ann@x.example>", to: "team@x.example")), me: me), "only cc'd or on a list: no")
        XCTAssertFalse(needsReply(conv(m("f", "Ann <ann@x.example>", thread: "t", hoursAgo: 2), m("g", "Me <me@example.com>", thread: "t", sent: true)), me: me),
                       "you already answered")
    }

    func testInsightsCountMailPeopleAndReplyTime() {
        let list = [m("a1", "Ann <ann@x.example>", thread: "t", hoursAgo: 5), m("a2", "Me <me@example.com>", thread: "t", hoursAgo: 3, sent: true),
                    m("n1", "News <news@paper.example>", unread: true, list: true), m("n2", "News <news@paper.example>", unread: true, list: true),
                    m("n3", "News <news@paper.example>", unread: true, list: true),
                    m("old", "Ann <ann@x.example>", hoursAgo: 24 * 10)]
        let r = inboxInsights(list, me: me, days: 7, now: now)
        XCTAssertEqual(r.received, 4, "sent mail and mail before the period don't count")
        XCTAssertNil(r.previousReceived, "mail doesn't reach back through the whole earlier week: no comparison")
        XCTAssertEqual(inboxInsights(list + [m("older", "Ann <ann@x.example>", hoursAgo: 24 * 15)], me: me, days: 7, now: now).previousReceived, 1)
        XCTAssertEqual(r.fromPeople, 1)
        XCTAssertEqual(r.neverOpened, 3)
        XCTAssertEqual(r.averageReply ?? 0, 2 * 3600, accuracy: 1, "replied 2 hours after Ann wrote")
        XCTAssertEqual(r.repliedTo.first?.email, "ann@x.example")
        XCTAssertEqual(r.neverReadSenders, 1); XCTAssertEqual(r.neverReadEmails, 3)
        XCTAssertEqual(r.days.count, 7); XCTAssertEqual(r.days.reduce(0) { $0 + $1.people + $1.other }, 4)
        XCTAssertEqual(r.categories.first?.0, .newsletters)
    }

    func testReplyTimesReadNaturally() {
        XCTAssertEqual(durationLabel(50 * 60), "50m")
        XCTAssertEqual(durationLabel(3 * 3600 + 40 * 60), "3h 40m")
        XCTAssertEqual(durationLabel(5 * 86400), "5 days")
    }

    func testNeedsReplySplitShowsDraftedConversations() {
        let c = Conversation(account: "me@example.com", threadId: "a", messages: [m("a", "Ann <ann@x.example>")])
        XCTAssertTrue(matchesQuery("is:drafted", c, QueryContext(drafted: [c.id])))
        XCTAssertFalse(matchesQuery("is:drafted", c, QueryContext()))
    }
}
