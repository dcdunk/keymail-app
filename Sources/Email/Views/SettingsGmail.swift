import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Settings → Gmail (out of office, signature sync, labels)

struct GmailSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var account = ""
    @State private var v = Vacation()
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var vacationNote: String?
    @State private var sendAs: [Gmail.SendAs] = []
    @State private var sigNote: [String: String] = [:]
    @State private var newLabel = ""
    @State private var deleting: Gmail.Label?

    var body: some View {
        Group {
            if store.gmailAccounts.isEmpty {
                Text("Add a Gmail account in Accounts to manage its settings here.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Picker("Account", selection: $account) {
                        ForEach(store.gmailAccounts, id: \.self) { Text(store.fullLabel($0)).tag($0) }
                    }
                    if store.needsSettingsAccess.contains(account) { accessCallout }
                    outOfOffice
                    signatures
                    labels
                }
                .formStyle(.grouped).scrollContentBackground(.hidden)
            }
        }
        .padding()
        .onAppear { if account.isEmpty { account = store.gmailAccounts.first ?? "" } }
        .task(id: account) { await load() }
        .confirmCard(deleting.map { "Delete the label “\($0.name)”?" }, message: "Emails keep everything else; they just lose this label. This can't be undone.",
                     confirm: "Delete label", icon: "tag.slash", cancel: { deleting = nil }) {
            if let l = deleting { let a = account; store.labelAction(a) { try await store.gmail(a).deleteLabel(l.id) } }
            deleting = nil
        }
    }

    func load() async {
        guard !account.isEmpty else { return }
        await store.checkSettingsAccess(account)
        if let vac = await store.settingsCall(account, { try await store.gmail(account).vacation() }) {
            v = vac; hasStart = vac.start != nil; hasEnd = vac.end != nil; store.vacations[account] = vac
        }
        sendAs = await store.settingsCall(account, { try await store.gmail(account).sendAs() }) ?? []
        await store.loadLabels(account)
    }

    var accessCallout: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Allow Keymail to manage these settings", systemImage: "lock.shield").font(.scaled(.headline))
                Text("To change out of office and signatures here, Google needs your OK. Click below and approve in your browser.")
                    .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Grant access") { store.grantSettingsAccess(for: account) }.prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
    }

    var outOfOffice: some View {
        Section("Out of office") {
            Toggle("Auto-reply while I'm away", isOn: $v.enabled)
            Toggle("Starts", isOn: $hasStart)
            if hasStart { DatePicker("", selection: Binding(get: { v.start ?? Date() }, set: { v.start = $0 })).labelsHidden() }
            Toggle("Ends", isOn: $hasEnd)
            if hasEnd { DatePicker("", selection: Binding(get: { v.end ?? Date().addingTimeInterval(7 * 86400) }, set: { v.end = $0 })).labelsHidden() }
            TextField("Subject", text: $v.subject, prompt: Text("Out of office"))
            TextEditor(text: $v.message).frame(height: 90).font(.scaled(size: 13))
                .overlay(alignment: .topLeading) { if v.message.isEmpty { Text("Message").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false) } }
            Toggle("Only reply to people in my contacts", isOn: $v.contactsOnly)
            if !account.hasSuffix("@gmail.com") { Toggle("Only reply to people in my organization", isOn: $v.domainOnly) }
            HStack {
                if let vacationNote { Text(vacationNote).font(.scaled(.caption)).foregroundStyle(.secondary) }
                Spacer()
                Button("Save") {
                    var out = v
                    if !hasStart { out.start = nil }
                    if !hasEnd { out.end = nil }
                    let a = account
                    Task { vacationNote = await store.saveVacation(out, for: a) ? "Saved to Gmail." : nil }
                }.prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
    }

    var signatures: some View {
        Section("Signature sync") {
            Text("Gmail keeps its own copy of your signature for gmail.com and the Gmail phone app. Copy one way or the other to make them match.")
                .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sendAs.isEmpty { Text("No addresses found for this account.").foregroundStyle(.secondary) }
            ForEach(sendAs) { sa in SignatureSyncRow(sendAs: sa, account: account) { sendAs = $0 } }
        }
    }

    var labels: some View {
        Section("Labels") {
            ForEach(store.gmailLabels[account] ?? []) { l in
                HStack(spacing: 10) {
                    Menu {
                        ForEach(gmailLabelColors, id: \.bg) { c in
                            Button { let a = account; store.labelAction(a) { try await store.gmail(a).updateLabel(l.id, color: c) } } label: {
                                Label(c.bg, systemImage: "circle.fill")
                            }
                        }
                    } label: {
                        Circle().fill(Color(hex: l.bg) ?? Color.secondary.opacity(0.4)).frame(width: 14, height: 14)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Color")
                    LabelNameField(name: l.name) { new in
                        let a = account; store.labelAction(a) { try await store.gmail(a).updateLabel(l.id, name: new) }
                    }
                    Button { deleting = l } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete label")
                }
            }
            HStack {
                TextField("New label", text: $newLabel).onSubmit(addLabel)
                Button("Add", action: addLabel).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Use labels on any email from the right-click menu, ⌘K, or press L.").font(.scaled(.caption)).foregroundStyle(.secondary)
        }
    }

    func addLabel() {
        let name = newLabel.trimmingCharacters(in: .whitespaces), a = account
        guard !name.isEmpty else { return }
        newLabel = ""
        store.labelAction(a) { try await store.gmail(a).createLabel(name) }
    }
}

/// Renames on Return or when you click away, not on every keystroke.
struct LabelNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Label", text: $text).textFieldStyle(.plain).focused($focused)
            .onAppear { text = name }
            .onSubmit { save() }
            .onChange(of: focused) { _, f in if !f { save() } }
    }
    func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != name { commit(t) } else { text = name }
    }
}

