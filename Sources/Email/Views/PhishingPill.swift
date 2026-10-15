import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Phishing warning

/// A small orange pill in the message header; click it for the reasons. Nothing shows when all looks fine.
struct PhishingPill: View {
    let senderReasons: [String]
    let links: [SuspiciousLink]
    var body: some View {
        if !senderReasons.isEmpty || !links.isEmpty {
            MenuButton(width: 340, entries: { [] }, custom: { AnyView(details) }) {
                Label(senderReasons.isEmpty ? "\(links.count) suspicious link\(links.count == 1 ? "" : "s")" : "Check sender",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.scaled(.caption).weight(.medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
            .buttonStyle(.plain).handCursor()
        }
    }

    var details: some View {
                VStack(alignment: .leading, spacing: 10) {
                    Label("This email might be phishing", systemImage: "exclamationmark.shield.fill").font(.scaled(.headline)).foregroundStyle(.orange)
                    ForEach(senderReasons, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
                    ForEach(links.prefix(5), id: \.href) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• " + l.reason).fixedSize(horizontal: false, vertical: true)
                            Text(l.href).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Text("Don't enter passwords or payment details from this email. If unsure, go to the company's site directly.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
    }
}
