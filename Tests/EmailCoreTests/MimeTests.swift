import XCTest
@testable import EmailCore

final class MimeTests: XCTestCase {
    let raw = """
    From: =?UTF-8?B?Sm9zw6k=?= <jose@x.com>\r
    To: me@icloud.com\r
    Subject: =?UTF-8?Q?Caf=C3=A9_plans?=\r
     continued\r
    Date: Mon, 12 Oct 2026 09:46:00 -0400 (EDT)\r
    Message-ID: <b@x.com>\r
    References: <a@x.com> <b0@x.com>\r
    Content-Type: multipart/mixed; boundary="OUTER"\r
    \r
    --OUTER\r
    Content-Type: multipart/alternative; boundary=INNER\r
    \r
    --INNER\r
    Content-Type: text/plain; charset=iso-8859-1\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    Caf=E9 at noon? See https://x.com/menu=\r
     ok\r
    --INNER\r
    Content-Type: text/html; charset=utf-8\r
    Content-Transfer-Encoding: base64\r
    \r
    PHA+Q2Fmw6kgPGltZyBzcmM9ImNpZDpsb2dvQDEiPjwvcD4=\r
    --INNER--\r
    --OUTER\r
    Content-Type: image/png\r
    Content-ID: <logo@1>\r
    Content-Transfer-Encoding: base64\r
    \r
    iVBORw==\r
    --OUTER\r
    Content-Type: application/pdf; name="plan.pdf"\r
    Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\r
    Content-Transfer-Encoding: base64\r
    \r
    JVBERg==\r
    --OUTER--\r

    """

    func testParseRawMultipart() {
        let p = parseRaw(Data(raw.utf8))
        XCTAssertEqual(p.headers["from"], "José <jose@x.com>")
        XCTAssertEqual(p.headers["subject"], "Café plans continued")
        XCTAssertEqual(p.text?.trimmingCharacters(in: .whitespacesAndNewlines), "Café at noon? See https://x.com/menu ok")
        XCTAssertEqual(p.html, "<p>Café <img src=\"cid:logo@1\"></p>")
        XCTAssertEqual(p.attachments.map(\.ref.name), ["attachment", "résumé.pdf"])
        XCTAssertEqual(p.attachments.map(\.ref.contentId), ["logo@1", nil])
        XCTAssertEqual(p.attachments[1].data, Data("%PDF".utf8))
    }

    func testMessageFromRaw() {
        let m = messageFromRaw(Data(raw.utf8), uid: 42, flags: ["\\Flagged"], account: "me@icloud.com", inInbox: true)
        XCTAssertEqual(m.id, "42")
        XCTAssertEqual(m.threadId, "<a@x.com>")
        XCTAssertEqual(Set(m.labelIds), ["INBOX", "UNREAD", "STARRED", "IMPORTANT"])
        XCTAssertEqual(m.date, parseMailDate("Mon, 12 Oct 2026 13:46:00 +0000"))
        XCTAssertTrue(m.snippet.hasPrefix("Café at noon?"))
        XCTAssertEqual(threadKey(["message-id": "<root@x>"]), "<root@x>")
    }

    func testImportanceHeuristic() {
        XCTAssertTrue(likelyImportant(["from": "Maya <maya@x.com>"]))
        XCTAssertFalse(likelyImportant(["from": "Shop <news@shop.com>", "list-unsubscribe": "<https://x>"]))
        XCTAssertFalse(likelyImportant(["from": "GitHub <noreply@github.com>"]))
    }

    func testIMAPHelpers() {
        XCTAssertEqual(imapSearchUIDs(["* SEARCH 4 9 12", "A3 OK done"]), [4, 9, 12])
        XCTAssertEqual(imapSearchUIDs(["* SEARCH"]), [])
        let f = imapFetchInfo("* 5 FETCH (UID 123 FLAGS (\\Seen \\Flagged) BODY[] {10}")
        XCTAssertEqual(f?.uid, 123); XCTAssertEqual(f?.flags, ["\\Seen", "\\Flagged"])
        XCTAssertNil(imapFetchInfo("* 5 EXISTS"))
        XCTAssertEqual(imapSpecialUse(["* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"", "* LIST (\\Trash) \"/\" \"Deleted Messages\"",
                                       "* LIST (\\HasNoChildren) \"/\" INBOX"]),
                       ["\\Archive": "Archive", "\\Trash": "Deleted Messages"])
        XCTAssertEqual(imapQuote("pa\"ss\\"), "\"pa\\\"ss\\\\\"")
    }

    func testIMAPServerByDomain() {
        XCTAssertEqual(imapServer(for: "me@yahoo.com").imapHost, "imap.mail.yahoo.com")
        XCTAssertEqual(imapServer(for: "me@Yahoo.co.uk").smtpURL, "smtp://smtp.mail.yahoo.com:587")
        XCTAssertEqual(imapServer(for: "me@ymail.com").name, "Yahoo")
        XCTAssertEqual(imapServer(for: "me@icloud.com").imapHost, "imap.mail.me.com")
        XCTAssertEqual(imapServer(for: "me@notyahoo.com").name, "iCloud")
    }
}
