import AppKit
import SwiftUI
import EmailCore

// MARK: Draft text with formatting (issue #13)
//
// On screen: real bold, italic and links. In the draft: **bold**, *italic* and [text](url) inside the same plain
// String as before, so saving, AI drafting, snippets and agents don't change. Sending turns it into HTML.

/// Selecting text shows a small bar (bold, italic, link). ⌘B, ⌘I and ⌘K do the same from the keyboard.
struct ComposeBody: View {
    @Binding var text: String
    @ObservedObject var fmt: BodyFormatter

    var body: some View {
        BodyEditor(text: $text, fmt: fmt)
            .overlay(alignment: .topLeading) {
                if let a = fmt.anchor {
                    if let edit = fmt.link {
                        LinkCard(fmt: fmt, edit: edit).offset(place(a, CGSize(width: 320, height: 118)))
                    } else if fmt.hasSelection {
                        FormatBar(fmt: fmt).offset(place(a, CGSize(width: 112, height: 32)))
                    }
                }
            }
            .zIndex(1)   // the link card can hang over the signature below
    }

    /// Above the selection, or below it on the first line; never past the box's sides.
    private func place(_ a: CGRect, _ size: CGSize) -> CGSize {
        let x = max(0, min(a.minX, fmt.size.width - size.width))
        let y = a.minY - size.height - 6 >= 0 ? a.minY - size.height - 6 : a.maxY + 6
        return CGSize(width: x, height: y)
    }
}

final class BodyFormatter: NSObject, ObservableObject, NSTextViewDelegate {
    struct LinkEdit: Equatable { var range: NSRange; var text: String; var url: String; var existing: Bool }
    @Published var anchor: CGRect?          // the selection (or caret), in the editor's coordinates, top-left origin
    @Published var hasSelection = false
    @Published var link: LinkEdit?
    @Published var bold = false
    @Published var italic = false
    var size = CGSize.zero
    weak var textView: NSTextView?
    var onChange: ((String) -> Void)?
    private var saved: String?
    private var pointSize: CGFloat = 0
    fileprivate var pendingFocus = false

