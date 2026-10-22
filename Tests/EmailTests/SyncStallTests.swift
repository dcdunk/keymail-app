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
