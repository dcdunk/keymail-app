import SwiftUI
import EmailCore

/// An AI agent asked to send an email. Nothing goes out until the person presses Send here.
struct AgentApprovalCard: View {
    @EnvironmentObject var store: AppStore
    let approval: AgentApproval
    /// ⌘↵ also sends an inline reply, so a keypress already in flight when the card appears must not approve it.
    @State private var shownAt = Date()

    var body: some View {
        let d = approval.draft
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark").font(.scaled(size: 18)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("An AI agent wants to send this").font(.scaled(.title3).weight(.semibold))
                    Text(approval.sendAt.map { "Scheduled for \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Sends when you approve")
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("From", d.from); recipients("To", d.to)
                if !d.cc.isEmpty { recipients("Cc", d.cc) }
                row("Subject", d.subject)
                if let days = approval.remindDays { row("Remind", "if no reply in \(days) day\(days == 1 ? "" : "s")") }
            }
            .font(.scaled(.callout)).padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                Text(d.body + (d.signaturePlain.map { "\n\n" + $0 } ?? "")).font(.scaled(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            }
            .frame(maxHeight: 280)
            .background(Color.primary.opacity(0.03))

            HStack(spacing: 4) {
                Button("Decline") { finish("The person declined. Nothing was sent.") }.quiet().keyboardShortcut(.cancelAction)
                Button("Edit first") {
                    store.agentApproval = nil
                    store.openCompose(d, context: nil, isReply: !d.inReplyTo.isEmpty)
                    approval.resolve("The person chose to edit it first; it's open in Keymail and they'll send it themselves.")
                }.quiet().keyboardShortcut("e", modifiers: .command).help("Edit first (⌘E)")
                Spacer()
                Button {
                    guard Date().timeIntervalSince(shownAt) > 1 else { return }
                    if let at = approval.sendAt { store.schedule(d, at: at, remindDays: approval.remindDays) }
                    else { store.sendWithUndo(d, remindDays: approval.remindDays) }
                    finish(approval.sendAt == nil ? "Approved and sent (with Keymail's undo window)." : "Approved and scheduled.")
                } label: {
                    HStack(spacing: 8) { Text(approval.sendAt == nil ? "Send" : "Schedule").fontWeight(.semibold); KeyHint("⌘↵") }.padding(.horizontal, 4)
                }
                .primaryAction().keyboardShortcut(.return, modifiers: .command)
            }
            .actionBar()
        }
        .frame(width: 560)
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(v).lineLimit(2).textSelection(.enabled) }
    }

    /// Every recipient, in full: anyone not already on the thread is flagged, so an agent can't slip someone in.
    func recipients(_ k: String, _ header: String) -> some View {
        let outsiders = notInThread(header, participants: approval.participants)
        return GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(header).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(outsiders, id: \.self) { a in
                    Label("\(a) isn't on this thread", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.scaled(.caption))
                }
            }
        }
    }

    func finish(_ outcome: String) { store.agentApproval = nil; approval.resolve(outcome) }
}
