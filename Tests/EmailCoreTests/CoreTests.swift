import XCTest
@testable import EmailCore

final class CoreTests: XCTestCase {
    let me = "me@example.com"
    func msg(_ id: String, thread: String = "t1", from: String, to: String = "me@example.com", cc: String = "",
             subject: String = "Hi", date: TimeInterval = 0, labels: [String] = ["INBOX"]) -> Message {
        Message(id: id, threadId: thread, account: me, from: from, to: to, cc: cc, subject: subject,
                date: Date(timeIntervalSince1970: date), labelIds: labels, messageIdHeader: "<\(id)@x>")
    }

    func testParseAddresses() {
        let a = parseAddresses("\"Chen, Maya\" <maya@x.com>, bob@y.com,Sam Patel <sam@z.io>")
        XCTAssertEqual(a, [Address(name: "Chen, Maya", email: "maya@x.com"), Address(name: "", email: "bob@y.com"),
                           Address(name: "Sam Patel", email: "sam@z.io")])
        XCTAssertEqual(a[0].formatted, "\"Chen, Maya\" <maya@x.com>")
    }

    func testConversationsGroupAndSort() {
        let c = conversations(from: [msg("1", thread: "a", from: "x@x.com", date: 10), msg("2", thread: "b", from: "y@y.com", date: 20),
                                     msg("3", thread: "a", from: "me@example.com", date: 30, labels: ["SENT"])])
        XCTAssertEqual(c.map(\.threadId), ["a", "b"])
        XCTAssertEqual(c[0].messages.map(\.id), ["1", "3"])
        XCTAssertTrue(c[0].inInbox)
        XCTAssertEqual(participantsLabel(c[0], me: [me]), "x@x.com, You")
        // A bumped (unsnoozed) thread jumps to the top.
        let bumped = conversations(from: [msg("1", thread: "a", from: "x@x.com", date: 10), msg("2", thread: "b", from: "y@y.com", date: 20)],
                                   bumped: ["\(me)|a": Date(timeIntervalSince1970: 99)])
        XCTAssertEqual(bumped.first?.threadId, "a")
    }

    func testSplitQueries() {
        let ctx = QueryContext(labelNames: ["Label_9": "Receipts"], teamDomains: ["corp.com"], reminded: ["\(me)|r"],
                               importance: ["news@shop.com": true, "spam.com": false])
        func conv(_ m: Message) -> Conversation { conversations(from: [m])[0] }
        func q(_ query: String, _ m: Message) -> Bool { matchesQuery(query, conv(m), ctx) }
        let boss = msg("1", from: "The Boss <boss@corp.com>", subject: "Q4 plan")
        XCTAssertTrue(q("from:Boss@Corp.com", boss))
        XCTAssertTrue(q("from:corp.com", boss))
        XCTAssertFalse(q("from:orp.com", boss))
        XCTAssertTrue(q("from:boss", boss))
        XCTAssertTrue(q("from:nobody@x.com OR subject:q4", boss))
        XCTAssertFalse(q("from:corp.com AND subject:invoice", boss))
        XCTAssertTrue(q("from:corp.com subject:\"q4 plan\"", boss))
        XCTAssertFalse(q("from:corp.com -subject:q4", boss))
        XCTAssertTrue(q("is:team", boss))
        XCTAssertFalse(q("", boss))
        XCTAssertTrue(q("label:receipts", msg("2", from: "a@stripe.com", labels: ["INBOX", "Label_9"])))
        XCTAssertTrue(q("is:reminder", msg("3", thread: "r", from: "a@b.com")))
        var ics = msg("4", from: "x@y.com"); ics.attachments = [AttachmentRef(id: "a", name: "invite.ics", mimeType: "text/calendar", size: 1)]
        XCTAssertTrue(q(splitLibrary.first { $0.name == "Calendar" }!.query, ics))
        XCTAssertEqual(addTerm("from:a@b.com", to: " "), "from:a@b.com")
        XCTAssertEqual(addTerm("from:c.com", to: "from:a@b.com"), "from:a@b.com OR from:c.com")

        // Tabs: exclusive split, shared split, importance overrides.
        let splits = [Split(name: "Team", query: "is:team", alsoInMain: true), Split(name: "Bills", query: "label:receipts")]
        XCTAssertEqual(tabs(for: conv(boss), splits: splits, ctx: ctx), ["Team", otherTab])
        XCTAssertEqual(tabs(for: conv(msg("5", from: "a@stripe.com", labels: ["INBOX", "Label_9", "IMPORTANT"])), splits: splits, ctx: ctx), ["Bills"])
        XCTAssertEqual(tabs(for: conv(msg("6", from: "news@shop.com")), splits: splits, ctx: ctx), [importantTab])
        XCTAssertEqual(tabs(for: conv(msg("7", from: "x@spam.com", labels: ["INBOX", "IMPORTANT"])), splits: splits, ctx: ctx), [otherTab])
        var off = splits; off[1].enabled = false
        XCTAssertEqual(tabs(for: conv(msg("8", from: "a@stripe.com", labels: ["INBOX", "Label_9"])), splits: off, ctx: ctx), [otherTab])
    }

