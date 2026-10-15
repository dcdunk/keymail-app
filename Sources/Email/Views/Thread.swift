import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Thread

struct ThreadView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.layout) private var layout
    let conversation: Conversation
    @State private var expanded: Set<String> = []
    @AppStorage("threadNewestFirst") private var newestFirst = false
    @AppStorage("emailButtons") private var emailButtons = "text"   // "icons" or "text"
    @AppStorage("emailContentTheme") private var contentTheme = "auto"
    @Environment(\.colorScheme) private var scheme
    var contentDark: Bool { contentTheme == "dark" || (contentTheme == "auto" && scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.latest.subject).font(.scaled(size: 22, weight: .semibold)).textSelection(.enabled).lineLimit(2)
                Spacer()
                if conversation.messages.count > 1 {
                    Button { newestFirst.toggle() } label: {
                        Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down").font(.scaled(.callout)).padding(.horizontal, 6)
                    }.buttonBorderShape(.capsule).help("Change the order of messages in this thread")
                }
                // Shows the email's current look; click to flip it (saved, same as Settings → Email content).
                Button { contentTheme = contentDark ? "light" : "dark" } label: {
                    Image(systemName: contentDark ? "moon.fill" : "sun.max.fill").font(.scaled(.callout)).frame(width: 18).padding(.horizontal, 2)
                }
                .buttonBorderShape(.capsule)
                .help(contentDark ? "Emails are dark. Click for light." : "Emails are light. Click for dark.")
                Button { store.threadOpen = false } label: {
                    Label("Back", systemImage: "chevron.left").font(.scaled(.callout)).padding(.horizontal, 6)
                }.buttonBorderShape(.capsule).help("Back to the list (Esc)")
            }
            .padding(.horizontal, layout.compact ? 16 : 40).padding(.top, 4).padding(.bottom, 10)
            InstantReplyBar(conversation: conversation)
            UnsubscribeBar(conversation: conversation)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let older = Array(conversation.messages.dropLast())
                    if newestFirst { MessageCard(message: conversation.latest, collapsible: false) {} }
                    ForEach(newestFirst ? older.reversed() : older) { m in
                        if expanded.contains(m.key) { MessageCard(message: m, collapsible: true) { expanded.remove(m.key) } }
                        else { CollapsedMessage(message: m) { expanded.insert(m.key) } }
                    }
                    if !newestFirst { MessageCard(message: conversation.latest, collapsible: false) {} }
                }
                .frame(maxWidth: 960)               // emails stay readable on big monitors
                .frame(maxWidth: .infinity)
                .padding(.horizontal, layout.compact ? 16 : 40).padding(.top, 6).padding(.bottom, 60)
            }
            HStack(spacing: 4) {
                let actions: [(String, String, String, () -> Void)] = [
                    (Hotkeys.label("r"), "Reply", "arrowshape.turn.up.left", { store.reply(all: false) }),
                    (Hotkeys.label("a"), "Reply all", "arrowshape.turn.up.left.2", { store.reply(all: true) }),
                    (Hotkeys.label("f"), "Forward", "arrowshape.turn.up.right", { store.forward() }),
                    (Hotkeys.label("e"), "Done", "checkmark", { store.markDone() }),
                    (Hotkeys.label("h"), "Remind", "clock", { store.openPalette("remind") }),
                    (Hotkeys.label("b"), "Event", "calendar.badge.plus", { store.createEventFromEmail() }),
                    (Hotkeys.label("i"), "Summarize", "text.append", { store.summarize() }),
                    ("", "Claude Code", "brand:claude", { store.sendToClaudeCode() }),
                    ("⌫", "Delete", "trash", { store.trash() }),
                ]
                ForEach(actions, id: \.1) { k, l, icon, run in
                    Button(action: run) {
                        HStack(spacing: 6) {
                            if icon.hasPrefix("brand:") { BrandLogo(brand: String(icon.dropFirst(6)), size: 15) }
                            else { Image(systemName: icon).accessibilityLabel(l) }
                            if !layout.compact {
                                if emailButtons == "text" { Text(l) }
                                if !k.isEmpty { KeyHint(k) }
                            }
                        }.font(.scaled(.callout)).padding(.horizontal, 8).frame(height: 28)
                    }.buttonStyle(ToolStyle()).help(k.isEmpty ? l : "\(l) (\(k))")
                }
                Spacer()
                Button { store.move(-1) } label: { Image(systemName: "chevron.up").frame(width: 28, height: 28) }.buttonStyle(ToolStyle()).help("Previous (\(Hotkeys.label("k")))")
                Button { store.move(1) } label: { Image(systemName: "chevron.down").frame(width: 28, height: 28) }.buttonStyle(ToolStyle()).help("Next (\(Hotkeys.label("j")))")
            }
            .font(.scaled(.callout)).foregroundStyle(.secondary)
            .padding(.horizontal, layout.compact ? 16 : 40).padding(.vertical, 12)
        }
        .id(conversation.id) // fresh expand state per thread
    }
}

