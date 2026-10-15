import SwiftUI
import EmailCore

/// Shown above an email that carries a calendar invite: when, who, the video call, and Yes / Maybe / No.
struct InviteCard: View {
    @EnvironmentObject var store: AppStore
    let message: Message
    @State private var invite: Invite?
    @State private var answer: RSVP?
    @State private var sending: RSVP?
    @State private var needsAccess = false
    @State private var error: String?

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
                            .prominentGlassButton().buttonBorderShape(.capsule).help(c.url.absoluteString)
                    }
                }
                if inv.isCancelled {
                    Text("This event was cancelled.").font(.scaled(.callout)).foregroundStyle(.secondary)
                } else if !iAmOrganizer(inv) {
                    HStack(spacing: 8) {
                        Text("Going?").font(.scaled(.callout)).foregroundStyle(.secondary)
                        ForEach(RSVP.allCases, id: \.self) { r in
                            Button { respond(inv, r) } label: {
                                HStack(spacing: 5) {
                                    if sending == r { ProgressView().controlSize(.mini) }
                                    else if answer == r { Image(systemName: "checkmark") }
                                    Text(r.label)
                                }.frame(minWidth: 52)
                            }
                            .buttonBorderShape(.capsule)
                            .tint(answer == r ? (r == .declined ? .red : Theme.accent) : nil)
                            .modifier(Chosen(on: answer == r))
                            .disabled(sending != nil)
                        }
                    }
                    if needsAccess {
                        HStack(spacing: 8) {
                            Text("To update your Google Calendar, Keymail needs your OK once.").font(.scaled(.caption)).foregroundStyle(.secondary)
                            Button("Allow calendar access") {
                                Task { if await store.grantCalendarAccess(for: message.account) { needsAccess = false; await load() } }
                            }.controlSize(.small)
                        }
                    }
                    if let error { Text(error).font(.scaled(.caption)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
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
        answer = await store.currentRSVP(inv, account: message.account)
    }

    func iAmOrganizer(_ inv: Invite) -> Bool {
        Set(store.fromAddresses.map { $0.lowercased() }).contains(inv.organizer.lowercased())
    }

    func respond(_ inv: Invite, _ r: RSVP) {
        sending = r; error = nil
        Task {
            defer { sending = nil }
            do { store.banner = try await store.rsvp(inv, r, message: message); answer = r }
            catch is NeedsCalendarAccess { needsAccess = true }
            catch { self.error = error.localizedDescription }
        }
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

/// The chosen answer gets the filled style; the others stay quiet.
private struct Chosen: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.prominentGlassButton() } else { content }
    }
}
