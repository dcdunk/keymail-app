import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Onboarding

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    enum Step { case welcome, connect, google, accounts, ai, done }
    @State private var step: Step = .welcome
    @State private var showICloud = false
    @State private var installedAI: Set<String> = []   // checked once in the background (it can launch a shell)

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 36)
            Spacer(minLength: 20)
            Group {
                switch step {
                case .welcome: welcome
                case .connect: connect
                case .google: googleSetup
                case .accounts: accounts
                case .ai: ai
                case .done: done
                }
            }
            .frame(maxWidth: 560)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Spacer(minLength: 20)
            if let b = store.busy { Label(b, systemImage: "hourglass").font(.scaled(.callout)).foregroundStyle(.secondary).padding(.bottom, 8) }
            if let b = store.banner { Text(b).font(.scaled(.callout)).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 520).padding(.bottom, 12) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: step)
        .card(isPresented: $showICloud) { ICloudSheet() }
        // Each new account moves you to the accounts step.
        .onChange(of: store.state.accounts.count) { old, new in if new > old { store.banner = nil; step = .accounts } }
        .onAppear { if !store.state.accounts.isEmpty { step = .accounts } }
    }

    var progress: some View {
        let order: [Step] = [.welcome, .connect, .accounts, .ai, .done]
        let i = order.firstIndex(of: step == .google ? .connect : step) ?? 0
        return HStack(spacing: 6) {
            ForEach(0..<order.count, id: \.self) { n in
                Capsule().fill(n <= i ? Theme.accent : Color.primary.opacity(0.12)).frame(width: n == i ? 22 : 8, height: 8)
            }
        }
    }

    func title(_ t: String, _ sub: String) -> some View {
        VStack(spacing: 10) {
            Text(t).font(.scaled(size: 30, weight: .semibold)).multilineTextAlignment(.center)
            Text(sub).font(.scaled(.title3)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    func primary(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).frame(minWidth: 180).padding(.vertical, 4) }
            .prominentGlassButton().controlSize(.large).buttonBorderShape(.capsule).keyboardShortcut(.defaultAction)
    }

    var welcome: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            title("Welcome to Keymail", "Fast, keyboard-first email for Gmail and iCloud.")
            VStack(alignment: .leading, spacing: 14) {
                feature("bolt.fill", "Fly through your inbox", "Every action has a shortcut. ⌘K finds any of them.")
                feature("rectangle.split.3x1.fill", "An inbox that sorts itself", "Split Inbox groups people, newsletters and tools apart.")
                feature("sparkles", "Writing help when you want it", "Drafts, replies and summaries from the AI you already use.")
            }
            primary("Get started") { step = .connect }
        }
    }

    func feature(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.scaled(.title3)).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.scaled(.headline)); Text(d).foregroundStyle(.secondary) }
        }
    }

    var connect: some View {
        VStack(spacing: 24) {
            title("Connect your email", "Your mail goes straight from the provider to this Mac. No servers in between.")
            HStack(spacing: 16) {
                providerCard("envelope.fill", .red, "Gmail", "Google sign-in in your browser") {
                    if store.hasClient { store.addAccount() } else { step = .google }
                }
                providerCard("icloud.fill", .blue, "iCloud Mail", "With an app-specific password") { showICloud = true }
            }
            if !store.state.accounts.isEmpty { Button("Back") { step = .accounts }.buttonBorderShape(.capsule) }
        }
    }

    func providerCard(_ icon: String, _ color: Color, _ name: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.scaled(size: 34)).foregroundStyle(color)
                Text(name).font(.scaled(.title3).weight(.semibold))
                Text(detail).font(.scaled(.callout)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 220, height: 170)
            .floatingPanel(RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).handCursor()
    }

    var googleSetup: some View {
        VStack(spacing: 16) {
            SetupView().frame(height: 460)
            HStack {
                Button("Back") { step = .connect }.buttonBorderShape(.capsule)
                if store.hasClient { primary("Sign in with Google") { store.addAccount() } }
            }
        }
    }

    var accounts: some View {
        VStack(spacing: 24) {
            title("You're connected", "Add every account you use. You can switch with ⌘1, ⌘2…")
            VStack(spacing: 8) {
                ForEach(store.state.accounts, id: \.self) { a in
                    HStack(spacing: 12) {
                        Image(systemName: store.isICloud(a) ? "icloud.fill" : "envelope.fill").foregroundStyle(store.isICloud(a) ? .blue : .red)
                        Text(a)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .floatingPanel(RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack(spacing: 12) {
                Button { step = .connect } label: { Label("Add another account", systemImage: "plus") }.buttonBorderShape(.capsule).controlSize(.large)
                primary("Continue") { step = .ai }
            }
        }
    }

    var ai: some View {
        VStack(spacing: 24) {
            title("Writing help (optional)", "Keymail can draft replies, write quick responses and summarize long threads using an AI tool already signed in on this Mac.")
            VStack(spacing: 8) {
                ForEach(AIProvider.all) { p in
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) { Text(p.name).font(.scaled(.headline)); Text(p.maker).font(.scaled(.caption)).foregroundStyle(.secondary) }
                        Spacer()
                        if installedAI.contains(p.id) {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.scaled(.callout))
                            if store.state.aiProvider == p.id { Text("Selected").font(.scaled(.caption)).foregroundStyle(Theme.accent) }
                            else { Button("Use") { store.state.aiProvider = p.id }.buttonBorderShape(.capsule) }
                        } else {
                            Button("Get it") { NSWorkspace.shared.open(URL(string: p.installURL)!) }.buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .floatingPanel(RoundedRectangle(cornerRadius: 14))
                }
            }
            Text("AI runs read-only: email content can only produce text. You can change this anytime in Settings → AI Providers.")
                .font(.scaled(.callout)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .task {
                for p in AIProvider.all where await Task.detached(operation: { AI.binary(p.binary) }).value != nil { installedAI.insert(p.id) }
            }
            HStack(spacing: 12) {
                Button("Skip") { step = .done }.buttonBorderShape(.capsule).controlSize(.large)
                primary("Continue") { step = .done }
            }
        }
    }

    var done: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill").font(.scaled(size: 56)).foregroundStyle(.green)
            title("You're all set", "A few keys worth knowing. You'll get short tips inside the app too.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                keyRow("⌘K", "Do anything: search every action")
                keyRow("J  K", "Next and previous email")
                keyRow("E", "Done (archive)")
                keyRow("H", "Remind me later")
                keyRow("/", "Search")
                keyRow("C", "Compose")
            }
            .padding(20).floatingPanel(RoundedRectangle(cornerRadius: 20))
            primary("Open my inbox") {
                UserDefaults.standard.set(0, forKey: "coachStep")
                store.state.onboarded = true
            }
        }
    }

    func keyRow(_ k: String, _ d: String) -> some View {
        GridRow {
            Text(k).font(.scaled(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2)))
            Text(d)
        }
    }
}
