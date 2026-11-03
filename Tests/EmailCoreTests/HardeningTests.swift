import XCTest
@testable import EmailCore

/// Hostile input and failing helpers: each test here failed, or could not be written, before the hardening pass.
final class HardeningTests: XCTestCase {

    // MARK: Email web view

    func testOnlyKeymailsOwnPageRendersInsideAnEmail() {
        let remote = URL(string: "https://evil.com/fake-sign-in")!
        XCTAssertEqual(emailNavigation(url: URL(string: "about:blank"), startedByPage: true, hasTargetFrame: true), .render, "our own page load")
        XCTAssertEqual(emailNavigation(url: remote, startedByPage: true, hasTargetFrame: true), .block, "a meta refresh or iframe does nothing")
        XCTAssertEqual(emailNavigation(url: URL(string: "data:text/html,x"), startedByPage: true, hasTargetFrame: true), .block)
        XCTAssertEqual(emailNavigation(url: URL(string: "file:///etc/passwd"), startedByPage: true, hasTargetFrame: true), .block)
        XCTAssertEqual(emailNavigation(url: remote, startedByPage: false, hasTargetFrame: true), .open, "a click still goes through the link checks")
        XCTAssertEqual(emailNavigation(url: remote, startedByPage: false, hasTargetFrame: false), .open, "target=_blank too")
    }

    // MARK: Links

    func testLinksThatDisguiseWhereTheyGo() {
        XCTAssertTrue(linkWarning(href: "https://paypal.com@evil.com/login", shown: "Sign in")!.contains("evil.com"))
        for ip in ["http://2130706433/", "http://0x7f000001/", "http://[::1]/", "http://192.168.1.1/"] {
            XCTAssertTrue(linkWarning(href: ip, shown: "Click")?.contains("IP address") == true, ip)
        }
        XCTAssertNotNil(linkWarning(href: "http://intranet/payroll", shown: "Click"), "a name with no dot is no public site")
        XCTAssertNotNil(linkWarning(href: "https://аpple.com/", shown: "Click"), "Cyrillic а")
        // Ordinary links must stay quiet, or people learn to click through the warning.
        for ok in ["https://example.com/a?b=1", "https://www.bbc.co.uk/news", "http://news.example.org/x"] {
            XCTAssertNil(linkWarning(href: ok, shown: "Read more"), ok)
        }
    }

    func testJoinButtonIgnoresLookAlikeMeetingSites() {
        XCTAssertNil(findConference(in: ["https://evilzoom.us/j/123"]))
        XCTAssertNil(findConference(in: ["https://evilwebex.com/meet/x"]))
        XCTAssertNil(findConference(in: ["https://zoom.us.evil.com/j/123"]))
        XCTAssertEqual(findConference(in: ["https://us02web.zoom.us/j/123?pwd=a"])?.kind, .zoom)
        XCTAssertEqual(findConference(in: ["https://zoom.us/j/123"])?.kind, .zoom)
        XCTAssertEqual(findConference(in: ["https://acme.webex.com/meet/x"])?.kind, .webex)
    }

    func testSuspiciousUnsubscribeLinkNeverGetsASilentPost() {
        let lan = URL(string: "https://192.168.1.1/reboot")!, real = URL(string: "https://mail.example.com/u")!
        XCTAssertEqual(unsubscribeAction(header: "<\(lan)>", oneClickPost: true), .open(lan), "no background POST to your own network")
        XCTAssertEqual(unsubscribeAction(header: "<\(real)>", oneClickPost: true), .oneClick(real))
    }

    // MARK: Sign-in

    func testStrayRequestsCantEndASignIn() {
        XCTAssertFalse(oauthRedirectIsOurs(["error": "access_denied"], state: "secret"), "a web page poking the local port")
        XCTAssertFalse(oauthRedirectIsOurs(["code": "x", "state": "wrong"], state: "secret"))
        XCTAssertFalse(oauthRedirectIsOurs(["state": "secret"], state: "secret"), "no answer in it")
        XCTAssertTrue(oauthRedirectIsOurs(["code": "x", "state": "secret"], state: "secret"))
        XCTAssertTrue(oauthRedirectIsOurs(["error": "access_denied", "state": "secret"], state: "secret"), "pressing Cancel still ends it")
    }

    // MARK: Files and hosts named by strangers

    func testAttachmentNamesAreSafeToSave() {
        XCTAssertEqual(safeFilename("../../.ssh/authorized_keys"), "-..-.ssh-authorized_keys")
        XCTAssertFalse(safeFilename("invoice\u{202E}fdp.app").unicodeScalars.contains("\u{202E}"), "direction trick")
        XCTAssertEqual(safeFilename(".zshrc"), "zshrc", "no hidden files")
        XCTAssertEqual(safeFilename(".."), "attachment")
        XCTAssertEqual(safeFilename(""), "attachment")
        XCTAssertEqual(safeFilename("a\r\nb\0.pdf"), "ab.pdf")
        XCTAssertEqual(safeFilename("Q3 report (final).pdf"), "Q3 report (final).pdf", "normal names are untouched")
        XCTAssertEqual(safeFilename("写真.jpg"), "写真.jpg")
        let long = safeFilename(String(repeating: "写", count: 300) + ".pdf")
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertTrue(long.hasSuffix(".pdf"), "a long name keeps its type")
    }

