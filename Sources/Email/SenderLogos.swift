import AppKit
import EmailCore

/// Company logos for avatars, fetched straight from the sender's own website (no third-party logo service, so no
/// one else learns who emails you). Cached on disk; a site with no usable icon is retried after a week.
/// Off when "Load remote images" is off, since fetching it tells that site this Mac looked.
@MainActor final class SenderLogos: ObservableObject {
    static let shared = SenderLogos()
    struct Logo { let image: NSImage; let background: NSColor?; var photo = false }   // background: the solid color the icon paints behind its mark
    @Published private(set) var images: [String: Logo] = [:]
    private var tried: Set<String> = []
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppFlavor.isDemo ? "Keymail-Demo-Logos" : "Keymail-Logos")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // no cookies sent or kept
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    /// Logos are stored per company site, not per sending domain: brands sharing a vendor (getredo.com) each get their own.
    static func key(_ domain: String, senderName: String?) -> String { logoSites(for: domain, senderName: senderName).first ?? domain }

    /// Your own accounts' profile photos (Google, Microsoft), shown instead of an initial or logo.
    static func personKey(_ email: String) -> String { "person:" + email.lowercased() }
    func setPhoto(_ email: String, _ data: Data) {
        guard let img = NSImage(data: data) else { return }
        try? data.write(to: dir.appendingPathComponent("person-\(email.lowercased())"))
        images[Self.personKey(email)] = Logo(image: img, background: nil, photo: true)
    }
    func loadPhoto(_ email: String) {
        let key = Self.personKey(email)
        guard images[key] == nil, let img = NSImage(contentsOf: dir.appendingPathComponent("person-\(email.lowercased())")) else { return }
        images[key] = Logo(image: img, background: nil, photo: true)
    }

    func load(_ domain: String, senderName: String? = nil) async {
        let sites = logoSites(for: domain, senderName: senderName), domain = sites.first ?? domain
        guard !tried.contains(domain), UserDefaults.standard.object(forKey: "loadSenderLogos") as? Bool ?? true else { return }
        tried.insert(domain)
        let file = dir.appendingPathComponent(domain + ".png"), none = dir.appendingPathComponent(domain + ".none")
        if let img = NSImage(contentsOf: file) { images[domain] = Logo(image: img, background: Self.background(img)); return }
        if let d = (try? none.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           d > Date().addingTimeInterval(-7 * 86400) { return }
        // Unstructured on purpose: a row scrolling away cancels its .task, which must not cancel (and mark "no logo") the fetch.
        // Mail-only domains (sonarsource.email, stripemail.com) have no site or logo; logoSites lists likely company sites.
        let got = await Task { () -> (NSImage, Data)? in for site in sites { if let r = await self.fetch(site) { return r } }; return nil }.value
        if let (img, data) = got {
            try? data.write(to: file)   // original bytes: an SVG stays sharp (NSImage reads it back whatever the extension)
            images[domain] = Logo(image: img, background: Self.background(img))
        } else {
            FileManager.default.createFile(atPath: none.path, contents: nil)
        }
    }

    /// An icon with solid corners has its own background (Obsidian: black square). The circle is filled with that
    /// color so the square's edges vanish. Transparent corners mean a bare mark: nil, and it goes on a white plate.
    static func background(_ img: NSImage) -> NSColor? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide > 4, rep.pixelsHigh > 4 else { return nil }
        let w = rep.pixelsWide - 1, h = rep.pixelsHigh - 1, inset = max(1, rep.pixelsWide / 16)
        let corners = [(inset, inset), (w - inset, inset), (inset, h - inset), (w - inset, h - inset)].compactMap { rep.colorAt(x: $0.0, y: $0.1) }
        guard corners.count == 4, corners.allSatisfy({ $0.alphaComponent > 0.9 }) else { return nil }
        return corners[0]
    }

    /// apple-touch-icon first (large and square), then what the homepage declares, then favicon.ico.
    private func fetch(_ domain: String) async -> (NSImage, Data)? {
        guard let site = URL(string: "https://\(domain)/") else { return nil }
        var candidates = [URL(string: "apple-touch-icon.png", relativeTo: site)!]
        if let (data, resp) = try? await session.data(from: site), let html = String(data: data.prefix(300_000), encoding: .utf8) {
            let base = resp.url ?? site   // after redirects, e.g. aws.com → aws.amazon.com
            candidates += iconLinks(inHTML: html).compactMap { URL(string: $0, relativeTo: base) }
            candidates.append(URL(string: "/apple-touch-icon.png", relativeTo: base)!)
        }
        candidates.append(URL(string: "favicon.ico", relativeTo: site)!)
        var best: (NSImage, Data)?
        for url in candidates where ["http", "https"].contains(url.scheme ?? "") {
            guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data), let side = img.representations.map({ $0.pixelsWide > 0 ? min($0.pixelsWide, $0.pixelsHigh) : 512 }).max(), side >= 16  // vector (SVG) reps report 0 pixels: they scale to any size
            else { continue }
            if side >= 64 { return (img, data) }
            if best == nil { best = (img, data) }
        }
        return best
    }
}
