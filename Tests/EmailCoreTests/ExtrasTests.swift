import XCTest
import CryptoKit
@testable import EmailCore

final class ExtrasTests: XCTestCase {
    let me: Set<String> = ["me@x.com"]
    func m(_ from: String, to: String = "me@x.com", cc: String = "", labels: [String] = [], unsub: String = "") -> Message {
        Message(id: UUID().uuidString, threadId: "t", account: "me@x.com", from: from, to: to, cc: cc, labelIds: labels, listUnsubscribe: unsub)
    }

    func testContactSuggestionsRankAndMatch() {
        let msgs = [m("Maya Chen <maya@corp.com>"), m("Mark <mark@x.org>"),
                    m("me@x.com", to: "Mark Twain <mark@x.org>"), m("me@x.com", to: "mark@x.org")]
        let s = contactSuggestions("ma", messages: msgs, me: me)
        XCTAssertEqual(s.map(\.email), ["mark@x.org", "maya@corp.com"]) // written-to ranks higher
        XCTAssertEqual(s.first?.name, "Mark") // first named form kept
        XCTAssertEqual(contactSuggestions("chen", messages: msgs, me: me).map(\.email), ["maya@corp.com"])
        XCTAssertEqual(contactSuggestions("me", messages: msgs, me: me), []) // never suggests yourself
        XCTAssertEqual(contactSuggestions("", messages: msgs, me: me), [])
    }

    func testCompleteField() {
        XCTAssertEqual(currentToken("a@b.com, ma"), "ma")
        XCTAssertEqual(completeField("a@b.com, ma", with: Address(name: "Maya Chen", email: "maya@corp.com")), "a@b.com, Maya Chen <maya@corp.com>, ")
        XCTAssertEqual(completeField("ma", with: Address(name: "", email: "maya@corp.com")), "maya@corp.com, ")
    }

    func testAutoArchiveCategory() {
        XCTAssertEqual(autoArchiveCategory(m("x@y.com", labels: ["INBOX", "CATEGORY_PROMOTIONS"])), .promotions)
        XCTAssertEqual(autoArchiveCategory(m("x@y.com", labels: ["INBOX", "CATEGORY_SOCIAL"])), .social)
        XCTAssertEqual(autoArchiveCategory(m("x@y.com", unsub: "<https://u>")), .newsletters)
        XCTAssertNil(autoArchiveCategory(m("x@y.com", labels: ["STARRED", "CATEGORY_PROMOTIONS"])))
        XCTAssertNil(autoArchiveCategory(m("friend@y.com")))
    }

    func testParseInstantReplies() {
        XCTAssertEqual(parseInstantReplies("Sounds good, see you then.\n===\nCan we do 3pm instead?\n===\nI'll pass this time, thanks!\n===\nextra"),
                       ["Sounds good, see you then.", "Can we do 3pm instead?", "I'll pass this time, thanks!"])
        XCTAssertEqual(parseInstantReplies("  \n"), [])
    }

    func testSplitQuoted() {
        let t = "Sounds good!\n\nOn Mon, Oct 12, 2026 at 9:46 AM Maya <m@x.com> wrote:\n> Can you sign?\n> Thanks"
        XCTAssertEqual(splitQuoted(t).body, "Sounds good!")
        XCTAssertEqual(splitQuoted(t).quoted?.hasPrefix("On Mon"), true)
        XCTAssertEqual(splitQuoted("Yes\n> earlier\n>\n> more").body, "Yes")
        XCTAssertNil(splitQuoted("Just a note.\nWith two lines.").quoted)
        XCTAssertNil(splitQuoted("> only quote").quoted) // nothing new to show, keep it all
    }

