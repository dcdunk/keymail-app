import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Settings → Signatures

struct SignatureSettings: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var store: AppStore
    @State private var selection: String?
    @State private var htmlMode = false
    @State private var note: String?
    func importFile(into binding: Binding<String>) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.html]
        guard p.runModal() == .OK, let url = p.url, let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        binding.wrappedValue = extractBodyHTML(html); note = nil
    }
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.fromAddresses, id: \.self) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.state.accounts.contains(a) ? store.label(a) : a).lineLimit(1)
                        Text(store.state.accounts.contains(a) ? a : "Alias").font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(a)
                }
            }.frame(width: 230)
            Divider()
            if let a = selection {
                let binding = Binding(get: { store.state.signatures[a.lowercased()] ?? "" },
                                      set: { store.state.signatures[a.lowercased()] = $0 })
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Add signature to", selection: $store.state.signatureUse) {
                        Text("All emails").tag("all"); Text("New emails only").tag("new")
                        Text("Replies & forwards only").tag("replies"); Text("Off").tag("off")
                    }.fixedSize()
                    Divider()
                    HStack {
                        Text("Signature for \(a)").font(.scaled(.headline)).lineLimit(1)
                        Spacer()
                        Picker("", selection: $htmlMode) { Text("Visual").tag(false); Text("HTML").tag(true) }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HStack {
                        Button { if let h = SignaturePasteboard.html() { binding.wrappedValue = extractBodyHTML(h) } else { note = "The clipboard has no formatted signature. Copy it from Mail, Gmail or a web page first." } } label: {
                            Label("Paste signature", systemImage: "doc.on.clipboard")
                        }
                        Button { importFile(into: binding) } label: { Label("Import HTML file…", systemImage: "square.and.arrow.down") }.quiet()
                        Spacer()
                        if !binding.wrappedValue.isEmpty { Button("Clear", role: .destructive) { binding.wrappedValue = "" }.quiet().foregroundStyle(.red) }
                    }.controlSize(.small)
                    if htmlMode {
                        TextEditor(text: binding).font(.scaled(size: 12, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    } else if isComplexHTML(binding.wrappedValue) {
                        // Tables, logos and rounded corners can't go through the rich-text editor unchanged,
                        // so show it exactly as recipients will see it instead.
                        EmailWebView(html: binding.wrappedValue, dark: scheme == .dark).frame(minHeight: 100).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("This signature has a designed layout (table, logo or rounded corners). It's kept exactly as is. Edit it in HTML, or paste/import a new one.")
                            .font(.scaled(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    } else {
                        RichTextEditor(html: binding)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    }
                    if !binding.wrappedValue.isEmpty && !isComplexHTML(binding.wrappedValue) {
                        // Live: how the signature lands under a real message, as recipients see it.
                        Text("In an email").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.secondary)
                        EmailWebView(html: "<p>Hi Maya,</p><p>Sounds good, talk Thursday.</p><br>" + binding.wrappedValue, padding: "10px 14px", dark: scheme == .dark)
                            .frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if let note { Text(note).font(.scaled(.callout)).foregroundStyle(.orange) }
                    Text("Type with formatting (⌘B, ⌘I, ⌘K for links), paste a signature from Mail or Gmail (⌘V or Paste signature), or import an .html file. Logos embedded in the signature are sent as inline images so Gmail and Outlook show them.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            } else {
                Text("Select an address").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let f = store.signatureFocus { selection = f; store.signatureFocus = nil }
            else if selection == nil { selection = store.fromAddresses.first }
        }
    }
}

/// A rich-text box whose value is HTML. Pasted formatting (bold, links, colors, fonts) is kept.
struct RichTextEditor: NSViewRepresentable {
    @Binding var html: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = SignatureTextView()
        if #available(macOS 15.1, *), !UserDefaults.standard.bool(forKey: "writingToolsButton") { tv.writingToolsBehavior = .none }
        tv.minSize = .zero; tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        tv.onPasteHTML = { html in context.coordinator.parent.html = extractBodyHTML(html) }
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false   // pasted images can't travel inside a signature; use an <img> link in HTML mode
        tv.usesFontPanel = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.font = .systemFont(ofSize: 14 * Font.scale)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.delegate = context.coordinator
        context.coordinator.load(html, into: tv)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        if html != context.coordinator.lastHTML { context.coordinator.load(html, into: tv) } // switched address or edited as HTML
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastHTML = ""
        init(_ p: RichTextEditor) { parent = p }

        func load(_ html: String, into tv: NSTextView) {
            lastHTML = html
            let source = signatureParts(html).html ?? plainToHTML(html)
            let attr = source.isEmpty ? NSAttributedString()
                : (try? NSAttributedString(data: Data(source.utf8),
                                           options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                           documentAttributes: nil)) ?? NSAttributedString(string: html)
            tv.textStorage?.setAttributedString(SignatureColors.forScreen(attr))
            tv.typingAttributes[.foregroundColor] = NSColor.textColor
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView, let storage = tv.textStorage else { return }
            let html = storage.length == 0 ? "" : Self.bodyHTML(SignatureColors.forSending(storage))
            lastHTML = html
            parent.html = html
        }

        /// AppKit writes a full HTML document; keep just the body plus its inline styles.
        static func bodyHTML(_ s: NSAttributedString) -> String {
            guard let data = try? s.data(from: NSRange(location: 0, length: s.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                              .excludedElements: ["xml", "doctype", "html", "head", "body", "meta", "title"]]),
                  var out = String(data: data, encoding: .utf8) else { return s.string }
            // AppKit puts styles in a <style> block with class names; email clients strip <style>, so inline them.
            if let styleRange = out.range(of: "<style[^>]*>([\\s\\S]*?)</style>", options: .regularExpression) {
                let css = String(out[styleRange])
                out.removeSubrange(styleRange)
                let re = try! NSRegularExpression(pattern: "([a-z]+)\\.([a-z0-9]+)\\s*\\{([^}]*)\\}")
                let ns = css as NSString
                for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
                    let tag = ns.substring(with: m.range(at: 1)), cls = ns.substring(with: m.range(at: 2))
                    let style = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    out = out.replacingOccurrences(of: "<\(tag) class=\"\(cls)\"", with: "<\(tag) style=\"\(style)\"")
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// HTML's default text colour is black, which disappears on a dark editor. On screen, black (or unset) text uses
/// the system text colour so it follows light/dark mode; when saved it goes back to black, so recipients never get
/// white text. Any colour the signature chose on purpose (a red name, a grey title) is left alone both ways.
enum SignatureColors {
    static func forScreen(_ s: NSAttributedString) -> NSAttributedString { remap(s) { c in c == nil || isBlack(c!) ? .textColor : nil } }
    static func forSending(_ s: NSAttributedString) -> NSAttributedString { remap(s) { c in c == .textColor ? .black : nil } }
    static func isBlack(_ c: NSColor) -> Bool {
        guard let rgb = c.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent < 0.08 && rgb.greenComponent < 0.08 && rgb.blueComponent < 0.08
    }
    private static func remap(_ s: NSAttributedString, _ f: (NSColor?) -> NSColor?) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        out.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: out.length)) { v, r, _ in
            if let c = f(v as? NSColor) { out.addAttribute(.foregroundColor, value: c, range: r) }
        }
        return out
    }
}

/// Reads a formatted signature from the clipboard as HTML, preferring the source's own HTML over a converted copy.
enum SignaturePasteboard {
    static func html(_ pb: NSPasteboard = .general) -> String? {
        if let s = pb.string(forType: .html), !s.isEmpty { return s }
        // Mail and Safari copy as a web archive: the original HTML is inside.
        if let d = pb.data(forType: NSPasteboard.PasteboardType("com.apple.webarchive")),
           let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let main = plist["WebMainResource"] as? [String: Any], let data = main["WebResourceData"] as? Data,
           let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return s
        }
        return nil
    }
}

/// Pasting formatted content stores its HTML as-is instead of flattening it through rich text.
final class SignatureTextView: NSTextView {
    var onPasteHTML: ((String) -> Void)?
    override func paste(_ sender: Any?) {
        if let html = SignaturePasteboard.html(), isComplexHTML(html) || html.contains("<") { onPasteHTML?(html); return }
        super.paste(sender)
    }
}

/// The signature as recipients will see it, below what you type. Not editable here, so it can't be deleted by accident.
struct ComposeSignature: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: ComposeModel
    var body: some View {
        if let plain = model.draft.signaturePlain {
            HStack(alignment: .top, spacing: 8) {
                if let html = model.draft.signatureHTML {
                    EmailWebView(html: html, padding: "10px 14px", dark: scheme == .dark).frame(maxWidth: 520).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(plain).font(.scaled(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { store.applySignature(&model.draft, from: nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove signature (put it back from the Signature menu)")
            }
        }
    }
}

/// Wraps children onto new lines, for recipient chips.