/// One line per older message: who, when, and a preview. Click to expand.
struct CollapsedMessage: View {
    let message: Message
    let expand: () -> Void
    var body: some View {
        Button(action: expand) {
            HStack(spacing: 10) {
                Avatar(address: parseAddresses(message.from).first, size: 26)
                Text(parseAddresses(message.from).first?.display ?? message.from).fontWeight(.medium).lineLimit(1)
                Text(message.snippet).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(shortDate(message.date)).font(.scaled(.callout)).foregroundStyle(.secondary)
            }
            .font(.scaled(size: 14))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The sender's company logo when their site has one (see SenderLogos), otherwise their initial.
struct Avatar: View {
    let address: Address?
    var size: CGFloat = 34
    @ObservedObject private var logos = SenderLogos.shared
    var body: some View {
        let key = address?.email ?? "?"
        let domain = logoDomain(for: key)
        Group {
            if let logo = logos.images[SenderLogos.personKey(key)] ?? domain.flatMap({ logos.images[SenderLogos.key($0, senderName: address?.name)] }) {
                Group {
                    // The circle takes the icon's own background color (white for bare marks), with the mark centered on it.
                    if logo.photo {   // a profile photo fills the circle
                        Image(nsImage: logo.image).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Circle().fill(Color(nsColor: logo.background ?? .white))
                            .overlay(Image(nsImage: logo.image).resizable().interpolation(.high).scaledToFit()
                                .padding(size * (logo.background == nil ? 0.18 : 0.08)))
                    }
                }
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            } else {
                Circle().fill(Theme.chip(key).opacity(0.2)).frame(width: size, height: size)
                    .overlay(Text(String((address?.display ?? "?").prefix(1)).uppercased())
                        .font(.scaled(size: size * 0.42, weight: .semibold)).foregroundStyle(Theme.chip(key)))
            }
        }
        .task(id: key) { logos.loadPhoto(key); if let domain { await logos.load(domain, senderName: address?.name) } }
    }
}

/// Native header + the email body in its own isolated web view + native attachment buttons.
struct MessageCard: View {
    @EnvironmentObject var store: AppStore
    let message: Message
    let collapsible: Bool
    let collapse: () -> Void
    @State private var showQuoted = false
    @State private var loadImagesOnce = false   // "Load images" for just this message
    @AppStorage("loadRemoteImages") private var loadRemoteImages = false
    @AppStorage("cardOpacity") private var cardOpacity = 1.0
    @AppStorage("emailContentTheme") private var contentTheme = "auto"   // auto (match app), light, dark
    @Environment(\.colorScheme) private var scheme
    var contentDark: Bool { contentTheme == "dark" || (contentTheme == "auto" && scheme == .dark) }

    var body: some View {
        let from = parseAddresses(message.from).first
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(address: from)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(from?.display ?? message.from).font(.scaled(size: 15, weight: .semibold))
                        if let e = from?.email, from?.name.isEmpty == false { Text(e).font(.scaled(.callout)).foregroundStyle(.secondary) }
                    }
                    Text(recipients).font(.scaled(.callout)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if message.labelIds.contains("DRAFT") && !message.labelIds.contains("SENT") {
                    // Your unsent reply in this conversation: marked clearly, one click to keep writing.
                    Text("Draft").font(.scaled(.caption).weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.orange.opacity(0.14)))
                    Button {
                        if let c = store.allConversations.first(where: { $0.account == message.account && $0.threadId == message.threadId }) {
                            store.openDraft(c, message: message)
                        }
                    } label: { Label("Continue editing", systemImage: "pencil") }
                        .controlSize(.small).buttonBorderShape(.capsule).help("Open this draft in compose")
                }
                PhishingPill(senderReasons: senderWarnings(message, known: store.knownContacts),
                             links: message.html.map(suspiciousLinks) ?? [])
                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.scaled(.callout)).foregroundStyle(.secondary)
                if collapsible {
                    Button(action: collapse) { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            // Clicking the header of an expanded older message collapses it again.
            .contentShape(Rectangle())
            .onTapGesture { if collapsible { collapse() } }
            .help(collapsible ? "Click to collapse" : "")
            if message.calendar != nil || message.attachments.contains(where: { $0.mimeType == "text/calendar" || $0.name.lowercased().hasSuffix(".ics") }) {
                InviteCard(message: message)
            }
            bodyView
            let files = message.attachments.filter { !$0.isInline }
            let photos = files.filter { $0.mimeType.hasPrefix("image/") }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos, id: \.id) { a in
                            let img = store.thumbnails[message.key + "|" + a.id]
                            Button { store.preview(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                Group {
                                    if let img, img.size.width > 0 { Image(nsImage: img).resizable().scaledToFill() }
                                    else { ZStack { Color.primary.opacity(0.06); ProgressView().controlSize(.small) } }
                                }
                                .frame(width: 160, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain).handCursor().help(a.name)
                            .onAppear { store.loadThumbnail(message, a) }
                        }
                    }
                }
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files, id: \.id) { a in
                            HStack(spacing: 2) {
                                Button { store.preview(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                    Label {
                                        Text(a.name).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).foregroundStyle(.secondary)
                                    } icon: { Image(systemName: icon(a.mimeType)) }
                                    .font(.scaled(.callout))
                                }.buttonStyle(.plain).handCursor().help("Click to preview")
                                Divider().frame(height: 16).padding(.horizontal, 6)
                                Button { store.preview(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                    Image(systemName: "eye")
                                }.buttonStyle(.plain).handCursor().help("Preview")
                                Button { store.download(account: message.account, messageId: message.id, attachmentId: a.id, name: a.name) } label: {
                                    Image(systemName: "arrow.down.circle")
                                }.buttonStyle(.plain).handCursor().padding(.leading, 6).help("Download to your Downloads folder")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
    }

    var recipients: String {
        let to = parseAddresses(message.to).map { store.me.contains($0.email.lowercased()) ? "me" : $0.display }.joined(separator: ", ")
        let cc = parseAddresses(message.cc).map(\.display).joined(separator: ", ")
        return "to \(to.isEmpty ? "undisclosed recipients" : to)" + (cc.isEmpty ? "" : " · cc \(cc)")
    }

    @ViewBuilder var bodyView: some View {
        if let html = message.html {
            if !loadRemoteImages && !loadImagesOnce && hasRemoteContent(html) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    Text("Remote images are blocked to protect your privacy.").font(.scaled(.callout)).foregroundStyle(.secondary)
                    Button("Load images") { loadImagesOnce = true }.quiet()
                }
            }
            // HTML emails are designed for a light page, so they sit on a white "paper" card, like Apple Mail does.
            EmailWebView(html: inlineImages(html, store.inlineData[message.key] ?? [:]), cardOpacity: cardOpacity,
                         dark: contentDark, blockRemote: !loadRemoteImages && !loadImagesOnce,
                         suspicious: Dictionary(suspiciousLinks(html).map { ($0.href, $0.reason) }, uniquingKeysWith: { a, _ in a }))
                .id(loadImagesOnce) // the blocker is set when the web view is made, so a new one loads the images
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            let parts = splitQuoted(message.text ?? message.snippet)
            VStack(alignment: .leading, spacing: 8) {
                // Match app: plain text sits on the card in app colors. Forced light/dark: it gets the same "paper" as HTML emails.
                EmailWebView(html: plainToHTML(parts.body), dark: contentDark, themed: contentTheme == "auto")
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let q = parts.quoted {
                    Button { showQuoted.toggle() } label: {
                        Text("•••").font(.scaled(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }.buttonStyle(.plain).handCursor().help(showQuoted ? "Hide quoted text" : "Show quoted text")
                    if showQuoted { EmailWebView(html: plainToHTML(q), dark: contentDark, themed: contentTheme == "auto").opacity(0.7) }
                }
            }
        }
    }

    func icon(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime.contains("csv") { return "tablecells" }
        if mime.contains("zip") { return "doc.zipper" }
        if mime == "text/calendar" { return "calendar" }
        return "paperclip"
    }
}

/// One email's HTML in its own web view: its CSS can't leak into the app, JavaScript is off,
/// it sizes itself to the content, and scrolling passes through to the thread.
struct EmailWebView: NSViewRepresentable {
    let html: String
    var padding = "16px 20px"
    var cardOpacity = 1.0   // < 1 lets the window glass show through the email's background
    var dark = false        // HTML emails: invert colors (keeping photos as-is) to read on dark mode
    var themed = false      // plain-text emails: app font and light/dark colors, transparent background
    var blockRemote = true   // plain-text bodies have no remote content either way
    var suspicious: [String: String] = [:]   // href → why it looks like phishing; clicking asks first
    @State private var height: CGFloat = 120
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PassThroughWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent() // no cookies or storage shared between emails
        if blockRemote, let blocker = RemoteContent.blocker {
            config.userContentController.add(blocker)
        }
        config.userContentController.addUserScript(WKUserScript(source: Coordinator.darkScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let v = PassThroughWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.pageZoom = Font.scale
        v.uiDelegate = context.coordinator
        if !themed { v.appearance = NSAppearance(named: .aqua) } // HTML emails render as their senders designed them (light)
        v.setValue(false, forKey: "drawsBackground") // the page's own background (below) decides how see-through it is
        context.coordinator.onHeight = { h in if abs(h - height) > 1 { height = h } }
        return v
    }
    func updateNSView(_ v: PassThroughWebView, context: Context) {
        context.coordinator.suspicious = suspicious
        let page = themed ? Self.wrapThemed(html) : Self.wrap(html, padding: padding, opacity: cardOpacity, dark: dark)
        // Emails that ship their own dark design only show it when the page is in dark appearance.
        if !themed { v.appearance = NSAppearance(named: dark && emailHasOwnDarkMode(html) ? .darkAqua : .aqua) }
        guard context.coordinator.last != page else { return }
        context.coordinator.last = page
        v.loadHTMLString(page, baseURL: nil)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassThroughWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }

    /// Minimal reset only; never override the sender's layout (forcing image heights broke sprites and banners).
    static func wrap(_ html: String, padding: String = "16px 20px", opacity: Double = 1, dark: Bool = false) -> String {
        // Dark: an email with its own dark design gets it (the web view runs in dark appearance); then darkScript
        // recolors whatever is still light, element by element (images untouched).
        // Many senders' dark designs only cover part of the email (Apple's darkens the header and footer, not the body),
        // so darkScript still runs and darkens whatever stayed light. It skips anything already dark.
        let native = dark && emailHasOwnDarkMode(html)
        let recolor = dark
        let darkCSS = (recolor ? "img.lm-plate { background-color: #fff; border-radius: 3px; }" : "") + (native ? " :root { color-scheme: light dark; }" : "")
        let bg = dark ? "30,30,32" : "255,255,255"
        return """
        <!doctype html><html\(recolor ? " class=\"lm-dark\"" : "")><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>
        html, body { margin: 0; padding: 0; background: rgba(\(bg),\(String(format: "%.2f", opacity))); color: \(dark ? "#e8e8ea" : "#1d1d1f"); }
        \(darkCSS)
        body { padding: \(padding); font: 15px -apple-system, Helvetica, sans-serif; line-height: 1.45; overflow-wrap: anywhere; }
        img { max-width: 100%; }
        /* Many templates set html/body to height:100%, which pins the measured height to the view's starting size
           and cuts the email off. Higher specificity than a sender's own !important rule on plain html/body. */
        html:root, html:root > body { height: auto !important; min-height: 0 !important; max-height: none !important; }
        a, a * { cursor: pointer; }
        table { max-width: 100%; }
        pre { white-space: pre-wrap; }
        </style></head><body>\(html)</body></html>
        """
    }

    /// Plain text styled like the rest of the app, following light/dark mode.
    static func wrapThemed(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; }
        body { font: 15px -apple-system, sans-serif; line-height: 1.55; overflow-wrap: anywhere; }
        a { color: LinkText; cursor: pointer; }
        </style></head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Dark mode: logos with see-through backgrounds (black ink) would vanish on the dark page, so images get a
        /// white backing. Photos cover it completely. Skips tracking pixels and thin spacer images used for layout.
        /// Runs in the app's own script world; the email's scripts stay disabled. The class only has a style in dark mode.
        /// Dark mode rules, applied to every element of the email:
        ///  1. Images are never changed.
        ///  2. Light backgrounds become dark, keeping their hue.
        ///  3. Dark text and borders become light, keeping their hue (links stay blue).
        ///  4. Mid-tone and dark backgrounds (buttons, banners) stay as designed.
        ///  5. Anything drawn on a background image is left alone.
        /// Safe to run more than once: already-dark backgrounds and light text are skipped.
        static let darkScript = """
        (function(){if(!document.documentElement.classList.contains('lm-dark'))return;
        function rgb(c){var m=/rgba?\\(([\\d.]+),\\s*([\\d.]+),\\s*([\\d.]+)(?:,\\s*([\\d.]+))?/.exec(c||'');return m?[+m[1]/255,+m[2]/255,+m[3]/255,m[4]===undefined?1:+m[4]]:null}
        function lum(c){return .299*c[0]+.587*c[1]+.114*c[2]}
        function setL(c,L){var r=c[0],g=c[1],b=c[2],mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn,l=(mx+mn)/2,h=0,s=0;
        if(d){s=l>.5?d/(2-mx-mn):d/(mx+mn);h=mx==r?(g-b)/d+(g<b?6:0):mx==g?(b-r)/d+2:(r-g)/d+4;h/=6}
        function f(t){t=(t%1+1)%1;var q=L<.5?L*(1+s):L+s-L*s,p=2*L-q;return t<1/6?p+(q-p)*6*t:t<.5?q:t<2/3?p+(q-p)*(2/3-t)*6:p}
        return 'rgba('+Math.round(f(h+1/3)*255)+','+Math.round(f(h)*255)+','+Math.round(f(h-1/3)*255)+','+c[3]+')'}
        function dark(c){return setL(c,.12+(1-lum(c))*.5)}
        var media=/^(IMG|PICTURE|VIDEO|SVG|svg|CANVAS)$/;
        function onPicture(el){for(var p=el;p&&p.nodeType===1;p=p.parentElement){if(/url\\(/.test(getComputedStyle(p).backgroundImage))return true}return false}
        /* The colour actually behind an element: its own or the nearest ancestor's (null = a picture). */
        function behind(el){for(var p=el;p&&p.nodeType===1;p=p.parentElement){var cs=getComputedStyle(p),bi=cs.backgroundImage;
        if(bi&&bi!=='none')return /url\\(/.test(bi)?null:rgb(bi);var c=rgb(cs.backgroundColor);if(c&&c[3]>.5)return c}return [30/255,30/255,32/255,1]}
        var all=[].slice.call(document.querySelectorAll('html, body, body *')).filter(function(el){return !media.test(el.tagName)&&!onPicture(el)});
        /* 1. Light backgrounds become dark, keeping their hue, including gradients used as a solid fill (a common way
              senders block dark mode). Borders that would vanish get lighter. Images are never touched. */
        all.forEach(function(el){var cs=getComputedStyle(el),bg=rgb(cs.backgroundColor),bi=cs.backgroundImage;
        if(bg&&bg[3]>0&&lum(bg)>.6){el.style.setProperty('background-color',dark(bg),'important');el.setAttribute('data-lm-bg','1')}
        if(bi&&bi!=='none'&&!/url\\(/.test(bi)){var g=rgb(bi);if(g&&lum(g)>.6){el.style.setProperty('background-image','none','important');el.style.setProperty('background-color',dark(g),'important');el.setAttribute('data-lm-bg','1')}}
        ['top','right','bottom','left'].forEach(function(side){var w=parseFloat(cs['border-'+side+'-width']),bc=rgb(cs['border-'+side+'-color']);
        if(w>0&&bc&&lum(bc)<.35)el.style.setProperty('border-'+side+'-color',setL(bc,.45),'important')})});
        /* 2. Dark text becomes light only where the colour behind it really is dark now, so text can never end up
              light-on-light (or be changed on top of a picture). */
        all.forEach(function(el){var fg=rgb(getComputedStyle(el).color),bg=behind(el);
        if(fg&&bg&&lum(fg)<.6&&lum(bg)<.5)el.style.setProperty('color',setL(fg,.86-lum(fg)*.4),'important')});})();0
        """

        static let plateScript = """
        if(document.documentElement.classList.contains('lm-dark'))document.querySelectorAll('img').forEach(function(i){var w=i.clientWidth,h=i.clientHeight;
        if(!i.complete||!i.naturalWidth||w<=12||h<=12||w/h>=12||h/w>=12)return;
        for(var p=i.parentElement,n=0;p&&n<6;p=p.parentElement,n++){if(getComputedStyle(p).backgroundImage!=='none')return;}
        for(var q=i.parentElement;q&&q!==document.body;q=q.parentElement){var c=getComputedStyle(q).backgroundColor;
        if(c&&c!=='transparent'&&!/rgba\\([^)]*,\\s*0\\)$/.test(c)){if(!q.hasAttribute('data-lm-bg'))return;break}}
        i.classList.add('lm-plate')});0
        """
        var last = ""
        var suspicious: [String: String] = [:]
        var onHeight: (CGFloat) -> Void = { _ in }
        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            // Images keep loading after "finish", so measure a few times as they arrive.
            w.evaluateJavaScript(Self.darkScript)
            for delay in [0.0, 0.4, 1.2, 3.0] { measure(w, after: delay, plates: true) }
        }
        /// "Finish" waits for every image, and one slow tracker or image server can hold it back for good,
        /// leaving the email stuck at its starting height. So measure while the page is still loading too.
        func webView(_ w: WKWebView, didCommit navigation: WKNavigation!) {
            for delay in [0.3, 1.0, 2.5, 5.0, 10.0] { measure(w, after: delay, plates: false) }
        }
        func measure(_ w: WKWebView, after delay: Double, plates: Bool) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak w] in
                if plates { w?.evaluateJavaScript(Self.plateScript) }
                w?.evaluateJavaScript("Math.ceil(Math.max(document.body.getBoundingClientRect().height, document.body.scrollHeight))") { r, _ in
                    if let h = r as? CGFloat { self?.onHeight(h) } else if let h = r as? Double { self?.onHeight(CGFloat(h)) }
                }
            }
        }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only our own initial page load renders inside the view; every click goes through openChecked.
            guard let url = a.request.url, a.navigationType != .other || a.targetFrame == nil else { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            openChecked(url)
        }

        /// Web links open directly unless flagged; flagged links, and anything that isn't http(s) or mailto,
        /// get one confirmation showing where they really go (linkWarning is an allowlist).
        func openChecked(_ url: URL) {
            let reason = suspicious[url.absoluteString] ?? suspicious.first { URL(string: $0.key) == url }?.value
                ?? linkWarning(href: url.absoluteString, shown: "")
            guard let reason else { NSWorkspace.shared.open(url); return }
            Task { @MainActor in AppStore.current?.linkPrompt = LinkPrompt(url: url, reason: reason) }
        }
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = a.request.url { openChecked(url) }
            return nil
        }
    }
}