    func testFullBodyOrder() {
        var d = Draft(from: "me@x.com"); d.body = "Sounds good"; d.signaturePlain = "Danny"; d.quoted = "\n\nOn Mon, Maya wrote:\n> hi"
        XCTAssertEqual(fullBody(d), "Sounds good\n\n-- \nDanny\n\nOn Mon, Maya wrote:\n> hi")
        d.signaturePlain = "  "
        XCTAssertEqual(fullBody(d), "Sounds good\n\nOn Mon, Maya wrote:\n> hi") // no signature, no delimiter
        let r = replyDraft(to: Message(id: "1", threadId: "t", account: "me@x.com", from: "Maya <m@x.com>", subject: "Plan", text: "hi"), me: "me@x.com", all: false)
        XCTAssertEqual(r.body, ""); XCTAssertTrue(r.quoted?.contains("> hi") == true)
    }

    func testRichSignatureBuildsHTMLAlternative() {
        let parts = signatureParts("<b>Danny Chait</b><br><a href=\"https://tc.org\">True Competitors</a>")
        XCTAssertEqual(parts.plain, "Danny Chait\nTrue Competitors")
        XCTAssertEqual(signatureParts("Just text").html, nil)

        var d = Draft(from: "me@x.com"); d.to = "bob@y.com"; d.subject = "Hi"
        d.body = "Hello Bob\nsee https://x.com"; d.quoted = "\n\nOn Mon, Bob wrote:\n> hi"
        d.signaturePlain = parts.plain; d.signatureHTML = parts.html
        let html = composeHTML(d)!
        XCTAssertTrue(html.contains("Hello Bob<br>"))
        XCTAssertTrue(html.contains("<a href=\"https://x.com\">https://x.com</a>"))
        XCTAssertTrue(html.contains("<b>Danny Chait</b>"))
        XCTAssertTrue(html.contains("<blockquote"))
        XCTAssertFalse(html.contains("-- "))
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("Content-Type: multipart/alternative"))
        XCTAssertTrue(raw.contains("Content-Type: text/html; charset=UTF-8"))

