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
    /// Snippet grey: a little lighter than .secondary, except over clear glass where it needs full strength.
    static var muted: Color { Color.secondary.opacity(WindowOpacity.boostsText(UserDefaults.standard.object(forKey: "windowOpacity") as? Double ?? 0.7) ? 1 : 0.75) }
    static let chipPalette: [Color] = [.green, .red, .purple, .brown, .blue, .orange, .teal, .pink]
    static func chip(_ name: String) -> Color { chipPalette[paletteIndex(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }, count: chipPalette.count)] }
}

/// Settings → Appearance → Text size. Every font in the app goes through these so one setting scales them all.
extension Font {
    static let textSizes: [(label: String, scale: Double)] = [("Small", 0.9), ("Default", 1), ("Large", 1.15), ("Larger", 1.3), ("Largest", 1.5)]
    static var scale: CGFloat { let s = UserDefaults.standard.double(forKey: "textScale"); return s > 0 ? s : 1 }

    /// ⌘+ / ⌘−: the next size up or down.
    static func step(_ by: Int) {
        let i = textSizes.firstIndex { $0.scale >= Double(scale) - 0.001 } ?? 1
        let next = textSizes[min(max(i + by, 0), textSizes.count - 1)].scale
        UserDefaults.standard.set(next, forKey: "textScale")
    }

    static func scaled(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
    /// macOS's point sizes for each text style, scaled.
    static func scaled(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
        let sizes: [Font.TextStyle: CGFloat] = [.largeTitle: 26, .title: 22, .title2: 17, .title3: 15, .headline: 13, .body: 13,
                                                .callout: 12, .subheadline: 11, .footnote: 10, .caption: 10, .caption2: 10]
        return scaled(size: sizes[style] ?? 13, weight: style == .headline ? .bold : .regular, design: design)
    }
}

/// A keyboard shortcut drawn as a small keycap. Uses the surrounding text color (white on a filled button,
/// label color elsewhere) so it stays readable in light and dark mode and on glass.
struct KeyHint: View {
    let key: String
    var size: CGFloat = 11
    init(_ key: String, size: CGFloat = 11) { self.key = key; self.size = size }
    var body: some View {
        Text(Self.display(key)).font(.scaled(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .frame(minWidth: size * 1.7 * Font.scale)
            .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.3), lineWidth: 0.75))
            .accessibilityLabel("Shortcut \(Self.display(key))")
    }
    /// ⇧ reads as an up arrow to many people, so Shift is spelled out ("⇧U" → "Shift U").
    static func display(_ key: String) -> String { key.replacingOccurrences(of: "⇧", with: "Shift ") }
}

/// Keymail's button language, taken from the compose window: quiet tools, one filled capsule per surface,
/// and a tinted action bar along the bottom of cards.
extension View {
    func quiet() -> some View { buttonStyle(ToolStyle(padded: true)) }
    func primaryAction() -> some View { prominentGlassButton().buttonBorderShape(.capsule).controlSize(.large) }
    func actionBar() -> some View {
        padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
    }
}
