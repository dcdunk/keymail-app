import AppKit
import EmailCore

enum PackageFilter: String, CaseIterable { case active = "On the way", delivered = "Delivered", all = "All" }

/// One section of the Packages screen ("Arriving today", "Running late"...).
struct PackageSection: Identifiable { let title: String; let note: String?; let packages: [Package]; var id: String { title } }

extension AppStore {
    /// Every delivery found in the mail on this Mac, for the accounts you're looking at. Packages you marked
    /// received count as delivered. Read once per message: the parse is cached by the message and its labels.
    var allPackages: [Package] {
        let found = packageCache ?? {
            var events: [ShipEvent] = []
            for m in messages.values where state.activeAccount == nil || m.account == state.activeAccount {
                let k = m.key + "|" + m.labelIds.joined(separator: ",")
                if let hit = shipCache[k] { if let e = hit { events.append(e) }; continue }
                let e = shippingEvent(m)
                shipCache[k] = .some(e)
                if let e { events.append(e) }
            }
            let ps = packages(from: events)
            packageCache = ps
            return ps
        }()
        return found.map { p in
            var p = p
            if state.packagesReceived[p.id] != nil { p.stage = .delivered }
            return p
        }
    }

    /// When it arrived: your "received" mark, else the delivered email.
    func deliveredDate(_ p: Package) -> Date? {
        state.packagesReceived[p.id] ?? p.events.last { $0.stage == .delivered }?.date
    }

    /// Delivered, or so long past due that it surely was (see probablyDelivered).
    func arrived(_ p: Package) -> Bool { p.stage == .delivered || p.probablyDelivered() }

    /// What the screen lists. Delivered ones stay 14 days; one with no news for 30 days has almost certainly
    /// arrived without a "delivered" email, so it drops off too.
    var packageSections: [PackageSection] {
        let now = Date(), cal = Calendar.current
        let all = allPackages
        let active = all.filter { !arrived($0) && $0.updated > now.addingTimeInterval(-30 * 86400) }
            .sorted { ($0.eta ?? .distantFuture, $1.updated) < ($1.eta ?? .distantFuture, $0.updated) }
        let when = { (p: Package) in self.deliveredDate(p) ?? p.eta ?? p.updated }
        let delivered = all.filter { arrived($0) && when($0) > now.addingTimeInterval(-14 * 86400) }.sorted { when($0) > when($1) }
        let today = active.filter { $0.arrivesToday(now: now, calendar: cal) }
        let late = active.filter { $0.isLate(now: now, calendar: cal) }
        let rest = active.filter { !$0.arrivesToday(now: now, calendar: cal) && !$0.isLate(now: now, calendar: cal) }
        var s: [PackageSection] = []
        if packageFilter != .delivered {
            s += [PackageSection(title: "Arriving today", note: nil, packages: today), PackageSection(title: "Running late", note: nil, packages: late),
                  PackageSection(title: "On the way", note: nil, packages: rest)]
        }
        if packageFilter != .active { s.append(PackageSection(title: "Delivered", note: "last 14 days", packages: delivered)) }
        return s.filter { !$0.packages.isEmpty }
    }

    var shownPackages: [Package] { packageSections.flatMap(\.packages) }
    var currentPackage: Package? { let l = shownPackages; return l.indices.contains(packageIndex) ? l[packageIndex] : l.first }
    var packagesOnTheWay: Int { allPackages.filter { !arrived($0) && $0.updated > Date().addingTimeInterval(-30 * 86400) }.count }

    // MARK: Actions

    func openPackageEmail(_ p: Package) {
        guard let c = allConversations.first(where: { $0.messages.contains { $0.key == p.latest.messageKey } }) else {
            banner = "That email isn't on this Mac anymore."; return
        }
        closeTool(); open(c)
    }

    /// The carrier's own tracking page (or Amazon's order page), in the browser.
    func trackPackage(_ p: Package) {
        guard let url = p.trackURL else { banner = "No tracking number yet. It shows once \(p.store) emails that it shipped."; return }
        banner = "Opening \(p.carrier?.name ?? p.store) tracking in your browser."
        if !AppFlavor.isTesting { NSWorkspace.shared.open(url) }
    }

    func copyTracking(_ p: Package) {
        guard let t = p.tracking else { banner = "No tracking number yet."; return }
        if !AppFlavor.isTesting { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        banner = "Copied the \(p.carrier.map { $0.name + " " } ?? "")tracking number."
    }

    /// For stores that never send a "delivered" email. Again undoes it.
    func toggleReceived(_ p: Package) {
        if state.packagesReceived[p.id] != nil {
            state.packagesReceived[p.id] = nil; banner = "Moved back to On the way."
        } else {
            state.packagesReceived[p.id] = Date(); banner = "Marked received. Press E again to undo."
        }
    }

    /// The keyboard on Packages. J/K move, ↵ opens the email, T tracks, C copies, E marks received, Tab switches tabs.
    func handlePackagesKey(code: UInt16, ch: String) -> Bool {
        let list = shownPackages, p = currentPackage
        switch (code, ch) {
        case (125, _), (_, "j"): packageIndex = min(packageIndex + 1, max(list.count - 1, 0))
        case (126, _), (_, "k"): packageIndex = max(packageIndex - 1, 0)
        case (36, _), (_, "o"): if let p { openPackageEmail(p) }
        case (_, "t"): if let p { trackPackage(p) }
        case (_, "c"): if let p { copyTracking(p) }
        case (_, "e"): if let p { toggleReceived(p) }
        case (48, _):
            let all = PackageFilter.allCases
            packageFilter = all[((all.firstIndex(of: packageFilter) ?? 0) + 1) % all.count]; packageIndex = 0
        default: return false
        }
        return true
    }
}