    var baseFont: NSFont { .systemFont(ofSize: 15 * Font.scale) }
    var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 3
        return [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: p]
    }

    func focus() {
        guard let tv = textView, let w = tv.window else { pendingFocus = true; return }
        pendingFocus = false
        w.makeFirstResponder(tv)
    }

    func isStale(_ markup: String) -> Bool { markup != saved || baseFont.pointSize != pointSize }

    /// Shows `markup` unless it's what the editor itself just saved (typing) and the text size hasn't changed.
    func show(_ markup: String) {
        guard let tv = textView, isStale(markup) else { return }
        saved = markup; pointSize = baseFont.pointSize
        let (text, spans) = Markup.parse(markup)
        let attr = NSMutableAttributedString(string: text, attributes: baseAttributes)
        for sp in spans {
            attr.addAttribute(.font, value: styled(baseFont, bold: sp.bold, italic: sp.italic), range: sp.range)
            if let l = sp.link, let u = URL(string: l) { attr.addAttribute(.link, value: u, range: sp.range) }
        }
        let caret = min(tv.selectedRange().location, attr.length)
        tv.textStorage?.setAttributedString(attr)
        tv.typingAttributes = baseAttributes
        tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// What's on screen, as markup.
    func markup() -> String {
        guard let s = textView?.textStorage else { return "" }
        var spans: [Markup.Span] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { a, r, _ in
            let t = (a[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let l = (a[.link] as? URL)?.absoluteString ?? a[.link] as? String
            if t.contains(.bold) || t.contains(.italic) || l != nil {
                spans.append(.init(range: r, bold: t.contains(.bold), italic: t.contains(.italic), link: l))
            }
        }
        return Markup.render(s.string, spans)
    }

    func textDidChange(_ n: Notification) {
        let m = markup()
        saved = m
        onChange?(m)
        refresh()
    }

    /// Pasted styled text keeps only what an email can carry: bold, italic, links. Fonts and colours go.
    func normalize() { saved = nil; show(markup()); textDidChange(Notification(name: NSText.didChangeNotification)) }

    func textViewDidChangeSelection(_ n: Notification) { refresh() }

    func textView(_ tv: NSTextView, clickedOnLink link: Any, at i: Int) -> Bool {
        tv.setSelectedRange(NSRange(location: i, length: 0))
        beginLink()
        return true   // clicking a link in your own draft edits it instead of opening the browser
    }

    func refresh() {
        guard let tv = textView, let s = tv.textStorage, let scroll = tv.enclosingScrollView else { return }
        size = scroll.bounds.size
        let r = tv.selectedRange()
        // Typing right after a link doesn't make the link longer.
        if r.length == 0, r.location >= s.length || s.attribute(.link, at: r.location, effectiveRange: nil) == nil {
            tv.typingAttributes[.link] = nil
        }
        let attrs = r.length > 0 && r.location < s.length ? s.attributes(at: r.location, effectiveRange: nil) : tv.typingAttributes
        let t = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        bold = t.contains(.bold); italic = t.contains(.italic)
        hasSelection = r.length > 0 && tv.window?.firstResponder === tv
        guard link == nil else { return }   // keep the link card where it opened
        guard hasSelection, let w = tv.window else { anchor = nil; return }
        var rect = scroll.convert(w.convertFromScreen(tv.firstRect(forCharacterRange: r, actualRange: nil)), from: nil)
        if !scroll.isFlipped { rect.origin.y = scroll.bounds.height - rect.maxY }
        anchor = rect
    }

    // MARK: Actions

    func toggle(bold b: Bool) {
        guard let tv = textView, let s = tv.textStorage else { return }
        let r = tv.selectedRange(), on = !(b ? bold : italic)
        func flip(_ f: NSFont) -> NSFont {
            let t = f.fontDescriptor.symbolicTraits
            return styled(f, bold: b ? on : t.contains(.bold), italic: b ? t.contains(.italic) : on)
        }
        if r.length == 0 {
            tv.typingAttributes[.font] = flip(tv.typingAttributes[.font] as? NSFont ?? baseFont)
        } else if tv.shouldChangeText(in: r, replacementString: nil) {
            s.beginEditing()
            s.enumerateAttribute(.font, in: r) { v, sub, _ in s.addAttribute(.font, value: flip(v as? NSFont ?? baseFont), range: sub) }
            s.endEditing()
            tv.didChangeText()
        }
        refresh()
    }

    /// Opens the link card for the selection, or for the link the caret is in.
    func beginLink() {
        guard let tv = textView, let s = tv.textStorage, let w = tv.window else { return }
        var r = tv.selectedRange(), url = ""
        for i in [r.location, r.location - 1] where i >= 0 && i < s.length {
            var found = NSRange()
            if let v = s.attribute(.link, at: i, longestEffectiveRange: &found, in: NSRange(location: 0, length: s.length)) {
                r = found; url = (v as? URL)?.absoluteString ?? v as? String ?? ""
                break
            }
        }
        let text = (s.string as NSString).substring(with: r)
        if url.isEmpty, text.range(of: #"^(https?://|www\.)\S+$"#, options: .regularExpression) != nil { url = text }
        tv.setSelectedRange(r)
        var rect = tv.enclosingScrollView.map { $0.convert(w.convertFromScreen(tv.firstRect(forCharacterRange: r, actualRange: nil)), from: nil) } ?? .zero
        if let scroll = tv.enclosingScrollView, !scroll.isFlipped { rect.origin.y = scroll.bounds.height - rect.maxY }
        anchor = rect
        link = LinkEdit(range: r, text: text, url: url, existing: !url.isEmpty && r.length > 0 && s.attribute(.link, at: r.location, effectiveRange: nil) != nil)
    }

    /// "example.com" becomes https://example.com and "maya@x.com" a mailto link. Nil when it can't be a link.
    static func linkURL(_ typed: String) -> String? {
        var u = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !u.contains(" ") else { return nil }
        if !u.lowercased().hasPrefix("http://"), !u.lowercased().hasPrefix("https://"), !u.lowercased().hasPrefix("mailto:") {
            u = (u.contains("@") && !u.contains("/") ? "mailto:" : "https://") + u
        }
        // Parentheses would end the stored [text](url) early.
        u = u.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return URL(string: u) == nil || !u.contains(".") ? nil : u
    }

    func applyLink(text: String, url: String) {
        guard let tv = textView, let s = tv.textStorage, let edit = link, let u = Self.linkURL(url), let target = URL(string: u) else { return }
        // Square brackets and line breaks would break the stored [text](url).
        var t = text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { t = u.hasPrefix("mailto:") ? String(u.dropFirst(7)) : url.trimmingCharacters(in: .whitespaces) }
        let r = NSRange(location: min(edit.range.location, s.length), length: min(edit.range.length, s.length - min(edit.range.location, s.length)))
        var attrs = r.length > 0 ? s.attributes(at: r.location, effectiveRange: nil) : tv.typingAttributes
        attrs[.link] = target
        link = nil
        if tv.shouldChangeText(in: r, replacementString: t) {
            s.replaceCharacters(in: r, with: NSAttributedString(string: t, attributes: attrs))
            tv.didChangeText()
        }
        focus()
        tv.setSelectedRange(NSRange(location: r.location + (t as NSString).length, length: 0))
    }

    func removeLink() {
        guard let tv = textView, let s = tv.textStorage, let edit = link else { return }
        link = nil
        if NSMaxRange(edit.range) <= s.length, tv.shouldChangeText(in: edit.range, replacementString: nil) {
            s.removeAttribute(.link, range: edit.range)
            tv.didChangeText()
        }
        focus()
    }

    func cancelLink() { link = nil; focus(); refresh() }

    private func styled(_ f: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var t = f.fontDescriptor.symbolicTraits
        if bold { t.insert(.bold) } else { t.remove(.bold) }
        if italic { t.insert(.italic) } else { t.remove(.italic) }
        return NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(t), size: f.pointSize) ?? f
    }
}

private final class BodyTextView: NSTextView {
    weak var formatter: BodyFormatter?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, let f = formatter,
              e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "b": f.toggle(bold: true); return true
        case "i": f.toggle(bold: false); return true
        case "k": f.beginLink(); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }
    override func paste(_ sender: Any?) { super.paste(sender); formatter?.normalize() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if formatter?.pendingFocus == true { DispatchQueue.main.async { self.formatter?.focus() } }
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { self.formatter?.refresh() }   // hide the bar when you click elsewhere
        return ok
    }
}

private struct BodyEditor: NSViewRepresentable {
    @Binding var text: String
    let fmt: BodyFormatter

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = BodyTextView()
        if #available(macOS 15.1, *), !UserDefaults.standard.bool(forKey: "writingToolsButton") { tv.writingToolsBehavior = .none }
        tv.minSize = .zero; tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false   // attachments go in the attachment row, not inside the text
        tv.allowsUndo = true
        tv.isAutomaticLinkDetectionEnabled = false   // plain web addresses become links when sent
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.formatter = fmt
        tv.delegate = fmt
        scroll.documentView = tv; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak fmt] _ in
            fmt?.refresh()   // the bar follows the selection when the text scrolls
        }
        fmt.textView = tv
        fmt.onChange = { text = $0 }
        fmt.show(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        fmt.onChange = { text = $0 }
        // AI, snippets or agents replaced the text (typing doesn't reload). After this update, not during it.
        if fmt.isStale(text) { DispatchQueue.main.async { [text] in fmt.show(text) } }
    }
}