/// Sends scroll-wheel events to the thread instead of scrolling inside the email,
/// and shows the pointing hand over links (SwiftUI otherwise keeps resetting it to the arrow).
final class PassThroughWebView: WKWebView {
    private var overLink = false
    private var pending = false

    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self && t.userInfo?["links"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["links": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !pending else { return } // one lookup in flight at a time
        let p = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? p.y : bounds.height - p.y
        pending = true
        // Runs in the app's own script world, which works even though the email's scripts are off.
        evaluateJavaScript("(function(){var e=document.elementFromPoint(\(p.x),\(y));return !!(e&&e.closest('a[href]'));})()") { [weak self] r, _ in
            guard let self else { return }
            self.pending = false
            self.overLink = (r as? Bool) ?? false
            (self.overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        (overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        overLink = false
        NSCursor.arrow.set()
    }
}

/// When the sender supports one-click unsubscribe (RFC 8058), say so at the top of the thread.
/// Hidden for senders that failed authentication: unsubscribing would only confirm the address to a spammer.
struct UnsubscribeBar: View {
    @EnvironmentObject var store: AppStore
    let conversation: Conversation
    var body: some View {
        if let m = conversation.messages.last(where: { !$0.listUnsubscribe.isEmpty }), m.authFailed != true,
           case .oneClick = unsubscribeAction(header: m.listUnsubscribe, oneClickPost: m.listUnsubscribePost) {
            let sender = parseAddresses(m.from).first.map { $0.name.isEmpty ? $0.email : $0.name } ?? "this sender"
            HStack(spacing: 10) {
                Image(systemName: "hand.raised").foregroundStyle(Theme.accent)
                Text("You can unsubscribe from \(sender) with one click.").font(.scaled(.callout))
                Spacer()
                Button { store.unsubscribe() } label: {
                    HStack(spacing: 6) { Text("Unsubscribe"); KeyHint("⇧U") }.padding(.horizontal, 4)
                }.buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.18)))
            .padding(.horizontal, 40).padding(.bottom, 8)
        }
    }
}
