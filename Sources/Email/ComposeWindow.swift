import AppKit
import SwiftUI

/// New emails and replies open in their own window: drag it anywhere, or onto another display.
/// Follows store.composing: a draft appears, the window opens; the draft closes, so does the window.
/// Inline replies (Settings → General → Reply inside the conversation) stay in the main window instead.
@MainActor final class ComposeWindow: NSObject, NSWindowDelegate {
    static let shared = ComposeWindow()
    private(set) var window: NSWindow?
    private var shownID: UUID?
    var isKey: Bool { window?.isKeyWindow ?? false }

    func update(_ store: AppStore) {
        guard !AppFlavor.isTesting else { return }
        guard let m = store.composing, !m.inline else { close(); return }
        if shownID == m.id, let w = window { w.makeKeyAndOrderFront(nil); return }
        shownID = m.id
        let root = ComposeView(model: m)
            .environment(\.closeCard, CloseCard { store.composing = nil })
            .environment(\.popupHost, "compose")
            .overlay { PopupLayer(host: "compose") }
            .coordinateSpace(name: "main")   // menus position themselves in this window
            .frame(minWidth: 560, minHeight: 420)
            .environmentObject(store)        // last, so the menu layer above can see it too
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("KeymailCompose")   // reopens where you last put it, on whichever display
            if !w.setFrameUsingName("KeymailCompose") { w.center() }
            return w
        }()
        w.contentView = NSHostingView(rootView: root)
        w.title = m.draft.subject.isEmpty ? "New email" : m.draft.subject
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func close() {
        shownID = nil
        window?.orderOut(nil)
        window?.contentView = nil
    }

    /// The red close button and ⌘W ask the same "Save this draft?" as ✕ and Esc. An empty draft just closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let store = AppStore.current, let m = store.composing {
            if m.draft.isBlank && m.draft.draftId == nil && m.draftMessage == nil { m.saveTask?.cancel(); store.composing = nil }
            else { m.askClose = true }
        }
        return false   // update() hides it; the window object is reused for the next draft
    }
}