    func testReplyAllExcludesMeAndDedupes() {
        let m = msg("1", from: "Maya <maya@x.com>", to: "me@example.com, bob@y.com", cc: "Maya <maya@x.com>, ann@z.com", subject: "Plan")
        let d = replyDraft(to: m, me: "ME@example.com", all: true)
        XCTAssertEqual(d.to, "Maya <maya@x.com>")
        XCTAssertEqual(d.cc, "bob@y.com, ann@z.com")
        XCTAssertEqual(d.subject, "Re: Plan")
        XCTAssertEqual(d.inReplyTo, "<1@x>")
        XCTAssertEqual(replySubject("RE: Plan"), "RE: Plan")
        // Replying to my own sent message goes back to its recipients.
        let mine = replyDraft(to: msg("2", from: "me@example.com", to: "bob@y.com"), me: me, all: false)
        XCTAssertEqual(mine.to, "bob@y.com")
    }

    func testBuildRawRoundTrips() {
        var d = Draft(from: me); d.to = "bob@y.com"; d.subject = "Café ☕"; d.body = "Line 1\nLíne 2"
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("Subject: =?UTF-8?B?"))
        XCTAssertFalse(raw.contains("Cc:"))
        var chips = Draft(from: me); chips.to = "Maya Chen <m@x.com>, bob@y.com, "
        XCTAssertTrue(buildRaw(chips).contains("To: Maya Chen <m@x.com>, bob@y.com\r\n"))
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let body = String(data: Data(base64Encoded: parts[1].replacingOccurrences(of: "\r\n", with: ""))!, encoding: .utf8)
        XCTAssertEqual(body, "Line 1\r\nLíne 2")
        XCTAssertEqual(base64urlDecode(base64url(Data(raw.utf8))), Data(raw.utf8))
    }

    func testAttachmentsBuildMultipart() {
        var d = Draft(from: me); d.to = "bob@y.com"; d.subject = "Deck"; d.body = "See attached"
        d.files = [OutgoingFile(name: "plan.pdf", mimeType: "application/pdf", data: Data("PDFDATA".utf8))]
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed; boundary="))
        XCTAssertTrue(raw.contains("Content-Disposition: attachment; filename=\"plan.pdf\""))
        XCTAssertTrue(raw.contains(Data("PDFDATA".utf8).base64EncodedString()))
        XCTAssertTrue(raw.contains(Data("See attached".utf8).base64EncodedString()))
        XCTAssertTrue(raw.hasSuffix("--\r\n"))
        XCTAssertFalse(attachmentsTooLarge(d.files))
        XCTAssertTrue(attachmentsTooLarge([OutgoingFile(name: "big", mimeType: "x", data: Data(count: 19_000_000))]))
    }

    func testParseAttachmentRefs() {
        let j: [String: Any] = ["id": "m", "threadId": "t", "payload": ["mimeType": "multipart/mixed", "parts": [
            ["mimeType": "application/pdf", "filename": "a.pdf", "body": ["attachmentId": "ATT1", "size": 1234]]]]]
        XCTAssertEqual(parseMessage(j, account: me)?.attachments, [AttachmentRef(id: "ATT1", name: "a.pdf", mimeType: "application/pdf", size: 1234)])
    }

    func testLinkifyAndInlineImages() {
        XCTAssertEqual(linkify("See https://x.com/a?b=1. Thanks"), "See <a href=\"https://x.com/a?b=1\">https://x.com/a?b=1</a>. Thanks")
        XCTAssertEqual(linkify("no links here"), "no links here")
        XCTAssertEqual(inlineImages("<img src=\"cid:logo@1\">", ["logo@1": "data:image/png;base64,AA"]), "<img src=\"data:image/png;base64,AA\">")
        let j: [String: Any] = ["id": "m", "threadId": "t", "payload": ["mimeType": "multipart/related", "parts": [
            ["mimeType": "text/html", "body": ["data": base64url(Data("<img src=\"cid:logo@1\">".utf8))]],
            ["mimeType": "image/png", "filename": "logo.png", "headers": [["name": "Content-ID", "value": "<logo@1>"], ["name": "Content-Disposition", "value": "inline"]],
             "body": ["attachmentId": "A", "size": 10]],
            ["mimeType": "application/pdf", "filename": "a.pdf", "headers": [["name": "Content-ID", "value": "<x>"], ["name": "Content-Disposition", "value": "attachment; filename=a.pdf"]],
             "body": ["attachmentId": "B", "size": 10]]]]]
        let m = parseMessage(j, account: me)!
        XCTAssertEqual(m.attachments.map(\.contentId), ["logo@1", nil])
        XCTAssertEqual(m.attachments.map(\.isInline), [true, false])
    }

    func testPKCEMatchesOpenSSL() {
        XCTAssertEqual(pkceChallenge("dBjftJeZ4CVP-mJ92K9qXJYH4-Hk-8xnI8i4kD4MQ5s"), "bP4agaPN8SlLonWQpieNx4wmCT18SVtBd7fINwNPGWg")
    }

    func testLoopbackQuery() {
        let q = queryItems(fromRequest: "GET /?state=abc&code=4%2F0Ad&scope=x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        XCTAssertEqual(q["code"], "4/0Ad"); XCTAssertEqual(q["state"], "abc")
        XCTAssertEqual(queryItems(fromRequest: "POST / HTTP/1.1"), [:])
    }

    func testSnoozePresets() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15))! // Monday
        let p = Dictionary(uniqueKeysWithValues: snoozePresets(now: now, calendar: cal))
        XCTAssertEqual(p["Tomorrow"], cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 8)))
        XCTAssertEqual(p["This weekend"], cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 8)))
        XCTAssertEqual(p["Next week"], cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8)))
        XCTAssertEqual(p["Later today"], now.addingTimeInterval(3 * 3600))
    }

    func testParseWhen() {
        let d = parseWhen("tomorrow at 3pm")
        XCTAssertNotNil(d)
        XCTAssertEqual(Calendar.current.component(.hour, from: d!), 15)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(d!))
        XCTAssertNil(parseWhen("banana"))
        XCTAssertNil(parseWhen(""))
    }

    func testFollowUp() {
        let sent = msg("1", from: me, date: 100, labels: ["SENT"])
        XCTAssertFalse(gotReply([sent, msg("2", from: "Me <ME@example.com>", date: 200)], me: me, after: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(gotReply([sent, msg("3", from: "bob@y.com", date: 200)], me: me, after: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(gotReply([msg("4", from: "bob@y.com", date: 50), sent], me: me, after: Date(timeIntervalSince1970: 100)))
    }

    func testSnippetAndUnsubscribe() {
        XCTAssertEqual(expand("Hi {first_name}!", recipient: Address(name: "Maya Chen", email: "m@x.com")), "Hi Maya!")
        XCTAssertEqual(unsubscribeAction(header: "<mailto:u@x.com>, <https://x.com/u?id=1>", oneClickPost: true), .oneClick(URL(string: "https://x.com/u?id=1")!))
        XCTAssertEqual(unsubscribeAction(header: "<mailto:u@x.com>", oneClickPost: true), .open(URL(string: "mailto:u@x.com")!))
        XCTAssertEqual(unsubscribeAction(header: "", oneClickPost: false), .none)
    }

    func testParseGmailMessage() {
        let html = base64url(Data("<p>Hello &amp; welcome</p>".utf8)), txt = base64url(Data("Hello & welcome".utf8))
        let j: [String: Any] = ["id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Hello &amp; welcome",
                                "internalDate": "1760000000000",
                                "payload": ["mimeType": "multipart/mixed", "headers": [["name": "From", "value": "A <a@x.com>"], ["name": "Subject", "value": "Yo"],
                                                                                         ["name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"]],
                                            "parts": [["mimeType": "multipart/alternative", "parts": [["mimeType": "text/plain", "body": ["data": txt]],
                                                                                                     ["mimeType": "text/html", "body": ["data": html]]]],
                                                      ["mimeType": "text/plain", "filename": "notes.txt", "body": ["attachmentId": "x"]]]]]
        let m = parseMessage(j, account: me)!
        XCTAssertEqual(m.subject, "Yo"); XCTAssertEqual(m.snippet, "Hello & welcome")
        XCTAssertEqual(m.html, "<p>Hello &amp; welcome</p>"); XCTAssertEqual(m.text, "Hello & welcome")
        XCTAssertTrue(m.listUnsubscribePost)
        XCTAssertEqual(m.date, Date(timeIntervalSince1970: 1_760_000_000))
        var noText = m; noText.text = nil
        XCTAssertEqual(noText.plainText, "Hello & welcome")
    }

    func testParseHistory() {
        let pages: [[String: Any]] = [
            ["history": [["messagesAdded": [["message": ["id": "a", "threadId": "t", "labelIds": ["INBOX"]]]]],
                         ["labelsRemoved": [["message": ["id": "a", "threadId": "t", "labelIds": []]]]],
                         ["messagesDeleted": [["message": ["id": "b"]]]]]],
            ["history": [["messagesAdded": [["message": ["id": "b", "threadId": "t2", "labelIds": ["INBOX"]]]]],
                         ["messagesDeleted": [["message": ["id": "c"]]]]]],
        ]
        let d = parseHistory(pages)
        XCTAssertEqual(d.changed["a"]?.labels, [])
        XCTAssertEqual(d.changed["b"]?.threadId, "t2")
        XCTAssertEqual(d.deleted, ["c"])
    }
}
