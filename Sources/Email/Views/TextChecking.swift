import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Spelling & grammar

/// Turns on macOS spelling/grammar checking for the compose body (not the To/Subject fields,
/// where autocorrect would mangle addresses). Follows Settings → General → Writing.
struct TextChecking: NSViewRepresentable {
    @AppStorage("spellcheck") private var spellcheck = true
    @AppStorage("grammar") private var grammar = true
    @AppStorage("autocorrect") private var autocorrect = true
    @AppStorage("smartQuotes") private var smartQuotes = false
    @AppStorage("writingToolsButton") private var writingToolsButton = false

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let (s, g, a, q, wt) = (spellcheck, grammar, autocorrect, smartQuotes, writingToolsButton)
        // The editor is created after this view, so apply once the window has laid out.
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let root = v.window?.contentView else { return }
                for tv in Self.textViews(in: root) where !tv.isFieldEditor {
                    tv.isContinuousSpellCheckingEnabled = s
                    tv.isGrammarCheckingEnabled = g
                    tv.isAutomaticSpellingCorrectionEnabled = a
                    tv.isAutomaticQuoteSubstitutionEnabled = q
                    tv.isAutomaticDashSubstitutionEnabled = q
                    // Apple Intelligence's floating Writing Tools button. Off by default: Lightmail has its own Write button.
                    if #available(macOS 15.1, *) { tv.writingToolsBehavior = wt ? .default : .none }
                }
            }
        }
    }
    static func textViews(in v: NSView) -> [NSTextView] {
        (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap { textViews(in: $0) }
    }
}

/// The ✕ on a chip: a 20pt round target (not just the glyph), highlighted on hover.
struct ChipRemoveButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.15 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(hover ? .primary : .secondary)
        .onHover { hover = $0 }
        .handCursor()
        .help("Remove")
    }
}
