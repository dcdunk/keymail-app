import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Settings window (⌘,)

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag("accounts")
            GmailSettings().tabItem { Label("Gmail", systemImage: "envelope.badge") }.tag("gmail")
            AIProviderSettings().tabItem { Label("AI Providers", systemImage: "sparkles") }.tag("ai")
            SplitSettingsView(embedded: true).tabItem { Label("Split Inbox", systemImage: "rectangle.split.3x1") }.tag("splits")
            SignatureSettings().tabItem { Label("Signatures", systemImage: "signature") }.tag("signatures")
            SnippetSettings().tabItem { Label("Snippets", systemImage: "text.quote") }.tag("snippets")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 700, height: 560)
        .glassButtons()
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("windowOpacity") private var windowOpacity = 0.7
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("grammar") private var grammar = true
    @AppStorage("autocorrect") private var autocorrect = true
    @AppStorage("smartQuotes") private var smartQuotes = false
    @AppStorage("writingToolsButton") private var writingToolsButton = false
    @AppStorage("threadNewestFirst") private var newestFirst = false
    @AppStorage("emailContentTheme") private var contentTheme = "auto"
    @AppStorage("notifyMode") private var notifyMode = "important"
    @AppStorage("badgeMode") private var badgeMode = "important"
    @ObservedObject private var notifier = Notifier.shared
    var body: some View {
        Form {
            Picker("Email content", selection: $contentTheme) {
                Text("Match app").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
            Picker("Messages in a thread", selection: $newestFirst) {
                Text("Oldest first").tag(false); Text("Newest first").tag(true)
            }.pickerStyle(.segmented)
            Picker("Appearance", selection: Binding(get: { store.state.appearance }, set: { store.setAppearance($0) })) {
                Text("Match system").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark")
            }.pickerStyle(.segmented)
            Picker("Undo send", selection: $store.state.undoSendSeconds) {
                Text("Off").tag(0); Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("20 seconds").tag(20); Text("30 seconds").tag(30)
            }
            Section("Auto Archive") {
                ForEach(AutoArchiveCategory.allCases) { cat in
                    Toggle(cat.rawValue, isOn: Binding(
                        get: { store.state.autoArchive.contains(cat) },
                        set: { on in
                            if on { store.state.autoArchive.append(cat); if store.state.autoArchiveSince == nil { store.state.autoArchiveSince = Date() } }
                            else { store.state.autoArchive.removeAll { $0 == cat } }
                        }))
                }
                Text("Applies to new mail from when you turn it on. Starred mail and returned reminders are never auto-archived. Find them under ☰ → Auto Archived.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Calendar") {
                if store.calendar.authorized { Text("Connected to the Calendar app").foregroundStyle(.secondary) }
                else { Button("Allow calendar access") { Task { _ = await store.calendar.requestAccess() } } }
            }
            LabeledContent("Window opacity") {
                HStack {
                    Slider(value: $windowOpacity, in: 0.2...1.0, step: 0.05) { EmptyView() }
                        minimumValueLabel: { Image(systemName: "circle.dotted") } maximumValueLabel: { Image(systemName: "circle.fill") }
                        .frame(maxWidth: 260)
                    Text("\(Int(windowOpacity * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            LabeledContent("Email card opacity") {
                HStack {
                    Slider(value: $cardOpacity, in: 0.2...1.0, step: 0.05) { EmptyView() }
                        minimumValueLabel: { Image(systemName: "circle.dotted") } maximumValueLabel: { Image(systemName: "circle.fill") }
                        .frame(maxWidth: 260)
                    Text("\(Int(cardOpacity * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            Text("Lower values let the glass show through emails. Emails that paint their own white backgrounds stay white in those areas.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Notifications") {
                Picker("Notify me about", selection: $notifyMode) {
                    Text("Important mail").tag("important"); Text("All new mail").tag("all"); Text("Nothing").tag("off")
                }
                .onChange(of: notifyMode) { _, v in if v != "off" { notifier.requestPermission() } }
                Picker("Dock badge counts", selection: $badgeMode) {
                    Text("Unread important").tag("important"); Text("All unread").tag("all"); Text("Nothing").tag("off")
                }
                .onChange(of: badgeMode) { _, v in if v != "off" { notifier.requestPermission() }; notifier.updateBadge() }
                if (notifier.denied && notifyMode != "off") || (notifier.badgeBlocked && badgeMode != "off") {
                    HStack {
                        Text(notifier.denied ? "Notifications are turned off for Lightmail in System Settings."
                                             : "Turn on \"Badge app icon\" for Lightmail in System Settings → Notifications to see the Dock count.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }.controlSize(.small)
                    }
                }
                Button("Send a test notification") { notifier.sendTest() }.controlSize(.small)
                Text("Banners show only while you're in another app. Muted threads never notify. Click a notification to open the email.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { notifier.refreshStatus() }
            Section("Privacy") {
                Toggle("Load remote images", isOn: $loadRemoteImages)
                Text("Senders can use remote images to see when, where and on what device you opened an email. Turning this off blocks all outside content in emails; images attached to the email still show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Check spelling while typing", isOn: $spellcheck)
                Toggle("Check grammar", isOn: $grammar)
                Toggle("Correct spelling automatically", isOn: $autocorrect)
                Toggle("Smart quotes and dashes", isOn: $smartQuotes)
                Toggle("Show Apple's Writing Tools button while typing", isOn: $writingToolsButton)
                Text("Uses macOS's built-in spelling and grammar checker, in your system language. Right-click an underlined word for suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Tips") {
                Button("Show the getting-started tips again") { UserDefaults.standard.set(0, forKey: "coachStep") }
            }
            Toggle("Show folders sidebar", isOn: $store.sidebarOpen)
            Toggle("Show context panel", isOn: $store.contextOpen)
            LabeledContent("Fetch mail") {
                HStack {
                    Text("Every 30 seconds, or ⌘R").foregroundStyle(.secondary)
                    Button("Fetch now") { Task { await store.tick() } }.disabled(store.syncing)
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).padding()
    }
}

struct AccountsSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var showICloud = false
    @State private var showGoogleSetup = false
    @State private var removing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connected accounts").font(.headline)
            if store.state.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(store.state.accounts.enumerated()), id: \.element) { i, acct in
                    let cloud = store.isICloud(acct)
                    HStack(spacing: 12) {
                        Image(systemName: cloud ? "icloud.fill" : "envelope.fill")
                            .foregroundStyle(cloud ? Color.blue : Color.red).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name (e.g. Work, Personal)", text: Binding(
                                get: { store.state.accountNames[acct] ?? "" },
                                set: { store.state.accountNames[acct] = $0 }))
                                .textFieldStyle(.plain).font(.headline)
                            Text("\(acct) · \(cloud ? "iCloud Mail" : "Gmail")").font(.caption).foregroundStyle(.secondary)
                            TextField("Send-as aliases, comma-separated", text: Binding(
                                get: { (store.state.aliases[acct] ?? []).joined(separator: ", ") },
                                set: { store.setAliases($0, for: acct) }))
                                .textFieldStyle(.roundedBorder).font(.caption)
                                .help(cloud ? "Aliases from icloud.com → Mail settings → Accounts" : "Must already be set up under Gmail → Settings → Accounts → Send mail as")
                            if !(store.state.aliases[acct] ?? []).isEmpty {
                                Picker("Send from by default", selection: Binding(
                                    get: { store.sendAddress(acct) },
                                    set: { store.state.defaultFrom[acct] = $0 })) {
                                    ForEach([acct] + (store.state.aliases[acct] ?? []), id: \.self) { Text($0).tag($0) }
                                }
                                .font(.caption).fixedSize()
                            }
                        }
                        Spacer()
                        Text("⌘\(i + 1)").font(.caption).foregroundStyle(.tertiary)
                        Button("Remove") { removing = acct }
                    }.padding(.vertical, 4)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Button { store.addAccount() } label: { Label("Add Google account", systemImage: "plus") }
                    .disabled(!store.hasClient)

                Button { showICloud = true } label: { Label("Add iCloud account", systemImage: "plus") }
            }
            if let b = store.busy { Text(b).font(.callout).foregroundStyle(.secondary) }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GoogleClient.isBuiltIn ? "Google sign-in uses the client built into this app." :
                         store.hasClient ? "Google sign-in uses your own Google Cloud client." : "This build has no Google client.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Use my own Google Cloud client…") { showGoogleSetup = true }.controlSize(.small)
                }.padding(.top, 4)
            }.font(.callout)
            Text("iCloud uses an app-specific password stored in your Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .card(isPresented: $showICloud) { ICloudSheet() }
        .card(isPresented: $showGoogleSetup, closeButton: true) { SetupView().frame(width: 640, height: 500) }
        .confirmCard(removing.map { "Remove \($0)?" }, message: "This signs Lightmail out of the account and clears its cached mail from this Mac. Nothing is deleted from the server.",
                     confirm: "Remove account", icon: "person.crop.circle.badge.minus", cancel: { removing = nil }) {
            if let r = removing { store.removeAccount(r) }; removing = nil
        }
    }
}

struct SnippetSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var selection: UUID?
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.state.snippets) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.id) }
                }
                HStack {
                    Button { let s = Snippet(name: "New snippet", body: ""); store.state.snippets.append(s); selection = s.id } label: { Image(systemName: "plus") }
                    Button { store.state.snippets.removeAll { $0.id == selection }; selection = nil } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                    Spacer()
                }.controlSize(.small).padding(8)
            }.frame(width: 200)
            Divider()
            if let i = store.state.snippets.firstIndex(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $store.state.snippets[i].name).textFieldStyle(.roundedBorder)
                    TextEditor(text: $store.state.snippets[i].body).font(.system(size: 14))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    Text("Use {first_name}, {name} or {email} for the first recipient.").font(.callout).foregroundStyle(.secondary)
                }.padding(16)
            } else {
                Text("Select a snippet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