extension Color {
    init?(hex: String?) {
        guard let h = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// One address: Email's signature and Gmail's, side by side, with a copy arrow each way.
struct SignatureSyncRow: View {
    @EnvironmentObject var store: AppStore
    let sendAs: Gmail.SendAs
    let account: String
    let refreshed: ([Gmail.SendAs]) -> Void
    @State private var note: String?
    @State private var working = false

    var body: some View {
        let ours = signatureParts(store.signature(for: sendAs.email))
        let oursHTML = ours.html ?? (ours.plain.isEmpty ? "" : plainToHTML(ours.plain))
        let theirs = sendAs.signature
        let same = normalize(plainFromHTML(oursHTML)) == normalize(plainFromHTML(theirs))
        let blocked = gmailSignatureProblem(oursHTML)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(sendAs.email).fontWeight(.medium)
                if sendAs.isPrimary { Text("Primary").font(.scaled(.caption)).foregroundStyle(.secondary) }
                Spacer()
                status(same: same, ours: oursHTML, theirs: theirs)
            }
            HStack(alignment: .center, spacing: 10) {
                preview("In Keymail", oursHTML, empty: "No signature in Keymail")
                VStack(spacing: 8) {
                    Button { run { await store.pushSignature(sendAs.email, account: account) } } label: {
                        Label("Copy to Gmail", systemImage: "arrow.right").labelStyle(.titleAndIcon)
                    }
                    .disabled(oursHTML.isEmpty || same || blocked != nil || working)
                    .help(blocked ?? "Replace Gmail's signature with Keymail's")
                    Button { run { await store.pullSignature(sendAs.email, account: account) } } label: {
                        Label("Copy to Keymail", systemImage: "arrow.left")
                    }
                    .disabled(theirs.isEmpty || same || working)
                    .help("Replace Keymail's signature with Gmail's")
                }
                .buttonBorderShape(.capsule).controlSize(.small).fixedSize()
                preview("In Gmail", theirs, empty: "No signature in Gmail")
            }
            if let blocked, !same { Label(blocked, systemImage: "info.circle").font(.scaled(.caption)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let note { Text(note).font(.scaled(.caption)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    func run(_ f: @escaping () async -> String) {
        working = true
        Task {
            note = await f()
            refreshed((try? await store.gmail(account).sendAs()) ?? [sendAs])
            working = false
        }
    }

    func normalize(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    @ViewBuilder func status(same: Bool, ours: String, theirs: String) -> some View {
        if ours.isEmpty && theirs.isEmpty { Text("No signatures yet").font(.scaled(.caption)).foregroundStyle(.secondary) }
        else if same { Label("In sync", systemImage: "checkmark.circle.fill").font(.scaled(.caption)).foregroundStyle(.green) }
        else { Label("Different", systemImage: "arrow.left.arrow.right.circle").font(.scaled(.caption)).foregroundStyle(.orange) }
    }

    func preview(_ title: String, _ html: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if html.isEmpty {
                    Text(empty).font(.scaled(.callout)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4])))
                } else {
                    EmailWebView(html: html, padding: "8px 10px").frame(maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
