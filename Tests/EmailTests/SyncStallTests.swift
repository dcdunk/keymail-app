import XCTest
import Network
@testable import Email

/// A mail server that accepts the connection and then says nothing (what a dead connection looks like after sleep).
/// Keymail must give up and move on; before, it waited forever and all mail stopped until Keymail was quit.
final class SyncStallTests: XCTestCase {
    func testSilentMailServerTimesOutInsteadOfHangingSync() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { c in c.start(queue: .global()) }   // accept, never reply
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let old = IMAPConnection.silence
        IMAPConnection.silence = 1
        defer { IMAPConnection.silence = old }
        let start = Date()
        do {
            try await IMAPConnection(host: "127.0.0.1", port: listener.port!.rawValue).open()
            XCTFail("a silent server can't succeed")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "gave up instead of waiting forever")
    }
}

final class ICloudSignInTests: XCTestCase {
    /// Only a real password refusal signs an account out; a busy or throttling server is retried later.
    func testOnlyARealRefusalSignsTheAccountOut() {
        XCTAssertTrue(imapLoginRefusal("Mail server: NO [AUTHENTICATIONFAILED] Authentication failed."))
        XCTAssertTrue(imapLoginRefusal("Mail server: NO LOGIN failed"))
        XCTAssertFalse(imapLoginRefusal("Mail server: NO [UNAVAILABLE] Service temporarily unavailable"))
        XCTAssertFalse(imapLoginRefusal("Mail server: NO [LIMIT] Too many simultaneous connections"))
        XCTAssertFalse(imapLoginRefusal("Mail server: NO Please try again later"))
    }

    /// One stray "Authentication Failed" from iCloud no longer signs the account out: it takes 3 in a row,
    /// and a good sign-in in between starts the count over.
    func testOneStrayRefusalDoesNotSignOut() {
        let a = "test-refusal@icloud.com"
        ICloud.setRejected(a, false)
        XCTAssertEqual(ICloud.refused(a), 1)
        XCTAssertEqual(ICloud.refused(a), 2)
        ICloud.refusals(reset: a)   // signed in fine
        XCTAssertEqual(ICloud.refused(a), 1, "the count starts over after a good sign-in")
        XCTAssertEqual(ICloud.refused(a), 2)
        XCTAssertEqual(ICloud.refused(a), 3, "the third in a row is the one that signs out")
        ICloud.setRejected(a, false)
    }
}
