import Foundation
import EmailCore

/// Demo build only: the sign-in buttons add a sample account filled with made-up mail, and nothing touches the
/// network, so the whole app can be clicked through end to end. Each launch starts over at the welcome screen.
extension AppStore {
    func addDemoAccount(_ provider: String) {
        let email = ["icloud": "you@icloud.com", "microsoft": "you@outlook.com"][provider] ?? "you@gmail.com"
        if provider == "icloud", !state.icloud.contains(email) { state.icloud.append(email) }
        if provider == "microsoft", !state.microsoft.contains(email) { state.microsoft.append(email) }
        if !state.accounts.contains(email) { state.accounts.append(email) }
        for m in demoMessages(email) { messages[m.key] = m }
        saveCache()
    }

    /// Demo send: the message appears in the conversation (or Sent) instead of going anywhere.
    func demoSend(_ d: Draft) {
        let acct = account(for: d.from)
        let m = Message(id: UUID().uuidString, threadId: d.threadId ?? UUID().uuidString, account: acct, from: d.from, to: d.to,
                        cc: d.cc, subject: d.subject, snippet: String(d.body.prefix(120)), date: Date(), labelIds: ["SENT"],
                        messageIdHeader: d.messageId ?? "", references: d.references, text: d.body)
        messages[m.key] = m
    }

    func demoMessages(_ a: String) -> [Message] {
        let now = Date()
        func msg(_ thread: String, _ from: String, _ subject: String, _ body: String, minutesAgo: Double,
                 labels: [String] = ["INBOX", "UNREAD"], html: String? = nil, unsubscribe: String = "") -> Message {
            Message(id: "\(thread)-\(Int(minutesAgo))", threadId: thread, account: a, from: from, to: a, subject: subject,
                    snippet: String(body.replacingOccurrences(of: "\n", with: " ").prefix(140)), date: now.addingTimeInterval(-minutesAgo * 60),
                    labelIds: labels, messageIdHeader: "<\(thread)-\(Int(minutesAgo))@demo.keymail>", listUnsubscribe: unsubscribe,
                    html: html, text: html == nil ? body : nil)
        }
        let maya = "Maya Rodriguez <maya@northwind.co>", sam = "Sam Okafor <sam@northwind.co>"
        // An invite that clashes with the sample week's Tuesday 11:00 Client Meeting, so the "Your Tuesday" strip has something to show.
        var invite = msg("roadmap", maya, "Invitation: Q4 roadmap review", "Let's walk through the Q4 roadmap before the planning offsite. Please bring your top three bets and anything blocked.\n\nMaya",
                         minutesAgo: 30, labels: ["INBOX", "UNREAD", "IMPORTANT"])
        invite.calendar = demoInviteICS(attendee: a)
        return [
            invite,
            msg("q3", maya, "Q3 plan: budget review before Thursday",
                "Hi,\n\nThe Q3 plan is attached. Could you look over the budget section before Thursday? The hiring line moved up by two roles.\n\nThanks,\nMaya",
                minutesAgo: 12, labels: ["INBOX", "UNREAD", "IMPORTANT"]),
            msg("launch", sam, "Launch checklist", "Here's where we are on launch:\n\n1. Pricing page: done\n2. Onboarding emails: in review\n3. Press list: needs your sign-off\n\nCan you take a look at the press list today?",
                minutesAgo: 300, labels: ["INBOX", "IMPORTANT"]),
            msg("launch", a, "Re: Launch checklist", "Looking now. Will send notes by 3.", minutesAgo: 280, labels: ["SENT"]),
            msg("launch", sam, "Re: Launch checklist", "Perfect, thanks. Also moved the review to 4pm so we have time.", minutesAgo: 45,
                labels: ["INBOX", "UNREAD", "IMPORTANT"]),
            msg("dinner", "Jordan Lee <jordan.lee@gmail.com>", "Dinner Saturday?", "Are you free Saturday around 7? Thinking that new Thai place on 5th.\n\nJordan",
                minutesAgo: 90),
            msg("cert", "Cloud Alerts <alerts@cloudhost.example>", "Action required: your certificate renewal",
                "Your SSL certificate for *.northwind.co expires on Oct 29.\n\nAutomatic renewal failed because the DNS validation record is missing. Add the CNAME record shown in your console to renew before it expires.",
                minutesAgo: 140, labels: ["INBOX", "UNREAD", "IMPORTANT"]),
            msg("news", "The Product Weekly <hello@productweekly.example>", "5 onboarding flows worth stealing",
                "", minutesAgo: 400, labels: ["INBOX", "UNREAD"],
                html: "<div style=\"font-family:-apple-system,sans-serif;max-width:560px;margin:auto\"><h2>5 onboarding flows worth stealing</h2><p>This week: what the best apps do in their first 60 seconds, and why fewer steps beat clever ones.</p><p><a href=\"https://example.com\">Read the issue</a></p><hr><p style=\"color:#888;font-size:12px\">You're getting this because you subscribed.</p></div>",
                unsubscribe: "<https://example.com/unsubscribe>"),
            msg("receipt", "Brightline Coffee <receipts@brightline.example>", "Your receipt from Brightline Coffee",
                "Thanks for your order.\n\nOat latte  $5.75\nAlmond croissant  $4.25\nTotal  $10.00", minutesAgo: 1500, labels: ["INBOX"]),
            msg("invoice", "Billing <billing@designkit.example>", "Invoice #4821 is ready",
                "Your invoice for October is ready. Amount due: $48.00, charged to your card on file on Nov 1.", minutesAgo: 2900, labels: ["INBOX"]),
            msg("intro", "Priya Shah <priya@seedfund.example>", "Intro: you <> Alex at Lumen",
                "Hi both,\n\nAlex runs growth at Lumen and is thinking about the same onboarding problems you are. I think you'd enjoy a call.\n\nI'll let you take it from here.\nPriya",
                minutesAgo: 4300, labels: ["INBOX", "IMPORTANT"]),
            msg("old", maya, "Offsite photos", "Uploaded the offsite photos to the shared folder. A few good ones of the team dinner.",
                minutesAgo: 9000, labels: []),
        ]
    }

    /// Tuesday 11:00–12:00 of the current week, as an invitation from Maya.
    func demoInviteICS(attendee: String) -> String {
        var c = Calendar.current; c.firstWeekday = 2
        let tue = c.date(byAdding: .day, value: 1, to: c.dateInterval(of: .weekOfYear, for: Date())!.start)!
        let start = c.date(bySettingHour: 11, minute: 0, second: 0, of: tue)!
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC")
        return """
        BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:q4-roadmap@demo.keymail\r\nSUMMARY:Q4 roadmap review\r\n\
        DTSTART:\(f.string(from: start))\r\nDTEND:\(f.string(from: start.addingTimeInterval(3600)))\r\n\
        LOCATION:https://northwind.zoom.us/j/90155520417\r\nORGANIZER;CN=Maya Rodriguez:mailto:maya@northwind.co\r\n\
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(attendee)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n
        """
    }
}
