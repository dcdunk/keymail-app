import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Settings → About

struct AboutSettings: View {
    @ObservedObject private var updates = Updates.shared
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                Text("Keymail").font(.scaled(size: 24, weight: .semibold))
                Text("Version \(Updates.version) (\(Updates.build))").font(.scaled(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Fast, keyboard-first email for Gmail, iCloud and Outlook.").font(.scaled(.callout)).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updates").font(.scaled(.headline))
                        Text(updateStatus).font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates") { updates.check() }.disabled(!updates.enabled || !updates.canCheck)
                }
                if updates.enabled {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
                }
            }
            .padding(16).frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 8) {
                info("Privacy", "Mail goes straight between this Mac and Google, Apple or Microsoft. Keymail has no servers.")
                info("AI", "Runs through the AI app you choose in AI Providers, signed in on this Mac.")
                info("Requires", "macOS 14 or later")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Your data").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Disk.dir]) }.buttonStyle(.link).handCursor()
                }
            }
            .font(.scaled(.callout)).frame(maxWidth: 460, alignment: .leading)

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://keymailapp.com")!)
                Link("GitHub", destination: URL(string: "https://github.com/dcdunk/keymail-app")!)
                Link("Release notes", destination: URL(string: "https://github.com/dcdunk/keymail-app/releases")!)
                Link("Report a problem", destination: URL(string: "https://github.com/dcdunk/keymail-app/issues/new")!)
            }
            .font(.scaled(.callout)).handCursor()
            Spacer()
            Text("© 2026 Danny Chait. Updates by Sparkle (MIT license).").font(.scaled(.caption2)).foregroundStyle(.tertiary)
        }
        .padding(24).frame(maxWidth: .infinity)
    }

    var updateStatus: String {
        guard updates.enabled else { return "This is a development build. Release builds update themselves." }
        guard let d = updates.lastChecked else { return "Not checked yet" }
        return "Last checked \(d.formatted(.relative(presentation: .named)))"
    }

    func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
