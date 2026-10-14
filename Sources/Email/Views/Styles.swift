import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

extension View {
    /// Pointing-hand cursor on hover, for anything that behaves like a link.
    func handCursor() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    /// Liquid Glass on macOS 26+, frosted material on older systems.
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background(shape.fill(.regularMaterial))
        }
    }
    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glassProminent).tint(Theme.accent) }
        else { self.buttonStyle(.borderedProminent).tint(Theme.accent) }
    }
    /// Default style for every button and menu inside: Liquid Glass on macOS 26+, bordered before.
    @ViewBuilder func glassButtons() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass).menuStyle(.button).modifier(WindowOpacity()) }
        else { self.buttonStyle(.bordered).menuStyle(.button).modifier(WindowOpacity()) }
    }
    /// For menus and panels that float over the inbox: nearly solid, so the list behind doesn't bleed through.
    func floatingPanel<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
            .background(shape.fill(.ultraThickMaterial))
            .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .clipShape(shape)
    }

    /// Fully opaque panel that ignores the window and card opacity settings, so its text is always readable.
    func solidPanel<S: Shape>(_ shape: S) -> some View {
        let solid = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1) }
        return background(shape.fill(Color(nsColor: solid)))
            .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .clipShape(shape).compositingGroup()
    }

    @ViewBuilder func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

enum Theme {
    static let accent = Color(red: 0.29, green: 0.40, blue: 0.93)
    static let selection = Color(red: 0.29, green: 0.40, blue: 0.93).opacity(0.13)
    static let muted = Color.secondary.opacity(0.75)
    static let chipPalette: [Color] = [.green, .red, .purple, .brown, .blue, .orange, .teal, .pink]
    static func chip(_ name: String) -> Color { chipPalette[paletteIndex(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }, count: chipPalette.count)] }
}
