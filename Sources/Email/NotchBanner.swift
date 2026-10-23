import AppKit
import SwiftUI
import EmailCore

/// New mail drops out of the MacBook notch instead of a banner in the corner (Settings → General → Notification style).
/// macOS has no notch API: this is a borderless black panel drawn over the notch that grows down, then folds back up.
/// Macs without a notch (or with the lid closed) fall back to normal notifications.
@MainActor
final class NotchBanner {
    static let shared = NotchBanner()
    struct Item { var title: String; var subtitle: String; var body: String; var sender: Address?; var open: () -> Void }

    static var enabled: Bool { !AppFlavor.isTesting && (UserDefaults.standard.string(forKey: "notifyStyle") ?? "notch") == "notch" }

    /// The built-in display with a notch, and the notch's size.
    static var notchScreen: (screen: NSScreen, notch: CGSize)? {
        for s in NSScreen.screens where s.safeAreaInsets.top > 0 {
            let l = s.auxiliaryTopLeftArea?.width ?? 0, r = s.auxiliaryTopRightArea?.width ?? 0
            return (s, CGSize(width: s.frame.width - l - r, height: s.safeAreaInsets.top))
        }
        return nil
    }

    private var panel: NSPanel?
    private var queue: [Item] = []
    private let model = NotchModel()

    /// false when there's no notch to use, so the caller sends a normal notification instead.
    func show(_ item: Item) -> Bool {
        guard Self.notchScreen != nil else { return false }
        queue.append(item)
        if model.item == nil { next() }
        return true
    }

    private func next() {
        // No notch any more (lid closed): drop what's waiting rather than showing it hours later as "new".
        guard let (screen, notch) = Self.notchScreen, !queue.isEmpty else { queue.removeAll(); hide(); return }
        let item = queue.removeFirst()
        let size = NotchModel.open
        let p = panel ?? makePanel()
        p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: false)
        model.notch = notch
        p.orderFrontRegardless()
        model.item = item; model.token = UUID(); model.shownAt = Date()
        if Notifier.sound { NSSound(named: "Glass")?.play() }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.expanded = true }
        schedule()
    }

    /// Folds back into the notch after 5 seconds; the pointer resting on it keeps it open.
    private func schedule() {
        let shown = model.token
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.model.token == shown, self.model.item != nil else { return }
            // Kept open while the pointer rests on it, but never more than a minute.
            if self.model.hovering, Date().timeIntervalSince(self.model.shownAt) < 60 { self.schedule() } else { self.dismiss() }
        }
    }

    func dismiss() {
        guard model.expanded else { return }
        model.hovering = false   // a click hides it before the pointer can "leave", which kept the next one open forever
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.model.item = nil
            self.next()
        }
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar + 1   // above the menu bar, where the notch is
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: NotchView(model: model, tap: { [weak self] in
            self?.model.item?.open(); self?.dismiss()
        }, close: { [weak self] in self?.dismiss() }))
        panel = p
        return p
    }
}

@MainActor
final class NotchModel: ObservableObject {
    static let open = CGSize(width: 420, height: 112)
    @Published var item: NotchBanner.Item?
    @Published var expanded = false
    @Published var hovering = false
    var token = UUID()
    var shownAt = Date()   // which banner a 5-second timer belongs to
    @Published var notch = CGSize(width: 185, height: 32)
}

/// Black, flush with the top edge, rounded at the bottom: from the notch's own size to the open card.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    let tap: () -> Void
    let close: () -> Void

    var body: some View {
        let w = model.expanded ? NotchModel.open.width : model.notch.width
        let h = model.expanded ? NotchModel.open.height : model.notch.height
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                UnevenRoundedRectangle(bottomLeadingRadius: model.expanded ? 22 : 10, bottomTrailingRadius: model.expanded ? 22 : 10)
                    .fill(.black)
                if model.expanded, let item = model.item {
                    HStack(alignment: .top, spacing: 12) {
                        Avatar(address: item.sender, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if !item.subtitle.isEmpty { Text(item.subtitle).font(.system(size: 12, weight: .medium)).lineLimit(1) }
                            if !item.body.isEmpty { Text(item.body).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                        }
                        .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        if model.hovering {
                            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 20, height: 20) }
                                .buttonStyle(.plain).help("Dismiss")
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                    .frame(height: NotchModel.open.height - model.notch.height, alignment: .top)
                    .transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .onHover { model.hovering = $0 }
            Spacer(minLength: 0)
        }
        .frame(width: NotchModel.open.width, height: NotchModel.open.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
