import Foundation

/// Agentic inbox (preview): what the AI suggests doing with one email, which the person approves, steers or declines.
/// Only actions Keymail itself can carry out are allowed, and nothing runs until the person presses Approve.
public struct AgentPlan: Equatable, Codable {
    public enum Kind: String, CaseIterable, Codable { case reply, star, archive, remind, trash }
    public struct Step: Equatable, Codable {
        public var kind: Kind
        public var detail: String       // one line, e.g. "Tell Helena it's restored"
        public var body: String?        // reply: the email text
        public var when: Date?          // remind: when it comes back
        public init(kind: Kind, detail: String, body: String? = nil, when: Date? = nil) {
            self.kind = kind; self.detail = detail; self.body = body; self.when = when
        }
        /// Archive, remind and trash take the email out of view, so a plan has at most one and runs it last.
        public var isFinal: Bool { kind == .archive || kind == .remind || kind == .trash }
    }
    public var headline: String
    public var summary: String
    public var steps: [Step]
    public init(headline: String, summary: String, steps: [Step]) { self.headline = headline; self.summary = summary; self.steps = steps }

    /// Reads the AI's JSON answer. Unknown actions, replies without text and reminders without a readable time are
    /// dropped; only the first archive/remind/trash is kept, and it moves to the end.
    public static func parse(_ text: String, now: Date = Date()) -> AgentPlan? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { return nil }
        let str = { (o: [String: Any], k: String) in (o[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let headline = str(obj, "headline"), summary = str(obj, "summary")
        guard !headline.isEmpty else { return nil }
        var steps: [Step] = [], final: Step?
        for s in obj["steps"] as? [[String: Any]] ?? [] {
            guard let kind = Kind(rawValue: str(s, "action").lowercased()) else { continue }
            var step = Step(kind: kind, detail: str(s, "detail"))
            switch kind {
            case .reply:
                guard !str(s, "body").isEmpty else { continue }
                step.body = str(s, "body")
            case .remind:
                guard let d = parseWhen(str(s, "when"), now: now) else { continue }
                step.when = d
            default: break
            }
            if step.isFinal { if final == nil { final = step } }
            else if !steps.contains(where: { $0.kind == kind }) { steps.append(step) }
        }
        return AgentPlan(headline: headline, summary: summary, steps: steps + (final.map { [$0] } ?? []))
    }
}