        // Signature removed in compose: plain text only.
        d.signaturePlain = nil; d.signatureHTML = nil
        XCTAssertNil(composeHTML(d))
        XCTAssertFalse(buildRaw(d).contains("multipart/alternative"))
    }

    func testPastedSignatureWithEmbeddedLogo() {
        let page = "<!doctype html><html><head><title>x</title></head><body style=\"margin:24px\"><table><tr><td><img src=\"data:image/png;base64,iVBORw0KGgo=\" width=\"56\"></td><td><div>Danny Chait</div><div>President &middot; True Competitors</div></td></tr></table></body></html>"
        let sig = extractBodyHTML(page)
        XCTAssertTrue(sig.hasPrefix("<table>")); XCTAssertFalse(sig.contains("<body"))
        XCTAssertTrue(isComplexHTML(sig)); XCTAssertFalse(isComplexHTML("<b>Danny</b><br>Hi"))
        let parts = signatureParts(sig)
        XCTAssertEqual(parts.plain, "Danny Chait\nPresident · True Competitors")

        let (html, images) = extractDataImages(sig)
        XCTAssertEqual(images.count, 1); XCTAssertEqual(images[0].mimeType, "image/png")
        XCTAssertEqual(images[0].data, Data(base64Encoded: "iVBORw0KGgo="))
        XCTAssertTrue(html.contains("src=\"cid:\(images[0].cid)\"")); XCTAssertFalse(html.contains("data:image"))

        var d = Draft(from: "me@x.com"); d.to = "b@y.com"
        d.body = "Hi"; d.signaturePlain = parts.plain; d.signatureHTML = parts.html
        let raw = buildRaw(d)
        XCTAssertTrue(raw.contains("multipart/related"))
        XCTAssertTrue(raw.contains("Content-ID: <img1."))
        XCTAssertEqual(decodeEntities("a &#183; b &#xB7; c &amp;middot;"), "a · b · c &middot;")
    }

    func testGmailInlineImagesWithoutFilenames() {
        let html = base64url(Data("<img src=\"cid:logo1\"><img src=\"cid:big1\">".utf8))
        let png = base64url(Data([0x89, 0x50, 0x4E, 0x47]))
        let j: [String: Any] = ["id": "m", "threadId": "t", "payload": ["mimeType": "multipart/related", "parts": [
            ["mimeType": "text/html", "body": ["data": html]],
            // small logo: data inside the message, no filename
            ["mimeType": "image/png", "filename": "", "headers": [["name": "Content-ID", "value": "<logo1>"]], "body": ["data": png]],
            // bigger image: separate download, marked "attachment" but shown in the body
            ["mimeType": "image/jpeg", "filename": "", "headers": [["name": "Content-ID", "value": "<big1>"], ["name": "Content-Disposition", "value": "attachment"]],
             "body": ["attachmentId": "ATT", "size": 900]],
            ["mimeType": "application/pdf", "filename": "deck.pdf", "headers": [["name": "Content-ID", "value": "<unused>"]], "body": ["attachmentId": "PDF", "size": 5]]]]]
        let m = parseMessage(j, account: "me@x.com")!
        XCTAssertTrue(m.html!.contains("src=\"data:image/png;base64,iVBORw==\""))
        XCTAssertEqual(m.attachments.map(\.contentId), ["big1", nil]) // jpeg is inline (shown); pdf isn't
        XCTAssertEqual(m.attachments.map(\.isInline), [true, false])
        XCTAssertEqual(m.attachments.first?.name, "image-big1")
    }

    func testSearchQuery() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var q = SearchQuery()
        XCTAssertTrue(q.isEmpty)
        q.from = "Maya Chen"; q.subject = "Q4 pilot"; q.words = "contract"; q.hasAttachment = true
        q.after = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))
        q.before = cal.date(from: DateComponents(year: 2026, month: 10, day: 12))
        XCTAssertEqual(gmailQuery(q, calendar: cal),
                       "from:\"Maya Chen\" subject:(Q4 pilot) after:2026/10/01 before:2026/10/13 has:attachment contract")
        XCTAssertEqual(q.chips.count, 6)

        var m = Message(id: "1", threadId: "t", account: "me@x.com", from: "Maya Chen <maya@corp.com>", subject: "Contract for the Q4 pilot",
                        date: cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 23))!, text: "Please sign the contract")
        m.attachments = [AttachmentRef(id: "a", name: "c.pdf", mimeType: "application/pdf", size: 1)]
        XCTAssertTrue(matchesSearch(m, q, calendar: cal)) // 11pm on the "before" day still counts
        var other = q; other.from = "bob"
        XCTAssertFalse(matchesSearch(m, other, calendar: cal))
        var late = q; late.before = cal.date(from: DateComponents(year: 2026, month: 10, day: 11))
        XCTAssertFalse(matchesSearch(m, late, calendar: cal))
        var words = SearchQuery(); words.words = "sign contract"
        XCTAssertTrue(matchesSearch(m, words, calendar: cal))
    }

    func testSearchSuggestions() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))! // Wednesday
        let msgs = [
            Message(id: "1", threadId: "a", account: "me@x.com", from: "Maya Chen <maya@corp.com>", subject: "Contract for the Q4 pilot"),
            Message(id: "2", threadId: "b", account: "me@x.com", from: "Mark <mark@x.org>", subject: "Pilot schedule"),
        ]
        let me: Set<String> = ["me@x.com"]
        // A name → person first, words last.
        let s1 = searchSuggestions("may", current: SearchQuery(), messages: msgs, me: me, now: now, calendar: cal)
        XCTAssertEqual(s1.first, .person(Address(name: "Maya Chen", email: "maya@corp.com"), to: false))
        XCTAssertEqual(s1.last, .words("may"))
        // from: limits to people
        XCTAssertEqual(searchSuggestions("from:ma", current: SearchQuery(), messages: msgs, me: me, now: now, calendar: cal).count, 2)
        // With a person locked, subject suggestions are that person's subjects only
        var q = apply(.person(Address(name: "Maya Chen", email: "maya@corp.com"), to: false), to: SearchQuery())
        XCTAssertEqual(q.from, "maya@corp.com")
        let s2 = searchSuggestions("pilot", current: q, messages: msgs, me: me, now: now, calendar: cal)
        XCTAssertTrue(s2.contains(.subject("Contract for the Q4 pilot")))
        XCTAssertFalse(s2.contains(.subject("Pilot schedule")))
        // Dates and filters
        let lw = parseDateRange("last wee", now: now, calendar: cal)!
        XCTAssertEqual(lw.label, "Last Week")
        XCTAssertEqual(lw.after, cal.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        XCTAssertEqual(lw.before, cal.date(from: DateComponents(year: 2026, month: 10, day: 10)))
        XCTAssertEqual(parseDateRange("today", now: now, calendar: cal)?.after, cal.startOfDay(for: now))
        XCTAssertNil(parseDateRange("maya", now: now, calendar: cal))
        XCTAssertTrue(searchSuggestions("attach", current: q, messages: msgs, me: me, now: now, calendar: cal).contains(.hasAttachment))
        q = apply(.words("contract"), to: q); q = apply(.words("signed"), to: q)
        XCTAssertEqual(q.words, "contract signed")
    }

    func testFriendlyGoogleErrors() {
        let j500 = #"{"error":{"code":500,"message":"Internal error encountered.","errors":[{"message":"Internal error encountered.","domain":"global","reason":"backendError"}]}}"#
        XCTAssertEqual(friendlyGoogleError(status: 500, body: j500), "Gmail is having a temporary problem. Keymail will try again shortly.")
        XCTAssertTrue(isTransientGoogleError(status: 503, body: ""))
        XCTAssertTrue(isTransientGoogleError(status: 403, body: "Quota exceeded"))
        XCTAssertFalse(isTransientGoogleError(status: 404, body: ""))
        XCTAssertTrue(friendlyGoogleError(status: 401, body: "").contains("sign-in expired"))
        XCTAssertTrue(friendlyGoogleError(status: 400, body: #"{"error":"invalid_grant"}"#).contains("sign-in expired"))
        XCTAssertTrue(friendlyGoogleError(status: 403, body: #"{"error":{"message":"Gmail API has not been used in project 1"}}"#).contains("isn't available to Keymail"))
        XCTAssertTrue(friendlyGoogleError(status: 403, body: #"{"error":{"message":"Request had insufficient authentication scopes."}}"#).contains("permission"))
        XCTAssertTrue(friendlyGoogleError(status: 400, body: #"{"error":{"message":"Invalid To header"}}"#).hasSuffix("Invalid To header"))
        for status in [400, 401, 403, 404, 409, 413, 429, 500, 502, 503, 418] {
            let msg = friendlyGoogleError(status: status, body: j500)
            XCTAssertFalse(msg.contains("{"), "raw JSON leaked for \(status)")
        }
        XCTAssertEqual(friendlyNetworkError(URLError(.notConnectedToInternet)), "You're offline. Keymail will catch up when you reconnect.")
        XCTAssertNil(friendlyNetworkError(NSError(domain: "x", code: 1)))
    }

    func testCacheEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Data(#"{"messages":[{"subject":"Contract for the Q4 pilot"}]}"#.utf8)
        let enc = try encryptFile(plain, key: key)
        XCTAssertTrue(enc.starts(with: encryptedFileMagic))
        XCTAssertNil(String(data: enc, encoding: .utf8)?.range(of: "Contract")) // not readable on disk
        XCTAssertEqual(try decryptFile(enc, key: key), plain)
        XCTAssertThrowsError(try decryptFile(plain, key: key)) // F12: unencrypted data is rejected (no tamper-check bypass)
        XCTAssertThrowsError(try decryptFile(enc, key: SymmetricKey(size: .bits256))) // wrong key
        var tampered = enc; tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try decryptFile(tampered, key: key)) // edited on disk
    }

    func testPhishingChecks() {
        func m(_ from: String, replyTo: String? = nil, auth: Bool? = nil) -> Message {
            var x = Message(id: "1", threadId: "t", account: "me@x.com", from: from); x.replyTo = replyTo; x.authFailed = auth; return x
        }
        // Legit senders: no warnings
        XCTAssertEqual(senderWarnings(m("PayPal <service@paypal.com>"), known: []), [])
        XCTAssertEqual(senderWarnings(m("Maya Chen <maya@corp.com>"), known: []), [])
        XCTAssertEqual(senderWarnings(m("Apple <no_reply@email.apple.com>"), known: []), [])
        // Brand name from the wrong domain
        XCTAssertTrue(senderWarnings(m("PayPal Support <help@secure-mail.ru>"), known: []).first!.contains("came from secure-mail.ru"))
        // Lookalike domains
        XCTAssertEqual(lookalikeBrand("paypa1.com"), "paypal.com")
        XCTAssertEqual(lookalikeBrand("rnicrosoft.com"), "microsoft.com")
        XCTAssertEqual(lookalikeBrand("paypal-security.com"), "paypal.com")
        XCTAssertNil(lookalikeBrand("mail.paypal.com"))
        XCTAssertNil(lookalikeBrand("truecompetitors.org"))
        // Address shown in the name on another domain
        XCTAssertTrue(senderWarnings(m("\"service@paypal.com\" <x@evil.net>"), known: []).contains { $0.contains("shows paypal.com") })
        // Reply-To elsewhere; failed authentication
        XCTAssertTrue(senderWarnings(m("Bob <bob@acme.com>", replyTo: "pay@other.io"), known: []).contains { $0.contains("Replies would go to other.io") })
        XCTAssertTrue(senderWarnings(m("Bob <bob@acme.com>", auth: true), known: []).first!.contains("didn't verify"))
        XCTAssertEqual(authenticationFailed("mx.google.com; spf=pass; dkim=pass; dmarc=fail (p=REJECT)"), true)
        XCTAssertEqual(authenticationFailed("mx.google.com; spf=pass; dkim=pass; dmarc=pass"), false)
        // Known contact with a brand-like name isn't flagged
        XCTAssertEqual(senderWarnings(m("Apple Smith <apple@farm.com>"), known: ["apple@farm.com"]), [])

        // Links
        XCTAssertEqual(linkWarning(href: "https://evil.com/login", shown: "www.paypal.com"), "The link says paypal.com but goes to evil.com.")
        XCTAssertNil(linkWarning(href: "https://www.paypal.com/signin", shown: "paypal.com"))
        XCTAssertNil(linkWarning(href: "https://click.mailer.com/x", shown: "View your order"))
        XCTAssertTrue(linkWarning(href: "http://192.168.4.20/pay", shown: "Pay now")!.contains("IP address"))
        XCTAssertTrue(linkWarning(href: "javascript:alert(1)", shown: "Open")!.contains("runs code"))
        XCTAssertTrue(linkWarning(href: "https://paypa1.com/x", shown: "Click")!.contains("imitates paypal.com"))
        let links = suspiciousLinks(#"<a href="https://evil.com/a">paypal.com</a> <a href='https://ok.com'>Read more</a>"#)
        XCTAssertEqual(links.map(\.href), ["https://evil.com/a"])
        XCTAssertEqual(registrableDomain("mail.amazon.co.uk"), "amazon.co.uk")
    }

    func testVacationRoundTrip() {
        var v = Vacation()
        v.enabled = true; v.subject = "Out until Monday"; v.message = "I'm away.\nBack Monday."; v.contactsOnly = true
        v.start = Date(timeIntervalSince1970: 1_760_000_000); v.end = Date(timeIntervalSince1970: 1_760_400_000)
        let j = v.json
        XCTAssertEqual(j["startTime"] as? String, "1760000000000")
        XCTAssertEqual(j["responseBodyHtml"] as? String, "I'm away.<br>\nBack Monday.")
        XCTAssertEqual(Vacation(json: j), v)
        XCTAssertTrue(v.isActive(at: Date(timeIntervalSince1970: 1_760_100_000)))
        XCTAssertFalse(v.isActive(at: Date(timeIntervalSince1970: 1_760_500_000)))
        XCTAssertEqual(Vacation(json: ["enableAutoReply": false]).enabled, false)
        XCTAssertNotNil(gmailSignatureProblem("<img src=\"data:image/png;base64,AA\">"))
        XCTAssertNil(gmailSignatureProblem("<img src=\"https://x.com/logo.png\">"))
    }

    // MARK: Security fixes (scan of 2026-10-14). Each test fails if its fix is undone.

    func testLinkAllowlist() { // F1, F13
        XCTAssertNil(linkWarning(href: "https://example.com/a", shown: "Read more"))
        XCTAssertNil(linkWarning(href: "mailto:bob@example.com", shown: "Email Bob"))
        for bad in ["file:///Applications/Calculator.app", "smb://evil.example/share", "ssh://root@evil.example",
                    "vnc://evil.example", "x-apple-helpviewer://x", "data:text/html,hi", "javascript:alert(1)"] {
            XCTAssertNotNil(linkWarning(href: bad, shown: "Click"), bad)
        }
    }

    func testPaletteIndexNeverCrashes() { // F2
        for h in [Int.min, Int.max, -1, 0, 12345] { XCTAssertTrue((0..<7).contains(paletteIndex(h, count: 7))) }
    }

    func testInlineImagesIsBounded() { // F4
        let img = "data:image/png;base64," + String(repeating: "A", count: 10_000)
        let bomb = String(repeating: "<img src=\"cid:a\">", count: 10_000)
        XCTAssertEqual(inlineImages(bomb, ["a": img], limit: 1_000_000), bomb) // would be 100 MB: skipped
        XCTAssertEqual(inlineImages("<img src=\"cid:a\">", ["a": "data:text/html,<b>x</b>"]), "<img src=\"cid:a\">") // not an image
        XCTAssertEqual(inlineImages("cid:ab cid:a", ["a": "data:image/png;base64,A", "ab": "data:image/png;base64,B"]),
                       "data:image/png;base64,B data:image/png;base64,A") // "a" doesn't eat "ab"
    }

    func testIMAPQuoteStripsLineBreaks() { // F5, F8
        let q = imapQuote("<id@x>\r\nA1 DELETE INBOX\r\n")
        XCTAssertFalse(q.contains("\r") || q.contains("\n"))
        XCTAssertEqual(imapQuote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testDeepMIMENestingDoesNotCrash() { // F6
        var raw = "Content-Type: text/plain\r\n\r\nhi"
        for i in 0..<3000 { raw = "Content-Type: multipart/mixed; boundary=\"b\(i)\"\r\n\r\n--b\(i)\r\n" + raw + "\r\n--b\(i)--" }
        _ = parseRaw(Data(raw.utf8)) // returns instead of overflowing the stack
    }

    func testOnlyGooglesOwnAuthResultsCount() { // F7, F11
        func msg(_ auth: [String]) -> Message? {
            parseMessage(["id": "m", "threadId": "t", "payload": ["mimeType": "text/plain",
                "headers": auth.map { ["name": "Authentication-Results", "value": $0] } + [["name": "From", "value": "a@b.com"]],
                "body": ["data": ""]]], account: "me@x.com")
        }
        // Google's header (top) says fail; the sender's fake one below says pass.
        XCTAssertEqual(msg(["mx.google.com; dmarc=fail header.from=bank.com", "evil.example; dmarc=pass"])?.authFailed, true)
        // Only fake headers: no verdict at all.
        XCTAssertNil(msg(["evil.example; dmarc=pass"])?.authFailed)
    }

    func testFastOnHostileHTML() { // F9, F14
        let start = Date()
        _ = plainFromHTML(String(repeating: "<style x", count: 50_000) + String(repeating: "<", count: 50_000))
        _ = suspiciousLinks(String(repeating: "<a href=\"https://x.com\">", count: 20_000) + String(repeating: "<a ", count: 20_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(plainFromHTML("<header>Hi</header><style>p{}</style>there"), "Hithere")
        XCTAssertEqual(suspiciousLinks("<a href=\"https://evil.example\">paypal.com</a>").count, 1) // detection still works
    }

    func testFromHeaderCantHideRealAddress() { // F10
        XCTAssertEqual(parseAddresses("attacker@evil.example (<ceo@corp.com>)").first?.email, "attacker@evil.example")
        XCTAssertEqual(parseAddresses("\"CEO <ceo@corp.com>\" <attacker@evil.example>").first?.email, "attacker@evil.example")
        XCTAssertEqual(parseAddresses("Sam Patel <sam@x.com>, bob@y.com").map(\.email), ["sam@x.com", "bob@y.com"])
    }

    func testHeadersStayOneLine() { // F16
        var d = Draft(from: "me@x.com"); d.to = "bob@y.com"; d.subject = "Re: hi\rBcc: victim@z.com"; d.body = "x"
        let head = buildRaw(d).components(separatedBy: "\r\n\r\n")[0]
        XCTAssertFalse(head.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
    }

    func testFreshArrivals() {
        let now = Date()
        func msg(_ id: String, from: String = "bob@y.com", labels: [String] = ["INBOX", "UNREAD"], age: TimeInterval = 60, thread: String = "t") -> Message {
            Message(id: id, threadId: thread, account: "me@x.com", from: from, to: "me@x.com", date: now.addingTimeInterval(-age), labelIds: labels)
        }
        let all = [msg("old"), msg("new"), msg("read", labels: ["INBOX"]), msg("mine", from: "Me <me@x.com>"),
                   msg("sent", from: "work@y.com", labels: ["INBOX", "UNREAD", "SENT"]), msg("other-account", from: "Work <work@y.com>"),
                   msg("stale", age: 7200), msg("muted", thread: "quiet"), msg("archived", labels: ["UNREAD"])]
        let got = freshArrivals(all, knownKeys: ["me@x.com|old"], me: ["me@x.com"], muted: ["me@x.com|quiet"], now: now)
        XCTAssertEqual(Set(got.map(\.id)), ["new", "other-account"])
    }

    func testCacheKeysCapsAgeAndCount() {
        let now = Date()
        func msg(_ id: String, days: Double, thread: String = "t", account: String = "a@x.com") -> Message {
            Message(id: id, threadId: thread, account: account, from: "b@y.com", date: now.addingTimeInterval(-days * 86400))
        }
        let all = [msg("new", days: 1), msg("old", days: 200), msg("oldInbox", days: 300, thread: "keep"),
                   msg("n1", days: 2, account: "c@x.com"), msg("n2", days: 3, account: "c@x.com"), msg("n3", days: 4, account: "c@x.com")]
        let keep = cacheKeys(all, keepThreads: ["a@x.com|keep"], now: now, maxPerAccount: 2)
        XCTAssertEqual(keep, ["a@x.com|new", "a@x.com|oldInbox", "c@x.com|n1", "c@x.com|n2"])
    }

    func testMicrosoftAccountEmail() {
        XCTAssertEqual(microsoftAccountEmail(profile: ["mail": "Dan@Contoso.com", "userPrincipalName": "dan@contoso.onmicrosoft.com"]), "dan@contoso.com")
        XCTAssertEqual(microsoftAccountEmail(profile: ["mail": NSNull(), "userPrincipalName": "someone@outlook.com"]), "someone@outlook.com")
        XCTAssertNil(microsoftAccountEmail(profile: ["userPrincipalName": "bob_gmail.com#EXT#@contoso.onmicrosoft.com"]))
        XCTAssertNil(microsoftAccountEmail(profile: [:]))
        XCTAssertTrue(friendlyMicrosoftSignInError("AADSTS65001: The user or administrator has not consented").contains("administrator"))
        XCTAssertFalse(friendlyMicrosoftSignInError("AADSTS9999 weird").contains("AADSTS")) // never show raw codes
    }

    func testMessageFromGraph() {
        let j: [String: Any] = [
            "id": "AAMk1", "conversationId": "conv1", "subject": "Lunch?", "bodyPreview": "Want to grab\r\nlunch",
            "receivedDateTime": "2026-10-15T17:30:00Z", "isRead": false, "inferenceClassification": "focused",
            "flag": ["flagStatus": "flagged"], "internetMessageId": "<abc@outlook.com>", "isDraft": false,
            "from": ["emailAddress": ["name": "Sam Patel", "address": "sam@outlook.com"]],
            "toRecipients": [["emailAddress": ["name": "Me", "address": "me@outlook.com"]], ["emailAddress": ["name": "", "address": "b@x.com"]]],
            "replyTo": [["emailAddress": ["name": "Sam", "address": "sam@work.com"]]],
            "body": ["contentType": "html", "content": "<p>Hi</p>"],
            "internetMessageHeaders": [["name": "Authentication-Results", "value": "spf=fail; dmarc=fail header.from=bank.com"],
                                       ["name": "Authentication-Results", "value": "dmarc=pass"],
                                       ["name": "List-Unsubscribe", "value": "<mailto:u@x.com>"]]]
        let m = messageFromGraph(j, account: "me@outlook.com", inInbox: true)!
        XCTAssertEqual(m.threadId, "conv1")
        XCTAssertEqual(Set(m.labelIds), ["INBOX", "UNREAD", "STARRED", "IMPORTANT"])
        XCTAssertEqual(parseAddresses(m.from).first?.email, "sam@outlook.com")
        XCTAssertEqual(parseAddresses(m.to).map(\.email), ["me@outlook.com", "b@x.com"])
        XCTAssertEqual(m.snippet, "Want to grab lunch")
        XCTAssertEqual(m.html, "<p>Hi</p>")
        XCTAssertEqual(m.authFailed, true)            // Microsoft's own header (first) wins over a later fake pass
        XCTAssertEqual(m.listUnsubscribe, "<mailto:u@x.com>")
        XCTAssertEqual(m.replyTo, "\"Sam\" <sam@work.com>")
        // Read, unflagged, "Other", archived: no INBOX/UNREAD/STARRED/IMPORTANT.
        let other = messageFromGraph(["id": "2", "conversationId": "c", "isRead": true, "inferenceClassification": "other",
                                      "flag": ["flagStatus": "notFlagged"], "body": ["contentType": "text", "content": "plain"]],
                                     account: "me@outlook.com", inInbox: false)!
        XCTAssertEqual(other.labelIds, [])
        XCTAssertEqual(other.text, "plain")
        XCTAssertEqual(other.subject, "(no subject)")
        XCTAssertNil(messageFromGraph(["id": "x"], account: "a", inInbox: true)) // no conversation id
    }

    func testAttachmentFromGraph() {
        let inline = attachmentFromGraph(["@odata.type": "#microsoft.graph.fileAttachment", "id": "A1", "name": "logo.png",
                                          "contentType": "image/PNG", "size": 1200, "isInline": true, "contentId": "<logo@1>"])
        XCTAssertEqual(inline?.contentId, "logo@1")
        XCTAssertEqual(inline?.mimeType, "image/png")
        let file = attachmentFromGraph(["@odata.type": "#microsoft.graph.fileAttachment", "id": "A2", "name": "a.pdf", "isInline": false, "contentId": "x"])
        XCTAssertNil(file?.contentId)
        XCTAssertNil(attachmentFromGraph(["@odata.type": "#microsoft.graph.itemAttachment", "id": "A3"])) // attached emails aren't files
    }
}
