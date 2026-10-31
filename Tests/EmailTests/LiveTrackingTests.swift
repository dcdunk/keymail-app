import XCTest
import AppKit
import EmailCore
@testable import Email

/// Live status from your own tracking server (karrio), against a fake server: no network.
@MainActor
final class LiveTrackingTests: XCTestCase {
    var store: AppStore!
    var asked: [URLRequest] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "xctest")
        store = AppStore()
        store.messages = [:]; store.state = SavedState(); store.state.accounts = ["you@gmail.com"]
        for m in store.demoMessages("you@gmail.com") { store.messages[m.key] = m }
        Keychain.delete(AppStore.trackingKeyAccount)
        asked = []
    }
    override func tearDown() async throws {
        Keychain.delete(AppStore.trackingKeyAccount)
        UserDefaults.standard.removeObject(forKey: "trackingServer")
    }

    func connect(answer code: Int = 200, body: String = #"{"tracking": {"tracking_number": "x", "status": "delivered", "delivered": true, "events": [{"timestamp": "2026-10-31T19:00:00Z", "description": "Delivered, front door", "location": "San Diego, CA"}]}}"#) {
        UserDefaults.standard.set("https://beelink.example.ts.net/", forKey: "trackingServer")
        Keychain.set("key_test123", for: AppStore.trackingKeyAccount)
        store.liveFetch = { [unowned self] req in
            asked.append(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testOffUntilAServerAndKeyAreSet() async {
        store.liveFetch = { [unowned self] req in asked.append(req); throw URLError(.notConnectedToInternet) }
        await store.refreshLiveTracking(force: true)
        XCTAssertTrue(asked.isEmpty, "nothing is sent anywhere by default")
        UserDefaults.standard.set("http://beelink.example/", forKey: "trackingServer")
        Keychain.set("key_test123", for: AppStore.trackingKeyAccount)
        await store.refreshLiveTracking(force: true)
        XCTAssertTrue(asked.isEmpty, "plain http is refused: the key must not travel unencrypted")
    }

    func testAsksOnlyForCarrierPackagesAndAppliesTheAnswer() async throws {
        connect()
        await store.refreshLiveTracking(force: true)
        let paths = asked.map { $0.url!.path }
        XCTAssertTrue(paths.contains("/v1/proxy/tracking/ups/1Z999AA10123456784"), "the UPS package")
        XCTAssertTrue(paths.contains("/v1/proxy/tracking/fedex/771234567890"), "the FedEx package")
        XCTAssertTrue(paths.contains("/v1/proxy/tracking/usps/9400111202062345678901"), "the USPS package")
        XCTAssertFalse(paths.contains { $0.contains("amazon") || $0.contains("113-") }, "never Amazon, never order numbers")
        XCTAssertTrue(asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token key_test123" }, "karrio's API key header")
        XCTAssertTrue(asked.allSatisfy { $0.url!.host == "beelink.example.ts.net" }, "only to your server")
        let ups = try XCTUnwrap(store.allPackages.first { $0.tracking == "1Z999AA10123456784" })
        XCTAssertEqual(ups.stage, .delivered, "the carrier said delivered")
        XCTAssertEqual(ups.live?.events.first?.text, "Delivered, front door")
        let n = asked.count
        await store.refreshLiveTracking()
        XCTAssertEqual(asked.count, n, "delivered packages and fresh answers aren't asked again")
    }

    func testABadKeyStopsAndSaysSo() async {
        connect(answer: 401, body: #"{"detail": "Invalid token."}"#)
        await store.refreshLiveTracking(force: true)
        XCTAssertEqual(asked.count, 1, "stops at the first refusal")
        XCTAssertEqual(store.trackingServerNote, "The tracking server didn't accept the API key.")
        XCTAssertTrue(store.state.packageLive.isEmpty)
    }

    func testConnectionTestListsConnectedCarriers() async {
        connect(body: #"{"count": 2, "results": [{"carrier_name": "ups"}, {"carrier_name": "usps"}, {"carrier_name": "canadapost"}]}"#)
        let r = await store.testTrackingServer()
        XCTAssertEqual(r, "Connected. Live status for UPS, USPS.")
        XCTAssertEqual(asked.last?.url?.path, "/v1/connections")
    }

    func testOpeningPackagesChecksTheServer() async throws {
        connect()
        store.openTool(.packages)
        for _ in 0..<50 where asked.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(asked.isEmpty, "opening Packages asks for fresh status")
    }
}
