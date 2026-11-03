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
        var all = found.map { p in
            var p = p
            let e = packageEdit(p)
            if let e { p.apply(e) }
            if let f = packageFinding(p) { p.apply(f, edit: e) }
            return p
        }
        for (id, added) in state.packagesAdded.sorted(by: { $0.value < $1.value }) {
            var m = Package.manual(id: id, added: added)
            if let e = state.packageEdits[id] { m.apply(e) }
            if let f = state.packageFindings[id] { m.apply(f, edit: state.packageEdits[id]) }
            // Its shipping email has arrived: one package, and your name for it stays.
            if let t = m.tracking, let i = all.firstIndex(where: { $0.tracking == t }) {
                if let n = m.item { all[i].item = n }
                continue
            }
            all.append(m)
        }
        return all.map { p in
            var p = p
            if let t = p.tracking, let l = state.packageLive[t] {
                p.apply(l)
                if let e = packageEdit(p) { p.applyDate(e) }
            }
            if state.packagesReceived[p.id] != nil { p.stage = .delivered }
            return p
        }
    }

    func packageEdit(_ p: Package) -> PackageEdit? { p.editKeys.lazy.compactMap { self.state.packageEdits[$0] }.first }
    func packageFinding(_ p: Package) -> PackageFinding? { p.editKeys.lazy.compactMap { self.state.packageFindings[$0] }.first }

    /// When it arrived: your "received" mark, else the delivered email, else when you set it to Delivered.
    func deliveredDate(_ p: Package) -> Date? {
        state.packagesReceived[p.id] ?? p.events.last { $0.stage == .delivered }?.date ?? packageEdit(p).flatMap { $0.stage == .delivered ? $0.edited : nil }
    }

    /// Delivered, or so long past due that it surely was (see probablyDelivered).
    func arrived(_ p: Package) -> Bool { p.stage == .delivered || p.probablyDelivered() }

    /// What the screen lists. Delivered ones stay 14 days; one with no news for 30 days has almost certainly
    /// arrived without a "delivered" email, so it drops off too.
    var packageSections: [PackageSection] {
        let now = Date(), cal = Calendar.current
        let all = allPackages
        let active = all.filter { !arrived($0) && $0.isRecent(now: now) }
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
    var packagesOnTheWay: Int { allPackages.filter { !arrived($0) && $0.isRecent() }.count }

    // MARK: Live status from your tracking server (karrio)

    static let trackingKeyAccount = "karrio-api-key"   // the API key, in the Keychain

    /// Settings → Packages. https only: the server sits behind Tailscale's HTTPS address.
    var trackingServer: URL? {
        guard let s = UserDefaults.standard.string(forKey: "trackingServer")?.trimmingCharacters(in: .whitespaces),
              let u = URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s), u.scheme == "https", u.host != nil else { return nil }
        return u
    }

    func trackingRequest(_ path: String) -> URLRequest? {
        guard let base = trackingServer, let key = Keychain.get(Self.trackingKeyAccount), !key.isEmpty,
              let url = URL(string: base.absoluteString + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// Asks your tracking server about packages on the way. Each package at most every 30 minutes (force: now),
    /// 20 per run. Off until Settings → Packages has a server and key; only the carrier and tracking number are sent.
    func refreshLiveTracking(force: Bool = false) async {
        guard !liveChecking, trackingRequest("/") != nil else { return }
        liveChecking = true; defer { liveChecking = false }
        let soon = Date().addingTimeInterval(-30 * 60)
        let todo = allPackages.filter { p in
            guard let t = p.tracking, let c = p.carrier, c.karrioName != nil, p.isRecent(),
                  state.packagesReceived[p.id] == nil else { return false }
            if let l = state.packageLive[t] { return !l.delivered && (force || l.checked < soon) }
            return p.events.last?.stage != .delivered
        }.prefix(20)
        var got: [String: LiveTracking] = [:], note: String?
        for p in todo {
            guard let t = p.tracking, let c = p.carrier, let path = karrioTrackingPath(c, t), let req = trackingRequest(path) else { continue }
            do {
                let (data, resp) = try await liveFetch(req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 { note = "The tracking server didn't accept the API key."; break }
                if code == 200, let l = parseKarrioTracking(data) { got[t] = l }
                else if code != 200 { note = "The tracking server answered \(code) for a \(c.name) package. Is \(c.name) connected in karrio?" }
            } catch {
                note = "Couldn't reach the tracking server. Keymail tries again on the next sync."; break
            }
        }
        if !got.isEmpty { state.packageLive.merge(got) { $1 } }
        trackingServerNote = note ?? (todo.isEmpty ? trackingServerNote : "Checked \(got.count) package\(got.count == 1 ? "" : "s") at \(Date().formatted(date: .omitted, time: .shortened)).")
    }

    /// Settings → Packages → Test: lists the carriers connected in karrio. Outside Tailscale only tracking is
    /// reachable, so a 404 there still means the server and key work.
    func testTrackingServer() async -> String {
        guard trackingServer != nil else { return "Enter the server's https address." }
        guard let req = trackingRequest("/v1/connections") else { return "Paste the API key from karrio (Settings → API keys)." }
        do {
            let (data, resp) = try await liveFetch(req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"] as? [[String: Any]] ?? []
                let names = Set(rows.compactMap { $0["carrier_name"] as? String })
                let ours = Carrier.allCases.filter { $0.karrioName.map(names.contains) == true }.map(\.name)
                return ours.isEmpty ? "Connected, but no UPS, FedEx, USPS or DHL account is set up in karrio yet."
                                    : "Connected. Live status for \(ours.joined(separator: ", "))."
            case 401, 403: return "The server didn't accept that API key."
            case 404: return "Reached the server. (Away from Tailscale only tracking is open, so carriers can't be listed.)"
            case let c: return "The server answered \(c)."
            }
        } catch { return "Couldn't reach \(trackingServer?.host ?? "the server"): \(error.localizedDescription)" }
    }

    /// R, ⌘R and the header button: fetches mail, then asks your tracking server about everything on the way, now.
    func refreshPackages() async {
        guard !packagesRefreshing else { return }
        packagesRefreshing = true; defer { packagesRefreshing = false }
        if !AppFlavor.isTesting { await tick() }
        var said: [String] = []
        if trackingRequest("/") != nil {
            while liveChecking { try? await Task.sleep(for: .milliseconds(100)) }   // the sync's own check
            trackingServerNote = nil
            await refreshLiveTracking(force: true)
            said.append(trackingServerNote ?? "No packages to ask the carrier about.")
        }
        if let read = await readPackageEmails() { said.append(read) }
        banner = said.isEmpty ? "Checked your email." : said.joined(separator: " ")
    }

    // MARK: AI reading shipping emails (Refresh only)

    static let packageAIKey = "packageAI"

    /// Asks the first time there's something to read; Settings → Packages changes it later.
    func packageAIAllowed() -> Bool {
        let d = UserDefaults.standard
        if let on = d.object(forKey: Self.packageAIKey) as? Bool { return on && (d.bool(forKey: "aiConsent." + ai.id) || aiConsent(ai)) }
        guard !AppFlavor.isTesting else { return false }
        let alert = NSAlert()
        alert.messageText = "Read shipping emails with \(ai.name)?"
        alert.informativeText = "When you refresh Packages, Keymail can send new emails about packages on the way to \(ai.name) on this Mac, which sends them to \(ai.maker) under your own account and their privacy terms. It uses your plan, and only happens when you refresh. Other emails aren't sent.\n\nYou can change this in Settings → Packages."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not now")
        let yes = alert.runModal() == .alertFirstButtonReturn
        d.set(yes, forKey: Self.packageAIKey)
        if yes { d.set(true, forKey: "aiConsent." + ai.id) }
        return yes
    }

    /// New emails about packages on the way, newest first: their own shipping emails, plus any email that names their
    /// tracking number, or their order number from the same store ("delivery attempted" reads as nothing to the parser).
    /// ponytail: 10 packages, 5 emails each, 20 in all per refresh; the next refresh takes the rest.
    func packageEmailsToRead(now: Date = Date()) -> [(package: Package, emails: [Message])] {
        let packages = allPackages.filter { !arrived($0) && $0.isRecent(now: now) }.prefix(10)
        let pool = messages.values.filter { m in
            m.date > now.addingTimeInterval(-30 * 86400) && !state.packageAIRead.contains(m.key) && !m.labelIds.contains("SPAM")
                && !m.labelIds.contains("SENT") && !m.labelIds.contains("DRAFT") && m.authFailed != true
                && (state.activeAccount == nil || m.account == state.activeAccount)
        }
        var left = 20
        return packages.compactMap { p in
            let own = Set(p.events.map(\.messageKey)), domains = Set(p.events.map(\.domain))
            let order = p.order.flatMap { $0.count >= 6 ? $0 : nil }
            let track = p.tracking.flatMap { $0.count >= 8 ? $0 : nil }
            let found = pool.filter { m in
                if own.contains(m.key) { return true }
                let sender = parseAddresses(m.from).first.flatMap { logoDomain(for: $0.email) }
                guard track != nil || (order != nil && (p.isManual || sender.map(domains.contains) == true)) else { return false }
                let text = m.subject + "\n" + m.plainText.prefix(20_000)
                return track.map(text.contains) == true || (order.map(text.contains) == true && (p.isManual || sender.map(domains.contains) == true))
            }
            let emails = Array(found.sorted { $0.date > $1.date }.prefix(min(5, left)))
            left -= emails.count
            return emails.isEmpty ? nil : (p, emails)
        }
    }

    /// What to say about it, or nil when there was nothing to read or it isn't allowed.
    func readPackageEmails() async -> String? {
        let work = packageEmailsToRead()
        let count = work.reduce(0) { $0 + $1.emails.count }, noun = "shipping email\(count == 1 ? "" : "s")", name = ai.name
        guard count > 0, packageAIAllowed() else { return nil }
        banner = "\(name) is reading \(count) \(noun)."
        let before = Dictionary(allPackages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prompt = packageAIPrompt(work, today: Date())
        let out: String
        do {
            if let run = packageAIRun { out = try await run(prompt) } else { out = try await AI.run(prompt, with: ai, model: state.aiModels[ai.id]) }
        } catch { return "\(name) couldn't read your \(noun): \(error.localizedDescription)" }   // not marked read: the next refresh tries again
        var found = parsePackageFindings(out, work: work)
        guard !found.isEmpty else { return "\(name) gave an answer Keymail couldn't use. Try refreshing again." }
        var s = state
        for w in work {
            guard var f = found[w.package.id] else { continue }
            // A number another package already has would make two rows for one box.
            if let t = f.tracking, before.values.contains(where: { $0.id != w.package.id && $0.tracking == t }) { f.tracking = nil; found[w.package.id] = f }
            let keys = w.package.editKeys, old = keys.lazy.compactMap { s.packageFindings[$0] }.first
            for k in keys { s.packageFindings[k] = nil }
            s.packageFindings[w.package.id] = old?.updated(by: f) ?? f
            s.packageAIRead.formUnion(w.emails.map(\.key))
        }
        state = s
        let changed = allPackages.filter { p in
            guard var a = before[p.id] else { return false }
            var b = p; a.aiRead = nil; b.aiRead = nil
            return a != b
        }.count
        return changed == 0 ? "\(name) read \(count) \(noun). Nothing new." : "\(name) updated \(changed) package\(changed == 1 ? "" : "s") from \(count) \(noun)."
    }

    // MARK: Actions

    func newPackage() { packageForm = .new() }
    func editPackage(_ p: Package) { packageForm = PackageForm(p) }

    func savePackage(_ f: PackageForm) {
        guard f.canSave else { return }
        let id = f.id ?? "manual-\(UUID().uuidString)", cur = f.id.flatMap { i in allPackages.first { $0.id == i } }
        var s = state
        if f.id == nil { s.packagesAdded[id] = Date() }
        let e = f.edit(from: cur.map(PackageForm.init) ?? PackageForm(), over: cur.flatMap(packageEdit))
        for k in cur?.editKeys ?? [] { s.packageEdits[k] = nil }
        s.packageEdits[id] = e
        if f.stage < .delivered { s.packagesReceived[id] = nil }
        state = s
        packageForm = nil
        if !shownPackages.contains(where: { $0.id == id }) { packageFilter = .all }
        packageIndex = shownPackages.firstIndex { $0.id == id } ?? 0
        banner = f.id == nil ? "Added the package." : "Saved your changes."
        Task { await refreshLiveTracking() }
    }

    /// Back to what the emails say.
    func undoPackageEdits(_ p: Package) {
        var s = state
        for k in p.editKeys { s.packageEdits[k] = nil }
        state = s
        packageForm = nil
        banner = "Back to what the emails say."
    }

    func deletePackage(_ id: String) {
        var s = state
        s.packagesAdded[id] = nil; s.packageEdits[id] = nil; s.packagesReceived[id] = nil
        state = s
        packageForm = nil
        packageIndex = min(packageIndex, max(shownPackages.count - 1, 0))
        banner = "Deleted the package."
    }

    func openPackageEmail(_ p: Package) {
        if p.isManual { editPackage(p); return }   // you added it: there's no email, and ↵ shouldn't dead-end
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

    /// The keyboard on Packages. J/K move, ↵ opens the email, T tracks, C copies, E marks received, Tab switches tabs,
    /// I edits, N adds, R refreshes.
    func handlePackagesKey(code: UInt16, ch: String) -> Bool {
        let list = shownPackages, p = currentPackage
        switch (code, ch) {
        case (125, _), (_, "j"): packageIndex = min(packageIndex + 1, max(list.count - 1, 0))
        case (126, _), (_, "k"): packageIndex = max(packageIndex - 1, 0)
        case (36, _), (_, "o"): if let p { openPackageEmail(p) }
        case (_, "t"): if let p { trackPackage(p) }
        case (_, "c"): if let p { copyTracking(p) }
        case (_, "e"): if let p { toggleReceived(p) }
        case (_, "i"): if let p { editPackage(p) }
        case (_, "n"): newPackage()
        case (_, "r"): Task { await refreshPackages() }
        case (48, _):
            let all = PackageFilter.allCases
            packageFilter = all[((all.firstIndex(of: packageFilter) ?? 0) + 1) % all.count]; packageIndex = 0
        default: return false
        }
        return true
    }
}
