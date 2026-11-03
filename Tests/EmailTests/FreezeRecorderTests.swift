import XCTest
import AppKit
import EmailCore
@testable import Email

@MainActor
final class FreezeRecorderTests: XCTestCase {
    var log: URL!
    override func setUp() async throws {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-\(UUID().uuidString).log")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: log) }

    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    var text: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    /// The whole point: the note must be on disk while the app is still stuck, because a freeze can end in a force quit.
    func testFreezeIsWrittenWhileStuckAndClosedWhenItLetsGo() {
        let r = FreezeRecorder(log: log, threshold: 0.15, interval: 0.02)
        defer { r.stop() }
        r.start { "layout=split email=abc" }
        pump(0.1)
        Thread.sleep(forTimeInterval: 0.6)   // the main thread stops answering
        XCTAssertTrue(text.contains("FREEZE started | layout=split email=abc"), text)
        XCTAssertFalse(text.contains("FREEZE ended"), "still stuck: " + text)
        pump(0.3)
        XCTAssertTrue(text.contains("FREEZE ended after"), text)
        XCTAssertEqual(text.components(separatedBy: "FREEZE started").count - 1, 1, "one freeze, one note: " + text)
        let attrs = try? FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual(attrs?[.posixPermissions] as? Int, 0o600, "readable by you only")
    }

    func testAResponsiveAppWritesNothing() {
        let r = FreezeRecorder(log: log, threshold: 0.3, interval: 0.02)
        defer { r.stop() }
        r.start { "x" }
        pump(0.8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), text)
    }

    func testFreezeBeforeAnyPingStillSaysWhatWasOnScreen() {
        let r = FreezeRecorder(log: log, threshold: 0.1, interval: 0.02)
        defer { r.stop() }
        r.start { "first-layout" }   // no pump: stuck from the very start, as at launch
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(text.contains("| first-layout"), text)
        pump(0.1)
    }

    func testSnapshotHasWhatItNeedsAndNothingPersonal() {
        let me = "secret.person@gmail.com"
        let store = AppStore()
        store.messages = [:]; store.state = SavedState(); store.state.accounts = [me]; store.state.onboarded = true
        let m = Message(id: "m1", threadId: "18f3abc", account: me, from: "Private Sender <private@sender.com>", to: me, subject: "SECRET SUBJECT",
                        snippet: "SECRET SNIPPET", labelIds: ["INBOX", "IMPORTANT"], html: "<p>SECRET BODY</p>")
        store.messages[m.key] = m
        store.goTab(store.shownTabs.first ?? "")
        store.selectedID = store.visible.first?.id
        let s = store.freezeSnapshot
        XCTAssertTrue(s.contains("email=18f3abc"), s)
        XCTAssertTrue(s.contains("layout=") && s.contains("screen=list") && s.contains("messages=1") && s.contains("account=0"), s)
        for leak in ["secret", "SECRET", "private", "gmail"] { XCTAssertFalse(s.contains(leak), s) }
        store.threadOpen = true
        XCTAssertTrue(store.freezeSnapshot.contains("screen=thread"))
    }

    func testIDsBuiltFromHeadersOrSubjectsAreHashed() {
        XCTAssertEqual(AppStore.freezeSafeID("18f3abc"), "18f3abc", "Gmail's are opaque, and stay findable")
        for id in ["subject:my medical results", "<abc@private-domain.com>"] {
            let safe = AppStore.freezeSafeID(id)
            XCTAssertTrue(safe.hasPrefix("sha-"), safe)
            XCTAssertFalse(safe.contains("medical") || safe.contains("private"), safe)
            XCTAssertEqual(safe, AppStore.freezeSafeID(id), "same email, same ID, so repeat freezes line up")
        }
    }

    func testSigningOutDeletesTheLog() {
        let store = AppStore()
        store.state.accounts = ["a@gmail.com"]
        let live = FreezeRecorder.shared.log
        FileManager.default.createFile(atPath: live.path, contents: Data("x\n".utf8))
        store.removeAccount("a@gmail.com")
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }
}
