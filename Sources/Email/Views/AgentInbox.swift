import SwiftUI
import EmailCore

/// Agentic layout (preview, Settings → Appearance → Inbox layout): the list on the left, and for the selected email
/// a plan from your AI that you approve (⌘↵), steer in plain words, or decline to handle it yourself.
struct AgentInbox: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    var body: some View {
        HStack(spacing: 0) {
            SplitList().frame(width: min(420, max(300, layout.width * 0.3)))
            Divider().opacity(0.5)
            if let c = store.selected {
                AgentPane(c: c).id(store.instantKey(c))
                    .onAppear { if !store.threadOpen, store.selectedID == nil || store.selectedID == c.id { store.open(c) } }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.scaled(size: 30, weight: .light))
                    Text("No email selected").font(.scaled(.title3).weight(.medium))
                    Text("Pick one on the left, or press J.").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct AgentPane: View {
    @EnvironmentObject var store: AppStore
    let c: Conversation
    @State private var showEmail = false
    @State private var steer = ""

    var body: some View {
        let state = store.agentPlan(c)
        if showEmail || state == .declined {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(state == .declined ? "Plan declined. Handle it yourself, or ask again." : "The email the plan is for.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    Spacer()
                    Button(state == .declined ? "Plan again" : "Back to plan") {
                        if state == .declined { store.agentPlans[store.instantKey(c)] = nil; store.loadAgentPlan(c) }
                        showEmail = false
                    }.quiet()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider().opacity(0.5)
                ThreadView(conversation: c, embedded: true)
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    card(state).frame(maxWidth: 720).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                }
                steerBox(state)
            }
            // A short pause, so holding J doesn't ask the AI about every email you pass.
            .task {
                guard store.agentAIAllowed else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { store.loadAgentPlan(c); store.planAhead(after: c) }
            }
        }
    }

    @ViewBuilder func card(_ state: AgentPlanState?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    status(state)
                    Spacer()
                    Button("Read email") { showEmail = true }.quiet()
                    Text("Preview").font(.scaled(.caption2).weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.selection))
                }
                switch state {
                case .ready(let p):
                    Text(p.headline).font(.scaled(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !p.summary.isEmpty { Text(p.summary).font(.scaled(size: 14)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                case .done(let msg):
                    Text(msg).font(.scaled(size: 18, weight: .semibold))
                case .failed(let msg):
                    Text(msg).font(.scaled(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { store.agentPlans[store.instantKey(c)] = nil; store.loadAgentPlan(c) }.quiet()
                case nil where !store.agentAIAllowed:
                    Text(c.latest.subject.isEmpty ? "(no subject)" : c.latest.subject).font(.scaled(size: 22, weight: .semibold))
                    Text("\(store.ai.name) reads this email and suggests what to do. Nothing happens until you approve.")
                        .font(.scaled(size: 14)).foregroundStyle(Theme.muted)
                    Button("Plan this email") { store.loadAgentPlan(c) }.primaryAction().padding(.top, 4)
                default:
                    Text(c.latest.subject.isEmpty ? "(no subject)" : c.latest.subject).font(.scaled(size: 22, weight: .semibold))
                    ProgressView().controlSize(.small).padding(.top, 2)
                }
            }
            .padding(22)

            if case .ready(let p) = state {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Action plan").font(.scaled(.callout).weight(.medium)).foregroundStyle(.secondary)
                    if p.steps.isEmpty { Text("Nothing to do. Leave it as it is.").font(.scaled(size: 14)) }
                    ForEach(Array(p.steps.enumerated()), id: \.offset) { _, s in StepRow(c: c, step: s) }
                    HStack(spacing: 10) {
                        Button { store.approveAgentPlan() } label: {
                            HStack(spacing: 8) { Text("Approve").fontWeight(.semibold); KeyHint("⌘↵") }.frame(maxWidth: .infinity)
                        }.primaryAction().disabled(p.steps.isEmpty)
                        Button("Decline") { store.declineAgentPlan() }.quiet()
                    }
                    .padding(.top, 6)
                }
                .padding(22)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
    }

    func status(_ state: AgentPlanState?) -> some View {
        let (icon, text): (String, String) = switch state {
        case .ready: ("circle.dashed", "Waiting for you")
        case .done: ("checkmark.circle.fill", "Done")
        case .failed: ("exclamationmark.circle", "Couldn't plan this one")
        case nil where !store.agentAIAllowed: ("sparkles", "Not planned yet")
        default: ("sparkles", "\(store.ai.name) is reading it…")
        }
        return Label(text, systemImage: icon).font(.scaled(.callout)).foregroundStyle(.secondary)
    }

    /// Steer: say what to change in plain words and the plan is redone with it.
    @ViewBuilder func steerBox(_ state: AgentPlanState?) -> some View {
        if case .ready = state {
            HStack(spacing: 8) {
                TextField("Steer: say what to change", text: $steer).textFieldStyle(.plain).font(.scaled(size: 14))
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(.scaled(size: 13, weight: .semibold)) }
                    .buttonStyle(.plain).frame(width: 30, height: 30)
                    .background(Circle().fill(steer.isEmpty ? Color.primary.opacity(0.12) : Color.primary))
                    .foregroundStyle(steer.isEmpty ? Color.secondary : Color(nsColor: .windowBackgroundColor))
                    .disabled(steer.isEmpty)
            }
            .padding(.leading, 18).padding(.trailing, 7).padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .frame(maxWidth: 720).padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    func send() {
        let s = steer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        steer = ""
        store.loadAgentPlan(c, steer: s)
    }
}

/// One step: an icon and what it does; a reply shows its text (Show more) and can be edited before approving.
struct StepRow: View {
    @EnvironmentObject var store: AppStore
    let c: Conversation
    let step: AgentPlan.Step
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.scaled(size: 13)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                Text(title).font(.scaled(size: 15, weight: .semibold))
            }
            if !step.detail.isEmpty, step.kind != .reply {
                Text(step.detail).font(.scaled(size: 13)).foregroundStyle(Theme.muted).padding(.leading, 36)
            }
            if step.kind == .reply, let body = step.body {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Re: " + c.latest.subject.replacingOccurrences(of: "^(?i)re:\\s*", with: "", options: .regularExpression))
                        .font(.scaled(size: 13, weight: .medium))
                    Text(body).font(.scaled(size: 13)).foregroundStyle(Theme.muted).lineSpacing(2)
                        .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack {
                        Button { expanded.toggle() } label: {
                            Label(expanded ? "Show less" : "Show more", systemImage: expanded ? "chevron.up" : "chevron.down")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                        Spacer()
                        Button { store.editAgentReply() } label: { Label("Edit", systemImage: "pencil") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.scaled(.caption))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
                .padding(.leading, 36)
            }
        }
    }

    var icon: String {
        switch step.kind {
        case .reply: "envelope"
        case .star: "star"
        case .archive: "archivebox"
        case .remind: "clock"
        case .trash: "trash"
        }
    }

    var title: String {
        switch step.kind {
        case .reply: "Send reply from \(parseAddresses(store.replyFrom(c.replyTarget, account: c.account)).first?.email ?? c.account)"
        case .star: "Star it"
        case .archive: "Archive"
        case .remind: "Remind me \(step.when?.formatted(date: .abbreviated, time: .shortened) ?? "later")"
        case .trash: "Move to Trash"
        }
    }
}
