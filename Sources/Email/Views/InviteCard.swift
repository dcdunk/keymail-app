import SwiftUI
import EmailCore

/// Shown above an email that carries a calendar invite: when, who, the video call, and Yes / Maybe / No.
struct InviteCard: View {
    @EnvironmentObject var store: AppStore
    let message: Message
    @State private var invite: Invite?
    @State private var tapped: RSVP?        // which button shows the spinner
    var answer: RSVP? { invite.flatMap { store.inviteAnswers[$0.uid] } }
    var sending: RSVP? { store.inviteSending == invite?.uid ? tapped : nil }
    var needsAccess: Bool { store.calNeedsAccess.contains(message.account) }

    var body: some View {
        if let inv = invite {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: inv.isCancelled ? "calendar.badge.minus" : "calendar").foregroundStyle(inv.isCancelled ? .red : Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(inv.summary.isEmpty ? "Invitation" : inv.summary).font(.scaled(.headline)).strikethrough(inv.isCancelled)
                        Text(when(inv)).font(.scaled(.callout))
                        Text("Organizer: \(inv.organizerName.isEmpty ? inv.organizer : inv.organizerName)")
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let c = inv.conference, !inv.isCancelled {
                        Button { NSWorkspace.shared.open(c.url) } label: { Label("Join \(c.kind.rawValue)", systemImage: "video.fill") }
                            .primaryAction().help(c.url.absoluteString)
                    }
                }
                if inv.isCancelled {
                    Text("This event was cancelled.").font(.scaled(.callout)).foregroundStyle(.secondary)
                } else if !store.isMine(inv) {
                    if let day = store.inviteDay, day.uid == inv.uid { InviteDayStrip(invite: inv, day: day) }
                    HStack(spacing: 8) {
                        Text("Going?").font(.scaled(.callout)).foregroundStyle(.secondary)
                        ForEach(RSVP.allCases, id: \.self) { r in
                            Button { respond(inv, r) } label: {
                                HStack(spacing: 5) {
                                    if sending == r { ProgressView().controlSize(.mini) }
                                    else if answer == r { Image(systemName: "checkmark") }
                                    Text(r.label)
                                    KeyHint(["ACCEPTED": "Y", "TENTATIVE": "?", "DECLINED": "N"][r.rawValue]!, size: 9.5)
                                }.frame(minWidth: 52)
                            }
                            .tint(answer == r ? (r == .declined ? .red : Theme.accent) : nil)
                            .modifier(Chosen(on: answer == r))
                            .disabled(sending != nil)
                        }
                    }
                    if needsAccess {
                        HStack(spacing: 8) {
                            Text("To update your \(store.isMicrosoft(message.account) ? "Outlook" : "Google") Calendar, Keymail needs your OK once.").font(.scaled(.caption)).foregroundStyle(.secondary)
                            Button("Allow calendar access") {
                                Task { if await store.grantCalendarAccess(for: message.account) { store.calNeedsAccess.remove(message.account); await load() } }
                            }.quiet().font(.scaled(.caption))
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.2)))
        } else {
            Color.clear.frame(height: 0).task(id: message.key) { await load() }
        }
    }

    func load() async {
        guard let inv = await store.invite(in: message) else { return }
        invite = inv
        if store.inviteAnswers[inv.uid] == nil, let r = await store.currentRSVP(inv, account: message.account) { store.inviteAnswers[inv.uid] = r }
        await store.loadInviteDay(inv, message: message)
    }

    func respond(_ inv: Invite, _ r: RSVP) {
        tapped = r
        store.respondToInvite(inv, r, message: message)
    }

    func when(_ inv: Invite) -> String {
        guard let s = inv.start else { return "" }
        if inv.allDay { return s.formatted(.dateTime.weekday(.wide).month().day()) + " · All day" }
        let e = inv.end ?? s
        let sameDay = Calendar.current.isDate(s, inSameDayAs: e)
        return s.formatted(.dateTime.weekday(.wide).month().day().hour().minute()) + " – "
            + (sameDay ? e.formatted(.dateTime.hour().minute()) : e.formatted(.dateTime.month().day().hour().minute()))
            + (inv.rrule != nil ? " · Repeats" : "")
    }
}

/// RSVP answers are quiet tools; the chosen one gets a soft accent wash so Join stays the only filled button.
private struct Chosen: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.buttonStyle(ToolStyle(padded: true))
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.accent.opacity(0.16) : .clear))
    }
}

/// "Your Tuesday": the rest of your day around the invite's time, with the invite outlined, so a clash shows before you answer.
struct InviteDayStrip: View {
    @EnvironmentObject var store: AppStore
    let invite: Invite
    let day: InviteDay
    var body: some View {
        if let s = invite.start {
            let e = invite.end ?? s.addingTimeInterval(3600)
            let cal = Calendar.current
            // Window: 9 to 5, stretched to fit the invite with an hour either side.
            let from = min(cal.date(bySettingHour: 9, minute: 0, second: 0, of: s)!, s.addingTimeInterval(-3600))
            let to = max(cal.date(bySettingHour: 17, minute: 0, second: 0, of: s)!, e.addingTimeInterval(3600))
            let span = to.timeIntervalSince(from)
            let shown = day.events.filter { $0.end > from && $0.start < to }
            let clash = shown.first { $0.start < e && $0.end > s }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Your \(s.formatted(.dateTime.weekday(.wide)))").font(.scaled(.caption)).foregroundStyle(.secondary)
                    Spacer()
                    if let clash { Text("Overlaps \(clash.title)").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.orange) }
                    else { Text("You're free then").font(.scaled(.caption)).foregroundStyle(.secondary) }
                }
                GeometryReader { g in
                    let x = { (d: Date) in CGFloat(max(0, min(1, d.timeIntervalSince(from) / span))) * g.size.width }
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
                        ForEach(shown) { ev in
                            let c = store.calColor(ev)
                            HStack(spacing: 0) {
                                Rectangle().fill(c).frame(width: 2)
                                Text(ev.title).font(.scaled(size: 10.5)).lineLimit(1).padding(.horizontal, 5)
                                Spacer(minLength: 0)
                            }
                            .frame(width: max(4, x(ev.end) - x(ev.start)), height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.3)))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .offset(x: x(ev.start)).help(ev.title)
                        }
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5)
                            .frame(width: max(6, x(e) - x(s)), height: 24).offset(x: x(s))
                            .help("This invite")
                    }
                }
                .frame(height: 26)
                HStack(spacing: 0) {
                    let hours = Int(span / 3600)
                    ForEach(0...hours, id: \.self) { i in
                        Text(from.addingTimeInterval(Double(i) * 3600).formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))))
                            .font(.scaled(size: 9.5)).foregroundStyle(.tertiary)
                        if i < hours { Spacer(minLength: 0) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
