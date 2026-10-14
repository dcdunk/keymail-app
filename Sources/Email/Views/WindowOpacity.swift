import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Window opacity

/// Frosted, see-through window background. Text and email content stay fully opaque; only the backdrop thins out.
struct WindowOpacity: ViewModifier {
    @AppStorage("windowOpacity") private var opacity = 0.7
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // Slider 0.2…1.0 (same scale as email cards) maps to a tint of 0…1 over the blur.
        let tint = max(0, (opacity - 0.2) / 0.8)
        content
            .background {
                ZStack {
                    BehindWindowBlur(dark: scheme == .dark)
                    Color(nsColor: .textBackgroundColor).opacity(tint * tint)
                }
                .ignoresSafeArea()
            }
            .background(ClearWindow(translucent: opacity < 0.999))
    }
}

/// The macOS "behind window" blur, the same material sidebars use.
struct BehindWindowBlur: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        // HUD is the smoky dark glass; popover is its light counterpart. Both let the desktop show through.
        v.material = dark ? .hudWindow : .popover
    }
}

/// Lets the window itself be transparent so the blur shows through.
struct ClearWindow: NSViewRepresentable {
    let translucent: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.acceptsMouseMovedEvents = true
            w.isOpaque = !translucent
            w.backgroundColor = translucent ? .clear : .windowBackgroundColor
        }
    }
}
