import XCTest
@testable import EmailCore

/// Bold, italic and links typed in the compose box (issue #13).
final class MarkupTests: XCTestCase {
    let sample = "Hi **Bob**, see [the plan](https://x.com/p) and *soon*"

    func testParse() {
        let (text, spans) = Markup.parse(sample)
        XCTAssertEqual(text, "Hi Bob, see the plan and soon")
        XCTAssertEqual(spans, [
            .init(range: NSRange(location: 3, length: 3), bold: true),
            .init(range: NSRange(location: 12, length: 8), link: "https://x.com/p"),
            .init(range: NSRange(location: 25, length: 4), italic: true),
        ])
    }

    func testEverydayStarsStayAsTyped() {
        for s in ["5 * 3 * 2", "a lone * star", "**not closed", "snake_case_name", "[not a link](ftp://x)", "price: $5*", "* bullet\n* bullet"] {
            XCTAssertFalse(Markup.has(s), s)
            XCTAssertEqual(Markup.toPlain(s), s)
            XCTAssertEqual(Markup.toHTML(s), plainToHTML(s))
        }
    }

    func testRoundTrip() {
        for s in [sample, "***both***", "**bold [link](https://a.co) bold**", "line one **x**\nline *two*", "[**big** link](https://a.co)", "plain"] {
            // Same words back, and saving again changes nothing (the editor saves on every keystroke).
            let p = Markup.parse(s), once = Markup.render(p.text, p.spans), q = Markup.parse(once)
            XCTAssertEqual(q.text, p.text, s)
            XCTAssertEqual(Markup.render(q.text, q.spans), once, s)
            XCTAssertEqual(q.spans.count, p.spans.count, s)
        }
    }

    func testRenderKeepsSpacesOutsideMarkers() {
        // Double-click selects "Bob " with its trailing space; bolding it must still parse back.
        let out = Markup.render("Hi Bob there", [.init(range: NSRange(location: 3, length: 4), bold: true)])
        XCTAssertEqual(out, "Hi **Bob** there")
        // Bold across a line break closes and reopens on each line.
        XCTAssertEqual(Markup.render("a\nb", [.init(range: NSRange(location: 0, length: 3), bold: true)]), "**a**\n**b**")
    }

    func testPlainAndHTML() {
        XCTAssertEqual(Markup.toPlain(sample), "Hi Bob, see the plan (https://x.com/p) and soon")
        XCTAssertEqual(Markup.toPlain("[https://a.co](https://a.co)"), "https://a.co")
        XCTAssertEqual(Markup.toPlain("[Maya](mailto:maya@x.com)"), "Maya (maya@x.com)")
        let html = Markup.toHTML(sample + "\nalso https://y.com")
        XCTAssertTrue(html.contains("Hi <b>Bob</b>, see <a href=\"https://x.com/p\">the plan</a> and <i>soon</i><br>"))
        XCTAssertTrue(html.contains("<a href=\"https://y.com\">https://y.com</a>"))
        // A crafted address can't break out of the href.
        XCTAssertFalse(Markup.toHTML("[x](https://a.com/\"onmouseover=alert(1))").contains("\"onmouseover"))
        XCTAssertFalse(Markup.toHTML("**<script>**").contains("<script>"))
    }

    func testFormattedDraftSendsHTMLWithoutSignature() {
        var d = Draft(from: "me@x.com"); d.to = "bob@y.com"; d.subject = "Hi"; d.body = sample
        let html = composeHTML(d)!
        XCTAssertTrue(html.contains("<a href=\"https://x.com/p\">the plan</a>"))
        XCTAssertFalse(fullBody(d).contains("*"))
        XCTAssertTrue(buildRaw(d).contains("multipart/alternative"))
        d.signaturePlain = "Danny"
        XCTAssertTrue(composeHTML(d)!.contains("-- <br>\nDanny"))
        XCTAssertTrue(fullBody(d).hasSuffix("-- \nDanny"))
    }
}
