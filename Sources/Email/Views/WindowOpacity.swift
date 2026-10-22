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
        content
            .background {
                ZStack {
                    // The raw WindowServer blur keeps the wallpaper's colour (monocode's look). The AppKit material
                    // greys and desaturates it, so it is only the fallback when the private blur is missing.
                    if !windowBlurAvailable { BehindWindowBlur() }
                    Color(nsColor: .textBackgroundColor).opacity(Self.tint(opacity))
                }
                .ignoresSafeArea()
            }
            .background(ClearWindow(translucent: opacity < 0.999))
            // Clear glass: faint text (snippets, dates, captions) goes to full strength and the faintest steps up a level,
            // so it doesn't sink into the wallpaper. Primary text is unchanged.
            .modifier(GlassContrast(on: Self.boostsText(opacity)))
    }

    /// Below the middle of the slider the desktop shows through enough to wash out grey text.
    static func boostsText(_ opacity: Double) -> Bool { opacity < 0.5 }

    /// Slider 0.2…1.0 (same scale as email cards) maps to 15…100% of Keymail's own background over the blur.
    /// The 15% floor (monocode's minimum) keeps the window reading as Keymail, slightly see-through, never a bare grey HUD.
    static func tint(_ opacity: Double) -> Double {
        0.15 + 0.85 * min(1, max(0, (opacity - 0.2) / 0.8))
    }
}

/// The macOS "behind window" blur. Under-window-background is neutral: it blurs the desktop without adding its own grey,
/// so the tint above it decides the colour.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .underWindowBackground
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Lets the window itself be transparent so the blur shows through.
struct ClearWindow: NSViewRepresentable {
    let translucent: Bool
    final class Coordinator { var applied: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        // The slider updates this on every tick; only touch the window when see-through actually flips.
        let c = context.coordinator
        DispatchQueue.main.async {
            guard let w = v.window, c.applied != translucent else { return }
            c.applied = translucent
            w.acceptsMouseMovedEvents = true
            w.isOpaque = !translucent
            w.backgroundColor = translucent ? .clear : .windowBackgroundColor
            setBackgroundBlur(w, radius: translucent ? 60 : 0)
        }
    }
}

/// Heavier desktop blur than the material alone gives. Uses the private CoreGraphics call macOS itself uses;
/// if a future macOS drops it, the lookup fails and the window keeps the normal material blur.
// ponytail: private API, looked up at runtime so a missing symbol is a no-op, not a crash.
private let blurSymbols: (UnsafeMutableRawPointer, UnsafeMutableRawPointer)? = {
    guard let h = dlopen(nil, RTLD_NOW),
          let conn = dlsym(h, "CGSMainConnectionID"),
          let set = dlsym(h, "CGSSetWindowBackgroundBlurRadius") else { return nil }
    return (conn, set)
}()
let windowBlurAvailable = blurSymbols != nil

private func setBackgroundBlur(_ window: NSWindow, radius: Int32) {
    typealias MainConnection = @convention(c) () -> UInt32
    typealias SetRadius = @convention(c) (UInt32, Int, Int32) -> Int32
    guard let (conn, set) = blurSymbols else { return }
    let cid = unsafeBitCast(conn, to: MainConnection.self)()
    _ = unsafeBitCast(set, to: SetRadius.self)(cid, window.windowNumber, radius)
}

/// One view either way: an if/else here would rebuild the whole window each time the slider crosses the middle.
struct GlassContrast: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.foregroundStyle(.primary,
                                on ? AnyShapeStyle(Color.primary.opacity(0.8)) : AnyShapeStyle(.secondary),
                                on ? AnyShapeStyle(Color(nsColor: .secondaryLabelColor)) : AnyShapeStyle(.tertiary))
    }
}