private struct FormatBar: View {
    @ObservedObject var fmt: BodyFormatter
    var body: some View {
        HStack(spacing: 2) {
            tool("bold", on: fmt.bold, "Bold (⌘B)") { fmt.toggle(bold: true) }
            tool("italic", on: fmt.italic, "Italic (⌘I)") { fmt.toggle(bold: false) }
            Divider().frame(height: 16).padding(.horizontal, 2)
            tool("link", on: false, "Add link (⌘K)") { fmt.beginLink() }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .fixedSize()
    }
    private func tool(_ icon: String, on: Bool, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.scaled(size: 13, weight: .semibold)).frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.2) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

private struct LinkCard: View {
    @ObservedObject var fmt: BodyFormatter
    @State private var text: String
    @State private var url: String
    @FocusState private var field: Int?
    private let existing: Bool

    init(fmt: BodyFormatter, edit: BodyFormatter.LinkEdit) {
        self.fmt = fmt; existing = edit.existing
        _text = State(initialValue: edit.text); _url = State(initialValue: edit.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Text", "What the email shows", $text, 0)
            row("Link", "example.com or name@example.com", $url, 1)
            HStack(spacing: 8) {
                if existing { Button("Remove link") { fmt.removeLink() }.buttonStyle(.link) }
                Spacer()
                Button("Cancel") { fmt.cancelLink() }.keyboardShortcut(.cancelAction)
                Button("Apply") { fmt.applyLink(text: text, url: url) }.keyboardShortcut(.defaultAction)
                    .disabled(BodyFormatter.linkURL(url) == nil)
            }
            .font(.scaled(.callout))
        }
        .padding(12).frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .onAppear { DispatchQueue.main.async { field = text.isEmpty ? 0 : 1 } }
    }

    private func row(_ label: String, _ prompt: String, _ value: Binding<String>, _ tag: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.scaled(.callout)).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            TextField(prompt, text: value).textFieldStyle(.roundedBorder).focused($field, equals: tag)
        }
    }
}
