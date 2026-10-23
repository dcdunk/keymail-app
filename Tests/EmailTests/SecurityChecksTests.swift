import XCTest
import EmailCore
@testable import Email

/// Guards against an agent or a forged invite sending mail somewhere the person didn't expect.
final class SecurityChecksTests: XCTestCase {
    func testApprovalFlagsRecipientsNotInThread() {
        let onThread: Set<String> = ["you@gmail.com", "maya@x.com"]
        XCTAssertEqual(notInThread("\"Chen, Maya\" <Maya@X.com>, evil@attacker.com", participants: onThread), ["evil@attacker.com"])
        XCTAssertEqual(notInThread("maya@x.com", participants: onThread), [])
        XCTAssertEqual(notInThread("anyone@new.com", participants: nil), [], "a new email has no thread to compare against")
    }
}
