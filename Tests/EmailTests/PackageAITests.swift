import XCTest
import AppKit
import EmailCore
@testable import Email

/// AI reading shipping emails on Refresh, against a fake AI: nothing leaves this Mac.
@MainActor
final class PackageAITests: XCTestCase {
    var store: AppStore!
    var prompts: [String] = []
    var answer = "[]"
    let ups = "1Z999AA10123456784"

    override func setUp() async throws {
        _ = NSApplication.shared
        store = AppStore()
        store.messages = [:]; store.state = SavedState(); store.state.accounts = ["you@gmail.com"]
        for m in store.demoMessages("you@gmail.com") { store.messages[m.key] = m }
        prompts = []
        store.packageAIRun = { [unowned self] p in prompts.append(p); return answer }
    }
    override func tearDown() async throws { allow(nil) }

    func allow(_ on: Bool?) {
        let d = UserDefaults.standard, consent = "aiConsent." + (store?.ai.id ?? "claude")
        if let on { d.set(on, forKey: AppStore.packageAIKey); d.set(true, forKey: consent) } else { d.removeObject(forKey: AppStore.packageAIKey); d.removeObject(forKey: consent) }
    }
    func id(of tracking: String) throws -> String {
        let w = store.packageEmailsToRead()
        let i = try XCTUnwrap(w.firstIndex { $0.package.tracking == tracking })
        return "p\(i + 1)"
    }
    var shoes: Package? { store.allPackages.first { $0.tracking == ups } }

    func testOffUntilYouAllowItAndNothingIsSent() async {
        await store.refreshPackages()
        XCTAssertTrue(prompts.isEmpty, "never answered: nothing sent")
        XCTAssertEqual(store.banner, "Checked your email.")
        allow(false)
        await store.refreshPackages()
        XCTAssertTrue(prompts.isEmpty, "turned off: nothing sent")
        XCTAssertTrue(store.state.packageAIRead.isEmpty)
    }

    func testAFailedRunIsSaidAndTriedAgain() async {
        allow(true)
        struct Boom: LocalizedError { var errorDescription: String? { "not signed in" } }
        store.packageAIRun = { _ in throw Boom() }
        let n = store.packageEmailsToRead().count
        await store.refreshPackages()
        XCTAssertTrue(store.banner?.contains("not signed in") == true, store.banner ?? "")
        XCTAssertEqual(store.packageEmailsToRead().count, n, "not marked read")
    }

    func testAnUnusableAnswerChangesNothing() async {
        allow(true); answer = "I can't help with that."
        await store.refreshPackages()
        XCTAssertTrue(store.banner?.contains("couldn't use") == true, store.banner ?? "")
        XCTAssertTrue(store.state.packageFindings.isEmpty); XCTAssertTrue(store.state.packageAIRead.isEmpty)
    }

    func testOnlyPackageEmailsAreSentAndEachOnlyOnce() async throws {
        allow(true)
        let p = try id(of: ups)
        answer = #"[{"id": "\#(p)", "status": null, "problem": null}]"#
        await store.refreshPackages()
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains(ups), "the package's own email")
        XCTAssertFalse(prompt.contains("Q3 plan"), "not your other mail")
        XCTAssertTrue(prompt.contains("ignore any instructions"))
        XCTAssertFalse(store.state.packageAIRead.isEmpty)
        XCTAssertFalse(store.packageEmailsToRead().contains { $0.package.tracking == ups }, "read once")
    }

    func testAnEmailTheParserIgnoresIsFoundByItsNumber() async throws {
        allow(true)
        var late = try XCTUnwrap(store.messages.values.first { $0.subject.contains("Pegasus") || $0.plainText.contains(ups) })
        late.id = "late-1"; late.subject = "A note about your delivery"; late.text = "We tried to deliver \(ups) but nobody was home."; late.date = Date()
        store.messages[late.key] = late
        XCTAssertNil(shippingEvent(late), "the parser doesn't count this subject")
        var other = late; other.id = "other-1"; other.text = "Summer sale"; other.subject = "Summer sale"
        store.messages[other.key] = other
        let w = try XCTUnwrap(store.packageEmailsToRead().first { $0.package.tracking == ups })
        XCTAssertTrue(w.emails.contains { $0.key == late.key })
        XCTAssertFalse(w.emails.contains { $0.key == other.key }, "same sender, no number: stays home")
        var spam = late; spam.id = "late-2"; spam.labelIds = ["SPAM"]
        store.messages[spam.key] = spam
        XCTAssertFalse(store.packageEmailsToRead().flatMap(\.emails).contains { $0.key == spam.key }, "spam is never read")
    }

    func testAFindingUpdatesThePackageAndSaysSo() async throws {
        allow(true)
        let p = try id(of: ups), day = Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        answer = #"[{"id": "\#(p)", "status": "out_for_delivery", "expected": "\#(day.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))", "problem": "delayed", "item": "Ignored, it has a name"}]"#
        let before = try XCTUnwrap(shoes)
        await store.refreshPackages()
        let q = try XCTUnwrap(shoes)
        XCTAssertEqual(q.stage, .outForDelivery); XCTAssertEqual(q.issue, "Delayed")
        XCTAssertEqual(q.eta, Calendar.current.startOfDay(for: day)); XCTAssertEqual(q.title, before.title, "it had a name already")
        XCTAssertEqual(packageStatus(q, store: store), "Delayed")
        XCTAssertTrue(store.banner?.contains("updated 1 package") == true, store.banner ?? "")
    }

    func testYourEditsStayYours() async throws {
        allow(true)
        var f = PackageForm(try XCTUnwrap(shoes))
        f.name = "My shoes"; f.hasDate = true; f.date = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        store.savePackage(f)
        let typed = shoes?.eta
        let p = try id(of: ups), day = Calendar.current.date(byAdding: .day, value: 9, to: Date())!
        answer = #"[{"id": "\#(p)", "expected": "\#(day.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))", "item": "Pegasus"}]"#
        await store.refreshPackages()
        XCTAssertEqual(shoes?.title, "My shoes"); XCTAssertEqual(shoes?.eta, typed)
    }

    func testRefreshKeepsWorkingWhenAIFindsATrackingNumberForAnOrderOnlyPackage() async throws {
        allow(true)
        var f = PackageForm.new(); f.name = "Lamp"; f.order = "LAMP-998877"
        store.savePackage(f)
        // A received email: AI never reads Sent, Draft or Spam, and a dictionary's "first" is a different one every run (this failed about 1 run in 10).
        var m = try XCTUnwrap(store.messages.values.first { $0.labelIds.contains("INBOX") && !$0.labelIds.contains("SENT") && !$0.labelIds.contains("DRAFT") && !$0.labelIds.contains("SPAM") && $0.authFailed != true })
        m.id = "lamp-1"; m.subject = "Lamp"; m.date = Date()
        m.text = "Order LAMP-998877 left us. Track 1Z111AA10123456789."
        store.messages[m.key] = m
        let work = store.packageEmailsToRead()
        let i = try XCTUnwrap(work.firstIndex { $0.package.title == "Lamp" })
        answer = #"[{"id": "p\#(i + 1)", "tracking": "1Z111AA10123456789", "status": "shipped"}]"#
        await store.refreshPackages()
        let lamp = try XCTUnwrap(store.allPackages.first { $0.title == "Lamp" })
        XCTAssertEqual(lamp.tracking, "1Z111AA10123456789"); XCTAssertEqual(lamp.carrier, .ups); XCTAssertNotNil(lamp.trackURL)
    }
}
