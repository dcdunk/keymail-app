import XCTest
@testable import EmailCore

/// Agentic inbox: the AI's JSON answer becomes a plan of actions Keymail can run.
final class AgentPlanTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testParsesAPlanAroundExtraText() {
        let out = """
        Here's the plan:
        ```json
        {"headline": "Confirm the meeting", "summary": "Ann asks about Thursday.",
         "steps": [{"action": "archive", "detail": "done"}, {"action": "Reply", "detail": "say yes", "body": "Thursday works."}]}
        ```
        """
        let p = AgentPlan.parse(out, now: now)
        XCTAssertEqual(p?.headline, "Confirm the meeting")
        XCTAssertEqual(p?.steps.map(\.kind), [.reply, .archive], "archive moves last so the reply goes out first")
        XCTAssertEqual(p?.steps.first?.body, "Thursday works.")
    }

    func testDropsWhatKeymailCantDo() {
        let out = #"""
        {"headline": "Tidy up", "summary": "", "steps": [
          {"action": "restore_account", "detail": "not a Keymail action"},
          {"action": "reply", "detail": "no text"},
          {"action": "remind", "detail": "no time", "when": "whenever"},
          {"action": "trash", "detail": "first final step wins"},
          {"action": "archive", "detail": "second one dropped"},
          {"action": "star", "detail": "kept"}]}
        """#
        XCTAssertEqual(AgentPlan.parse(out, now: now)?.steps.map(\.kind), [.star, .trash])
    }

    func testRemindReadsTheTime() {
        let p = AgentPlan.parse(#"{"headline": "Later", "steps": [{"action": "remind", "detail": "", "when": "2027-03-01 09:00"}]}"#, now: now)
        XCTAssertEqual(p?.steps.first?.kind, .remind)
        XCTAssertNotNil(p?.steps.first?.when)
        XCTAssertNil(AgentPlan.parse(#"{"headline": "Past", "steps": [{"action": "remind", "when": "2001-01-01 09:00"}]}"#, now: now)?.steps.first,
                     "a time in the past is dropped")
    }

    func testNotAPlan() {
        XCTAssertNil(AgentPlan.parse("Sorry, I can't help with that.", now: now))
        XCTAssertNil(AgentPlan.parse(#"{"summary": "no headline"}"#, now: now))
    }
}
