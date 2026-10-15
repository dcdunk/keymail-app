import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Coach tips

/// Marks a part of the screen a coach tip can point at.
struct CoachAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func coachAnchor(_ id: String) -> some View {
        anchorPreference(key: CoachAnchorKey.self, value: .bounds) { id.isEmpty ? [:] : [id: $0] }
    }
}

/// One tip at a time, floating next to the thing it describes with a spotlight on it.
/// coachStep -1 (the default) means no tips.
struct CoachTips: View {
    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy
    @AppStorage("coachStep") private var step = -1

    static let tips: [(anchor: String, icon: String, title: String, body: String)] = [
        ("palette", "command", "⌘K does everything", "Press ⌘K and type what you want, like \"remind\" or \"forward\". The shortcut shows on the right so you learn it as you go."),
        ("tabs", "rectangle.split.3x1", "Your split inbox", "These tabs group your mail. Press Tab to move between them, or the split button at the end to make your own."),
        ("row", "checkmark.circle", "Inbox zero, fast", "Press E to mark an email done and H to bring it back later. Or hover a row and use the buttons."),
        ("search", "magnifyingglass", "Search like you think", "Press / (or click here) and type a name: pick the person, then add words or a date."),
        ("row", "cursorarrow.click.2", "Prefer the mouse?", "Click to open, right-click any email for every action, and use the buttons under each thread."),
    ]

    var body: some View {
        if Self.tips.indices.contains(step) {
            let tip = Self.tips[step]
            let size = proxy.size
            let target = anchors[tip.anchor].map { proxy[$0] }
            let card = CGSize(width: 340, height: 176)
            // Below the target if it fits, otherwise above; fall back to the bottom-right corner.
            let below = target.map { $0.maxY + 14 + card.height < size.height } ?? true
            let origin: CGPoint = target.map { r in
                CGPoint(x: min(max(r.midX - card.width / 2, 16), size.width - card.width - 16),
                        y: below ? r.maxY + 14 : r.minY - 14 - card.height)
            } ?? CGPoint(x: size.width - card.width - 24, y: size.height - card.height - 40)

            ZStack(alignment: .topLeading) {
                if let r = target {
                    // Soft spotlight: dim everything except the target.
                    Color.black.opacity(0.22)
                        .mask {
                            Rectangle().overlay {
                                RoundedRectangle(cornerRadius: 14).frame(width: r.width + 12, height: r.height + 12)
                                    .position(x: r.midX, y: r.midY).blendMode(.destinationOut)
                            }.compositingGroup()
                        }
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: r.width + 12, height: r.height + 12)
                        .position(x: r.midX, y: r.midY)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                        .allowsHitTesting(false)
                    // Arrow from the card to the target.
                    Image(systemName: below ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.scaled(size: 14)).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .position(x: min(max(r.midX, origin.x + 24), origin.x + card.width - 24),
                                  y: below ? origin.y - 6 : origin.y + card.height + 6)
                }
                tipCard(tip).frame(width: card.width).offset(x: origin.x, y: origin.y)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
            .transition(.opacity)
        }
    }

    func tipCard(_ t: (anchor: String, icon: String, title: String, body: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: t.icon).font(.scaled(.title3)).foregroundStyle(Theme.accent)
                Text(t.title).font(.scaled(.headline))
                Spacer()
                Text("\(step + 1) of \(Self.tips.count)").font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            Text(t.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip tips") { step = -1 }.quiet().font(.scaled(.callout))
                Spacer()
                if step > 0 { Button("Back") { step -= 1 }.quiet() }
                Button(step == Self.tips.count - 1 ? "Done" : "Next") { step = step == Self.tips.count - 1 ? -1 : step + 1 }
                    .prominentGlassButton().buttonBorderShape(.capsule)
            }
        }
        .padding(18)
        .floatingPanel(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }
}