    func testLogosAreOnlyFetchedFromPublicSites() {
        for bad in ["x@192.168.1.1", "x@printer.local", "x@box.internal", "x@localhost", "x@evil/x.com", "x@a..com", "x@e%2fvil.com"] {
            XCTAssertNil(logoDomain(for: bad), bad)
        }
        XCTAssertEqual(logoDomain(for: "health@aws.com"), "aws.com")
        XCTAssertEqual(logoDomain(for: "a@news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(logoSites(for: "acme.com").first, "acme.com")
        XCTAssertFalse(logoSites(for: "acme.com", senderName: "../../evil").contains { $0.contains("/") })
    }

    // MARK: Text

    func testPlainTextFollowsTheHTMLItCameFrom() {
        var m = Message(id: "1", threadId: "t", account: "a", from: "b", html: "<p>first</p>")
        XCTAssertEqual(m.plainText, "first")
        XCTAssertEqual(m.plainText, "first", "a repeat read gives the same answer")
        m.html = "<p>third</p>"   // same id, same length
        XCTAssertEqual(m.plainText, "third", "edited content never shows stale text")
    }

    func testThreadFlagsLookAtEveryMessage() {
        let a = Message(id: "1", threadId: "t", account: "a", from: "b", labelIds: ["UNREAD"])
        let b = Message(id: "2", threadId: "t", account: "a", from: "b", labelIds: ["INBOX", "STARRED"])
        let c = Conversation(account: "a", threadId: "t", messages: [a, b])
        XCTAssertTrue(c.isUnread); XCTAssertTrue(c.inInbox); XCTAssertTrue(c.isStarred)
        XCTAssertFalse(Conversation(account: "a", threadId: "t", messages: [a]).inInbox)
    }

    // MARK: Helper programs (curl sending mail, AI tools)

    func testTheWholeEmailReachesTheSendingProgram() async throws {
        let raw = Data((0..<5_000_000).map { UInt8($0 % 251) })
        let r = try await runProcess("/bin/cat", [], input: raw, timeout: 30)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, raw, "every byte arrives, in order")
    }

    func testSendingIgnoresCurlSettingsFileAndRequiresEncryption() {
        let a = smtpCurlArguments(url: "smtp://smtp.mail.me.com:587", sender: "me@icloud.com", recipients: ["a@x.com", "b@y.com"], configFile: "/tmp/c")
        XCTAssertEqual(a.first, "-q", "curl only honors this as the very first argument")
        XCTAssertTrue(a.contains("--ssl-reqd"))
        XCTAssertEqual(a.filter { $0 == "--mail-rcpt" }.count, 2)
        XCTAssertEqual(Array(a.suffix(4)), ["--upload-file", "-", "-K", "/tmp/c"])
    }

    func testAToolFloodingItsErrorOutputDoesntHang() async throws {
        // 1 MB of errors is far past the size of a pipe. Reading stdout first used to wait forever here.
        let r = try await runProcess("/bin/sh", ["-c", "head -c 1000000 /dev/zero >&2; echo done"], timeout: 30)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "done\n")
        XCTAssertEqual(r.stderr.count, 1_000_000)
    }

    func testAToolThatQuitsEarlyIsAnErrorNotACrash() async throws {
        let r = try await runProcess("/bin/sh", ["-c", "exit 3"], input: Data(count: 5_000_000), timeout: 30)
        XCTAssertEqual(r.status, 3)
    }

    func testAStuckToolIsStopped() async throws {
        let start = Date()
        let r = try await runProcess("/bin/sleep", ["60"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testAMissingToolIsAnError() async {
        do { _ = try await runProcess("/no/such/tool", [], timeout: 5); XCTFail("should throw") } catch {}
    }

    // MARK: Agent socket

    private func socketPath() -> String {
        // Unix socket paths are short, so not the long test temp folder.
        "/tmp/km-\(UUID().uuidString.prefix(8)).sock"
    }

    func testLargeRepliesCrossTheAgentSocketWhole() throws {
        let path = socketPath(), text = String(repeating: "é mail\n", count: 700_000)   // about 5 MB, newlines escaped in JSON
        let fd = try XCTUnwrap(AgentSocket.serve(path: path) { _ in ["text": text] })
        defer { AgentSocket.stop(fd, path: path) }
        let reply = AgentSocket.request(["op": "list"], path: path)
        XCTAssertEqual(reply?["text"] as? String, text)
    }

    func testAnAgentHangingUpMidReplyLeavesKeymailRunning() throws {
        let path = socketPath(), big = String(repeating: "x", count: 5_000_000)
        let fd = try XCTUnwrap(AgentSocket.serve(path: path) { _ in ["text": big] })
        defer { AgentSocket.stop(fd, path: path) }
        // Ask for the big reply, then leave without reading it.
        var addr = try XCTUnwrap(AgentSocket.address(path))
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(ok, 0)
        _ = "{\"op\":\"list\"}\n".withCString { write(client, $0, 14) }
        close(client)
        Thread.sleep(forTimeInterval: 0.3)
        // Still answering. This test process doesn't ignore SIGPIPE, so a missing guard would have killed it.
        XCTAssertEqual(AgentSocket.request(["op": "list"], path: path)?["text"] as? String, big)
    }
}
