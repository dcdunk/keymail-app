import XCTest
import AppKit
import Network
import WebKit
import EmailCore
@testable import Email

/// The hardening that only shows in a real web view or a real store. The web tests watch an actual local server,
/// and a control proves that server would have seen the request.
@MainActor
final class HardeningFlowsTests: XCTestCase {

    /// Counts requests on a local port.
    final class Server {
        let listener: NWListener
        private(set) var hits = 0
        init() throws {
            let p = NWParameters.tcp; p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: p)
        }
        func start() async -> UInt16 {
            await withCheckedContinuation { c in
                var resumed = false
                listener.stateUpdateHandler = { [listener] s in
                    if case .ready = s, !resumed { resumed = true; c.resume(returning: listener.port!.rawValue) }
                }
                listener.newConnectionHandler = { conn in
                    conn.start(queue: .main)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
                        self?.hits += 1
                        conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in conn.cancel() })
                    }
                }
                listener.start(queue: .main)
            }
        }
    }

    private func settle(_ seconds: Double = 1) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Configured the way EmailWebView configures its views: JavaScript off, no shared storage.
    private func webView(delegate: WKNavigationDelegate? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        w.navigationDelegate = delegate
        return w
    }

    // MARK: Remote content

    func testBlockedEmailsLoadNothingEvenWithoutTheBlockList() async throws {
        let server = try Server(), port = await server.start()
        let email = #"<img src="http://127.0.0.1:\#(port)/pixel.gif"><style>body{background:url(http://127.0.0.1:\#(port)/bg.png)}</style><link rel="stylesheet" href="http://127.0.0.1:\#(port)/x.css">"#

        // Control: without the policy this environment really does make the request.
        let open = webView()
        open.loadHTMLString(EmailWebView.wrap(email, blockRemote: false), baseURL: nil)
        await settle()
        XCTAssertGreaterThan(server.hits, 0, "control: remote content loads when allowed, so the check below means something")

        // The content blocker is deliberately absent here: the app's fail-open case.
        let before = server.hits
        let blocked = webView()
        blocked.loadHTMLString(EmailWebView.wrap(email, blockRemote: true), baseURL: nil)
        await settle()
        XCTAssertEqual(server.hits, before, "a tracking pixel must not reach its server")
        _ = open
    }

    func testTheBlockPolicyKeepsEmailsLookingRight() async throws {
        let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAAMBAQAYqhRxAAAAAElFTkSuQmCC"
        let w = webView()
        w.configuration.userContentController.addUserScript(WKUserScript(source: EmailWebView.Coordinator.darkScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        w.loadHTMLString(EmailWebView.wrap(#"<style>p{color:rgb(1,2,3)}</style><p id="t" style="font-size:20px">Hi</p><div id="b" style="background-color:#fff">x</div><img id="i" src="\#(pixel)">"#, dark: true, blockRemote: true), baseURL: nil)
        await settle()
        let width = try await w.evaluateJavaScript("document.getElementById('i').naturalWidth") as? Int
        XCTAssertEqual(width, 1, "images inside the email still show")
        let size = try await w.evaluateJavaScript("getComputedStyle(document.getElementById('t')).fontSize") as? String
        XCTAssertEqual(size, "20px", "the sender's styles still apply")
        let bg = try await w.evaluateJavaScript("getComputedStyle(document.getElementById('b')).backgroundColor") as? String
        XCTAssertNotEqual(bg, "rgb(255, 255, 255)", "dark mode still recolors the email")
    }

    // MARK: Pages an email tries to load by itself

    func testAnEmailCantReplaceItselfWithARemotePage() async throws {
        let server = try Server(), port = await server.start()
        let coordinator = EmailWebView.Coordinator()
        let w = webView(delegate: coordinator)
        // blockRemote false: the person allowed images, so this is the only thing standing in the way.
        let email = #"<meta http-equiv="refresh" content="0;url=http://127.0.0.1:\#(port)/fake-sign-in"><iframe src="http://127.0.0.1:\#(port)/frame"></iframe><p id="mine">The real email</p>"#
        w.loadHTMLString(EmailWebView.wrap(email, blockRemote: false), baseURL: nil)
        await settle(2)
        XCTAssertEqual(server.hits, 0, "neither the refresh nor the frame reached the sender's server")
        let text = try await w.evaluateJavaScript("document.getElementById('mine').textContent") as? String
        XCTAssertEqual(text, "The real email", "the email is still on screen")
    }

    // MARK: Expensive facts about an email

    func testEmailFactsAreWorkedOutOnce() {
        let html = #"<a href="https://paypa1.com/x">Pay</a><img src="https://x.com/a.png"><div class="gmail_quote">old</div>"#
        let f = EmailFacts.of(html)
        XCTAssertTrue(f === EmailFacts.of(html), "a redraw reuses the answer")
        XCTAssertEqual(f.links.count, 1)
        XCTAssertTrue(f.hasRemote)
        XCTAssertNotNil(f.split.quoted)
        XCTAssertEqual(f.flagged.count, 1, "keyed the way clicks arrive")
        XCTAssertFalse(f === EmailFacts.of(html + " "), "different HTML gets its own")
    }

    func testInlineImagesAppearOnceTheyHaveDownloaded() {
        let f = EmailFacts.of(#"<img src="cid:a1">"#), img = "data:image/png;base64,AAAA"
        XCTAssertEqual(f.inlined(.whole, [:]), #"<img src="cid:a1">"#)
        XCTAssertEqual(f.inlined(.whole, ["a1": img]), "<img src=\"\(img)\">", "the first render without them mustn't stick")
        XCTAssertEqual(f.inlined(.whole, ["a1": img]), "<img src=\"\(img)\">")
    }

    // MARK: Saving

    func testABurstOfChangesEndsUpOnDiskAndTheLastOneWins() {
        let store = AppStore()
        for i in 0..<200 { store.state.muted = ["thread-\(i)"] }
        store.flushState()
        XCTAssertEqual(Disk.load("state.json", as: SavedState.self)?.muted, ["thread-199"])
    }

    func testAChangeIsSavedWithoutAskingOnceTheMainThreadIsFree() async {
        let store = AppStore()
        store.state.muted = ["soon"]
        await settle(0.2)
        store.flushState()
        XCTAssertEqual(Disk.load("state.json", as: SavedState.self)?.muted, ["soon"])
    }

    func testIdenticalMailIsntWrittenTwice() async throws {
        let store = AppStore()
        store.messages = ["a|1": Message(id: "1", threadId: "t", account: "a", from: "b", labelIds: ["INBOX"], text: "hello")]
        store.saveCache()
        await store.cacheWrite?.value
        let file = Disk.dir.appendingPathComponent("cache2.json")
        let first = try Data(contentsOf: file)
        XCTAssertFalse(first.isEmpty)

        store.cacheDirty = true   // a sync reassigning the same mail
        store.saveCache()
        await store.cacheWrite?.value
        XCTAssertEqual(try Data(contentsOf: file), first, "AES-GCM output differs on every write, so equal bytes mean no write")

        store.messages["a|1"]?.text = "changed"
        store.saveCache()
        await store.cacheWrite?.value
        XCTAssertNotEqual(try Data(contentsOf: file), first, "real changes still save")
    }

    // MARK: AI tools

    private func fakeTool(_ script: String) throws -> AIProvider {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ai-\(UUID().uuidString.prefix(8))")
        try ("#!/bin/sh\n" + script).write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: f) }
        return AIProvider(id: "fake", name: "Fake", maker: "", binary: f.path, installURL: "", signInHint: "", models: [], args: { _ in [] })
    }

    func testAIGetsThePromptAndGivesBackItsAnswer() async throws {
        let answer = try await AI.run("hello there", with: try fakeTool("cat"))
        XCTAssertEqual(answer, "hello there")
    }

    func testAIFailureSaysWhatTheToolSaid() async throws {
        do { _ = try await AI.run("x", with: try fakeTool("echo 'Error: please login' >&2; exit 1")); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("please login"), error.localizedDescription) }
    }

    func testAStuckAIToolIsStoppedWithAClearMessage() async throws {
        let keep = AI.timeout; AI.timeout = 0.5; defer { AI.timeout = keep }
        do { _ = try await AI.run("x", with: try fakeTool("sleep 60")); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("took too long"), error.localizedDescription) }
    }
}
