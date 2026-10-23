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

final class RSVPOrganizerTests: XCTestCase {
    func invite(_ organizer: String) -> Invite { var i = Invite(); i.organizer = organizer; return i }
    func mail(from: String, authFailed: Bool? = nil) -> Message {
        var m = Message(id: "1", threadId: "t", account: "you@gmail.com", from: from); m.authFailed = authFailed; return m
    }

    func testRSVPSendsAutomaticallyOnlyToVerifiedSender() {
        XCTAssertTrue(organizerIsSender(invite("Boss@Corp.com"), mail(from: "Big Boss <boss@corp.com>")))
        XCTAssertFalse(organizerIsSender(invite("evil@attacker.com"), mail(from: "boss@corp.com")), "organizer differs from sender")
        XCTAssertFalse(organizerIsSender(invite("boss@corp.com"), mail(from: "boss@corp.com", authFailed: true)), "sender failed SPF/DKIM/DMARC")
        XCTAssertTrue(organizerIsSender(invite("boss@corp.com"), mail(from: "boss@corp.com", authFailed: false)))
    }
}
