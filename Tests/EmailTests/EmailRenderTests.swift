import XCTest
import AppKit
import WebKit
@testable import Email

/// Emails drawn the way the thread draws them (EmailWebView.wrap), measured in WebKit.
@MainActor
final class EmailRenderTests: XCTestCase {
    /// Size of the first picture after the page loads.
    func imageSize(_ body: String) async throws -> CGSize {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        let loaded = expectation(description: "loaded")
        let nav = Nav { loaded.fulfill() }
        w.navigationDelegate = nav
        w.loadHTMLString(EmailWebView.wrap(body), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let r = try await w.evaluateJavaScript("var r=document.querySelector('img').getBoundingClientRect();[r.width,r.height]") as! [Double]
        return CGSize(width: r[0], height: r[1])
    }

    /// A plain 640×72 picture, inline so the test needs no network.
    var banner: String {
        let img = NSImage(size: NSSize(width: 640, height: 72), flipped: false) { r in NSColor.systemBlue.setFill(); r.fill(); return true }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return "data:image/png;base64," + rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    func testLogoNextToAFullWidthCellKeepsItsSize() async throws {
        // A newsletter header: the logo's cell sits beside an empty width="100%" cell.
        let html = #"<table><tr><td><img src="\#(banner)"></td><td width="100%"></td></tr></table>"#
        let s = try await imageSize(html)
        XCTAssertEqual(s.width, 640, accuracy: 1, "the logo keeps its width instead of being squeezed to nothing")
        XCTAssertEqual(s.height, 72, accuracy: 1)
    }

    func testPicturesWiderThanTheWindowStillShrinkToFit() async throws {
        for html in [#"<img src="\#(banner)" width="2000">"#, #"<table><tr><td><img src="\#(banner)" width="2000"></td></tr></table>"#] {
            let s = try await imageSize(html)
            XCTAssertLessThanOrEqual(s.width, 760, "a picture never makes the email wider than the window: \(html.prefix(30))")
        }
    }
}

private final class Nav: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done() }
}
