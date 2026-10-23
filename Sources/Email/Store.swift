import AppKit
import SwiftUI
import EmailCore
import CryptoKit

/// One row in a Keymail menu. Headers and dividers are rows too, so menus are plain arrays.
struct MenuEntry: Identifiable {
    enum Kind { case item, header, divider }
    let id = UUID()
    var kind: Kind = .item
    var title = ""
    var subtitle: String? = nil
    var icon: String? = nil
    var letter: String? = nil        // shows a colored initial circle instead of an icon; value seeds the color
    var key: String? = nil
    var checked = false
    var destructive = false
    var disabled = false
    var keepsOpen = false
    var submenu: [MenuEntry]? = nil
    var action: () -> Void = {}
    static func header(_ t: String) -> MenuEntry { MenuEntry(kind: .header, title: t) }
    static var divider: MenuEntry { MenuEntry(kind: .divider) }
}

/// An open menu (or small info panel), anchored to a rect in the main window's "main" coordinate space.
struct Popup {
    var entries: [MenuEntry]
    var anchor: CGRect
    var width: CGFloat = 290
    var trailing = false
    var custom: AnyView? = nil
    var back: [[MenuEntry]] = []
    var host = "main"   // which window draws it: "main" or "compose" (the separate compose window)
}

struct LinkPrompt: Identifiable { let id = UUID(); let url: URL; let reason: String }

struct SavedState: Codable {
    var accounts: [String] = []
    var splits: [Split] = []
    var snippets: [Snippet] = [Snippet(name: "Thanks", body: "Thanks {first_name}, appreciate it!")]
    var snoozes: [Snooze] = []
    var scheduled: [ScheduledSend] = []
    var followUps: [FollowUp] = []
    var bumped: [String: Date] = [:]
    var historyIds: [String: String] = [:]
    var importance: [String: Bool] = [:]
    var activeAccount: String?   // nil = all accounts together
    var appearance = "System"     // System, Light or Dark
    var icloud: [String] = []     // which accounts are iCloud (the rest are Gmail)
    var icloudLogins: [String: String] = [:]   // email → IMAP username that worked
    var aliases: [String: [String]] = [:]      // account → extra addresses you can send as
    var defaultFrom: [String: String] = [:]    // account → address new emails come from
    var accountNames: [String: String] = [:]   // account → nickname like "Work" (Mac Mail's "Description")
    var senderNames: [String: String] = [:]    // account → the name people see on your email, e.g. "Dan Chait"
    var accountColors: [String: Int] = [:]     // account → its color in inbox rows (index into AppStore.accountPalette)
    var undoSendSeconds = 10
    var aiProvider = "claude"
    var signatures: [String: String] = [:]     // sending address → signature text
    var signatureUse = "all"                   // all, new, replies or off
    var onboarded = false                      // finished the first-run setup flow
    var aiModels: [String: String] = [:]      // provider id → model override (blank = the tool's default)
    var muted: [String] = []                   // conversation ids whose new replies skip the inbox
    var autoArchive: [AutoArchiveCategory] = []
    var autoArchiveSince: Date?                // only mail arriving after this is auto-archived
    var autoArchived: [String] = []            // conversation ids, newest last (for the folder)
    var microsoftPreview: [String] = []        // old preview list; moved into `accounts` on load
    var microsoft: [String] = []               // which accounts are Microsoft (Outlook.com, Hotmail, Microsoft 365)
    var eventLinks: [String: String] = [:]     // calendar event (UID, or "title|minute") → conversation id it came from
    var readyDrafts: [String: ReadyDraft] = [:] // conversation id → reply written ahead of time
    var cleanupKept: [String] = []             // senders Clean up no longer lists ("Keep")

    init() {}
    /// Tolerates missing keys so adding a setting never wipes your accounts and splits.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        let base = SavedState()
        accounts = v(.accounts, base.accounts); splits = v(.splits, base.splits); snippets = v(.snippets, base.snippets)
        snoozes = v(.snoozes, base.snoozes); scheduled = v(.scheduled, base.scheduled); followUps = v(.followUps, base.followUps)
        bumped = v(.bumped, base.bumped); historyIds = v(.historyIds, base.historyIds); importance = v(.importance, base.importance)
        activeAccount = v(.activeAccount, base.activeAccount)
        appearance = v(.appearance, base.appearance)
        icloud = v(.icloud, base.icloud)
        icloudLogins = v(.icloudLogins, base.icloudLogins)
        aliases = v(.aliases, base.aliases)
        defaultFrom = v(.defaultFrom, base.defaultFrom)
        accountNames = v(.accountNames, base.accountNames)
        senderNames = v(.senderNames, base.senderNames)
        accountColors = v(.accountColors, base.accountColors)
        undoSendSeconds = v(.undoSendSeconds, base.undoSendSeconds)
        aiProvider = v(.aiProvider, base.aiProvider); aiModels = v(.aiModels, base.aiModels)
        signatures = v(.signatures, base.signatures)
        signatureUse = v(.signatureUse, base.signatureUse)
        // People who already had accounts before onboarding existed skip it.
        onboarded = v(.onboarded, !accounts.isEmpty)
        muted = v(.muted, base.muted); autoArchive = v(.autoArchive, base.autoArchive)
        autoArchiveSince = v(.autoArchiveSince, base.autoArchiveSince); autoArchived = v(.autoArchived, base.autoArchived)
        microsoftPreview = v(.microsoftPreview, base.microsoftPreview)
        microsoft = v(.microsoft, base.microsoft)
        eventLinks = v(.eventLinks, base.eventLinks)
        readyDrafts = v(.readyDrafts, base.readyDrafts); cleanupKept = v(.cleanupKept, base.cleanupKept)
        // "Needs reply" first shipped without "also in the inbox", which hid drafted emails from Important/Other.
        for i in splits.indices where splits[i].query == "is:drafted" { splits[i].alsoInMain = true }
        // Accounts connected during the sign-in preview join the inbox now that mail reading exists.
        for a in microsoftPreview where !accounts.contains(a) { accounts.append(a); microsoft.append(a) }
        microsoftPreview = []
    }
}

extension SavedState {
    /// Drops everything stored for a signed-out account, including unsent scheduled sends.
    mutating func forget(_ a: String) {
        let addresses = Set([a] + (aliases[a] ?? []) + [defaultFrom[a]].compactMap { $0 }).map { $0.lowercased() }
        func mine(_ address: String) -> Bool {
            addresses.contains(address.lowercased()) || parseAddresses(address).contains { addresses.contains($0.email.lowercased()) }
        }
        func ours(_ conversationId: String) -> Bool { conversationId.hasPrefix(a + "|") }
        accounts.removeAll { $0 == a }
        icloud.removeAll { $0 == a }
        icloudLogins[a] = nil
        aliases[a] = nil
        defaultFrom[a] = nil
        accountNames[a] = nil
        senderNames[a] = nil
        accountColors[a] = nil
        historyIds[a] = nil
        if activeAccount == a { activeAccount = nil }
        snoozes.removeAll { $0.account == a }
        followUps.removeAll { $0.account == a }
        scheduled.removeAll { mine($0.draft.from) }
        for k in signatures.keys where mine(k) { signatures[k] = nil }
        for k in bumped.keys where ours(k) { bumped[k] = nil }
        for k in importance.keys where ours(k) { importance[k] = nil }
        muted.removeAll(where: ours)
        autoArchived.removeAll(where: ours)
        for (k, v) in eventLinks where ours(v) { eventLinks[k] = nil }
    }
}

struct Cache: Codable { var messages: [Message] = []; var labelNames: [String: String] = [:] }

final class ComposeModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft: Draft
    @Published var remindDays: Int?
    @Published var busy = false
    @Published var error: String?
    @Published var savedNote: String?
    @Published var askClose = false   // "Save this draft?" showing, from ✕, Esc or the window's close button
    var saveTask: Task<Void, Never>?
    var draftMessage: Message?   // the saved draft this compose was reopened from, if any
    var inline = false           // a reply shown inside the conversation instead of its own window
    let context: Conversation?
    init(draft: Draft, context: Conversation?) { self.draft = draft; self.context = context }
}

struct Command: Identifiable {
    let id = UUID()
    let title: String
    var key = ""
    let run: () -> Void
}

@MainActor
final class AppStore: ObservableObject {
    @Published var state: SavedState = Disk.load("state.json", as: SavedState.self) ?? SavedState() {
        didSet { invalidate(); Disk.save(state, "state.json") }
    }
    @Published var messages: [String: Message] = [:] { didSet { invalidate() } }
    @Published var labelNames: [String: String] = [:] { didSet { invalidate() } }

    // Speed: threads and split tabs are computed once per change, not on every redraw.
    var convCache: [Conversation]?
    var tabCache: [String: [Conversation]]?
    var knownCache: Set<String>?
    func invalidate() {
        convCache = nil; tabCache = nil; knownCache = nil
        cacheDirty = true
        // Dock badge follows reads, archives and new mail; many changes in a row cost one update.
        badgeTask?.cancel()
        badgeTask = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { Notifier.shared.updateBadge() } }
    }
    var badgeTask: Task<Void, Never>?
    var cacheDirty = false
    var lastSavedFingerprint: Int?
    var cacheWrite: Task<Void, Never>?

    /// Everyone you've written to. Their mail skips the brand-impersonation checks.
    var knownContacts: Set<String> {
        if let k = knownCache { return k }
        let mine = me
        var out = Set<String>()
        // Only mail you actually sent (Gmail's SENT label). A received email can claim to be from you in its From line.
        for m in messages.values where m.labelIds.contains("SENT") && m.authFailed != true && parseAddresses(m.from).contains(where: { mine.contains($0.email.lowercased()) }) {
            for a in parseAddresses(m.to + "," + m.cc) { out.insert(a.email.lowercased()) }
        }
        knownCache = out
        return out
    }
    @Published var hasClient = GoogleClient.load() != nil
    @Published var tabName = (UserDefaults.standard.object(forKey: "splitImportance") as? Bool ?? true) ? importantTab : inboxTab
    @Published var folder: String?          // "Starred", "Search: …" etc. replaces the split tabs
    @Published var unreadOnly = false
    /// Folders panel opened by hand (← or the menu button). Settings → General → Show folders sidebar pins it instead.
    @Published var sidebarOpen = false { didSet {
        if !sidebarOpen && !foldersPinned { sidebarFocused = false }
        if sidebarOpen && !oldValue { panelIndex = currentPanelIndex }
        if !sidebarOpen && oldValue { refreshHover(after: 0.4) } // after the slide-out animation
    } }
    @Published var panelIndex = 0   // keyboard highlight in the folder panel

    static let panelFolders = ["Inbox", "Starred", "Drafts", "Sent", "Done", "Auto Archived", "Scheduled",
                               "Reminders", "Snippets", "Muted", "Spam", "Trash"]
    /// User labels shown under the folders, in the same order the panel draws them.
    var panelLabels: [String] {
        labelNames.values.filter { !isAppLabel($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    var panelCount: Int { Self.panelFolders.count + panelLabels.count }
    var currentPanelIndex: Int {
        if let f = folder {
            if let i = Self.panelFolders.firstIndex(of: f) { return i }
            if let i = panelLabels.firstIndex(of: f) { return Self.panelFolders.count + i }
        }
        return 0
    }

    /// Opens whatever row `i` of the folder panel is, then closes the panel.
    /// The keyboard is driving the folders panel (← put it there); J/K and arrows move through folders until Esc or Return.
    @Published var sidebarFocused = false

    func activatePanel(_ i: Int) {
        if i < Self.panelFolders.count { goFolder(Self.panelFolders[i]) }
        else if panelLabels.indices.contains(i - Self.panelFolders.count) {
            let l = panelLabels[i - Self.panelFolders.count]
            runQuery("label:\"\(l)\"", title: l)
        }
        sidebarFocused = false              // the keyboard goes back to the mail
        if !foldersPinned { sidebarOpen = false }   // opened by hand: it closes once you've picked
    }
    @Published var contextOpen = false   // opened by hand (→); Settings → General → Show context panel pins it

    // Settings switches are the master control: on = always visible (arrows never close it), off = open and close by hand.
    var foldersPinned: Bool { UserDefaults.standard.object(forKey: "foldersPinned") as? Bool ?? UserDefaults.standard.bool(forKey: "foldersOpen") }
    var contextPinned: Bool { UserDefaults.standard.object(forKey: "contextPinned") as? Bool ?? true }
    var foldersVisible: Bool { foldersPinned || sidebarOpen }
    var contextVisible: Bool { contextPinned || contextOpen }
    func setFoldersPinned(_ on: Bool) { UserDefaults.standard.set(on, forKey: "foldersPinned"); sidebarOpen = false; sidebarFocused = false; objectWillChange.send() }
    func setContextPinned(_ on: Bool) { UserDefaults.standard.set(on, forKey: "contextPinned"); contextOpen = false; objectWillChange.send() }
    @Published var splitSettingsOpen = false
    @Published var recentlyOpened: [String] = []
    @Published var inlineData: [String: [String: String]] = [:]   // message key → content id → data URL
    @Published var instantReplies: [String: [String]] = [:]        // conversation id → options
    @Published var previewURL: URL?
    @Published var popup: Popup? { didSet { if popup == nil && oldValue != nil { refreshHover(after: 0.15) } } }
    @Published var popupIndex: Int?
    @Published var linkPrompt: LinkPrompt?
    static weak var current: AppStore?        // for AppKit code (web view delegates) that has no environment
    var rightClickTarget: Conversation?       // the email row under the mouse, set by hover
    var mainFrame: CGRect = .zero             // main view's frame in window coordinates, for placing right-click menus
    var mouseMonitor: Any?
    @Published var thumbnails: [String: NSImage] = [:]   // "message key|attachment id" → image
    @Published var instantLoading: String?
    @Published var eventDraft: EventDraft?
    @Published var claudeTask: ClaudeTask?
    @Published var agentApproval: AgentApproval?
    // Conversation view state, kept here (not in the views) so keys and ⌘K reach it.
    @Published var threadToggled: Set<String> = []   // message keys flipped from their default (latest open, older closed)
    @Published var quotedShown: Set<String> = []     // messages showing their earlier quoted history
    @Published var imagesShown: Set<String> = []     // messages whose remote images were loaded once
    @Published var streamExpanded: Set<String> = []  // Stream layout: conversations showing the full email
    @Published var agentLog: [AgentLogEntry] = []
    var agentSocket: Int32?
    /// Set by the focused To/Cc/Bcc row: removes its last address on Backspace when nothing is typed. Returns true if it did.
    var chipBackspace: (() -> Bool)?
    /// Each email's searchable text (subject + sender + text, lowercased), built once instead of on every keystroke.
    private var hayCache: [String: String] = [:]
    func searchHay(_ m: Message) -> String {
        let k = m.key + "|" + m.id
        if let h = hayCache[k] { return h }
        let h = EmailCore.searchHay(m)
        hayCache[k] = h
        return h
    }
    let calendar = CalendarService()
    // Calendar screen (g c). Its view, week start, default calendar and hidden calendars live in UserDefaults.
    @Published var calendarOpen = false
    @Published var searchFocus = 0                    // bumped by / to put the cursor back in an open search bar
    @Published var toolScreen: ToolScreen?          // Clean up senders or Insights, in place of the inbox (⌘K)
    @Published var cleanupFilter = CleanupFilter.most
    @Published var cleanupIndex = 0
    @Published var cleanupSelected: Set<String> = []
    @Published var cleanupDone: [String: String] = [:]   // sender → what just happened ("Unsubscribed", "Archived 12")
    var cleanupUndo: (senders: [String], conversations: [Conversation])?
    @Published var insightsDays = 30
    @Published var draftsWriting: Set<String> = []  // conversation ids whose ready draft is being written
    @Published var calDate = Date()                  // the day the view is built around
    @Published var calEvents: [CalEvent] = []        // what the current view shows
    @Published var calUpcoming: [CalEvent] = []      // the next 7 days, for the context panel
    @Published var calSources: [CalSource] = []
    @Published var calSelected: String?              // the event whose card is open
    @Published var quickAddOpen = false
    @Published var placingEmail: String?
    @Published var calEditing: String?               // the event whose card is in edit mode (E or the pencil)
    var calLoadID = 0                                // newest calendar load; older ones finishing late are dropped
    var calTriedLoad = false                         // the context panel loaded the calendar once already
    var inviteIndexCache: (stamp: Int, map: [String: String])?             // conversation waiting for you to click a time on the calendar
    @Published var calNeedsAccess: Set<String> = []  // accounts whose calendar is waiting for your OK
    @Published var inviteAnswers: [String: RSVP] = [:]   // invite UID → your answer, once known or given
    @Published var inviteSending: String?                // invite UID while an answer is on its way
    @Published var inviteDay: InviteDay?                 // the open invite's day, for the strip and the context panel
    var openInvite: (message: Message, invite: Invite)?  // the invite in the email you're reading (Y / ? / N answer it)
    var pendingG: Date?
    @Published var selectedID: String?
    @Published var threadOpen = false
    @Published var paletteOpen = false { didSet { if !paletteOpen && oldValue { refreshHover(after: 0.1) } } }
    @Published var paletteText = ""
    @Published var paletteIndex = 0
    @Published var searchOpen = false
    @Published var searchText = ""
    @Published var searchResults: Set<String>?   // conversation ids
    @Published var composing: ComposeModel? { didSet {
        if composing == nil && oldValue != nil { refreshHover(after: 0.25) }
        ComposeWindow.shared.update(self)
    } }
    @Published var editingSnippet: Snippet?
    /// Every banner closes itself: 5 seconds, plus reading time for longer messages (up to 12), unless another
    /// banner replaced it first. The ✕ still closes it sooner.
    @Published var banner: String? { didSet {
        guard let text = banner, text != oldValue else { return }
        bannerToken += 1
        let token = bannerToken, seconds = min(12, max(5, Double(text.count) / 15))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if bannerToken == token, banner == text { banner = nil }
        }
    } }
    @Published var summary: String?
    @Published var busy: String?

    let auth = GoogleAuth()
    let microsoft = MicrosoftAuth()
    var timer: Timer?
    var keyMonitor: Any?

    init() {
        // A missing or outdated cache must force a full resync, or history sync would skip old mail.
        let cache = Disk.load("cache2.json", as: Cache.self) ?? { state.historyIds = [:]; return Cache() }()
        messages = Dictionary(cache.messages.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        labelNames = cache.labelNames
    }

    /// Settings slide in from the right inside the main window (⌘,). Esc or clicking the inbox closes them.
    /// Set while Settings → Signatures is open from a draft's Signature menu: which draft and address to refresh after.
    var resumeSignature: (model: ComposeModel, address: String)?
    @Published var signatureFocus: String?   // address Settings → Signatures should select when it opens
    @Published var settingsOpen = false { didSet {
        guard !settingsOpen && oldValue else { return }
        // Back from editing a signature mid-draft: put the updated signature into that draft.
        if let r = resumeSignature, r.model === composing { applySignature(&r.model.draft, from: r.address) }
        resumeSignature = nil
        // Hand the keyboard back to the inbox, or a settings text box keeps it and arrows/Return stop working.
        NSApp.keyWindow?.makeFirstResponder(nil)
        refreshHover(after: 0.5)
    } }
    /// Opens Settings on `tab` (e.g. "signatures"). A draft that's open stays open underneath and is there when Settings closes.
    @Published var settingsSearchFocus = 0   // bumped by ⌘K while Settings is open
    func openSettings(tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        openSettings()
    }

    func openSettings() {
        paletteOpen = false; sidebarFocused = false; closePopup()
        settingsOpen = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func setAppearance(_ name: String) {
        state.appearance = name
        NSApp.appearance = name == "Light" ? NSAppearance(named: .aqua) : name == "Dark" ? NSAppearance(named: .darkAqua) : nil
    }

    func start() {
        guard timer == nil else { return }
        RemoteContent.prepare()
        Disk.clearPreviewCache()
        updateAgentBridge()
        Task {
            await loadVacations()
            await loadAccountPhotos()
            for a in gmailAccounts { await loadLabels(a) } // for the Label menu; needs no extra permission
        }
        // Follow the Mac's light/dark setting by default (one-time reset from the old toggle).
        if !UserDefaults.standard.bool(forKey: "appearanceFollowsSystemV1") {
            state.appearance = "System"; UserDefaults.standard.set(true, forKey: "appearanceFollowsSystemV1")
        }
        setAppearance(state.appearance)
        AppStore.current = self
        Notifier.shared.start(self)
        GoogleNet.purgeOldCache()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] e in
            MainActor.assumeIsolated { self?.rightClick(e) == true ? nil : e }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) == true ? nil : e }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick(scheduled: true) } }
        Task { await tick() }
    }

    /// Writes the encrypted cache, but only when mail actually changed since the last write (it used to rewrite
    /// the whole file on every 30-second check). Old mail outside the cache limits is dropped first.
    func saveCache() {
        guard cacheDirty else { return }
        pruneCache()
        cacheDirty = false
        // Syncs often reassign mail without changing it; skip the write when the content is identical.
        var h = Hasher(); h.combine(messages); h.combine(labelNames)
        let fingerprint = h.finalize()
        guard fingerprint != lastSavedFingerprint else { return }
        lastSavedFingerprint = fingerprint
        let snapshot = Cache(messages: Array(messages.values), labelNames: labelNames)
        let previous = cacheWrite
        // One write at a time, in order, so an older snapshot can never land on top of a newer one.
        cacheWrite = Task.detached(priority: .utility) { await previous?.value; Disk.save(snapshot, "cache2.json") }
    }

    /// Keeps inbox, snoozed and follow-up threads whole, plus each account's newest 5,000 messages from 90 days.
    func pruneCache() {
        var threads = Set(messages.values.filter { $0.labelIds.contains("INBOX") || $0.labelIds.contains("DRAFT") }.map { $0.account + "|" + $0.threadId })
        threads.formUnion(state.snoozes.map { $0.account + "|" + $0.threadId })
        threads.formUnion(state.followUps.map { $0.account + "|" + $0.threadId })
        threads.formUnion(recentlyOpened) // never pull an email out from under you while you're reading it
        if let s = selectedID { threads.insert(s) }
        let keep = cacheKeys(Array(messages.values), keepThreads: threads)
        if keep.count < messages.count {
            log("cache: dropped \(messages.count - keep.count) old messages")
            messages = messages.filter { keep.contains($0.key) }
        }
    }
    func gmail(_ account: String) -> Gmail { Gmail(account: account, auth: auth) }
    func isICloud(_ a: String) -> Bool { state.icloud.contains(a) }
    /// Logo key and display name for an account's provider (iCloud-type accounts may be Yahoo).
    func brand(_ a: String) -> String { isICloud(a) ? (imapServer(for: a).name == "Yahoo" ? "yahoo" : "icloud") : isMicrosoft(a) ? "outlook" : "gmail" }
    func providerName(_ a: String) -> String { ["yahoo": "Yahoo Mail", "icloud": "iCloud Mail", "outlook": "Outlook"][brand(a)] ?? "Gmail" }
    func isMicrosoft(_ a: String) -> Bool { state.microsoft.contains(a) }
    /// Gmail-only features (labels, server search, Gmail settings, Google Calendar) check this, never "not iCloud".
    func isGmail(_ a: String) -> Bool { !isICloud(a) && !isMicrosoft(a) }
    func graph(_ a: String) -> GraphMail { GraphMail(account: a, auth: microsoft) }
    func icloud(_ a: String) -> ICloud {
        ICloud(account: a, login: state.icloudLogins[a] ?? String(a.split(separator: "@").first ?? ""))
    }
    @Published var syncing = false
    var me: Set<String> { Set((state.accounts + state.aliases.values.flatMap { $0 }).map { $0.lowercased() }) }

    /// Every address you can send from: each account, followed by its aliases.
    var fromAddresses: [String] { state.accounts.flatMap { [$0] + (state.aliases[$0] ?? []) } }

    /// The account that owns a From address (itself, or the account an alias belongs to).
    func account(for from: String) -> String {
        // "Danny Chait <danny@x.com>" (a From with your name added) belongs to danny@x.com. Comparing the whole string
        // matched no account, so drafts and sends from a named address said the account was signed out.
        let f = (parseAddresses(from).first?.email ?? from).lowercased()
        if let a = state.accounts.first(where: { $0.lowercased() == f }) { return a }
        return state.aliases.first { $0.value.contains { $0.lowercased() == f } }?.key ?? from
    }

    /// The account a draft saves and sends through: the one picked for it, else the one its From address belongs to.
    func account(of d: Draft) -> String {
        if let a = d.account, state.accounts.contains(a) { return a }
        return account(for: d.from)
    }

    /// "Work" if named, otherwise the address.
    func label(_ account: String) -> String {
        let n = state.accountNames[account]?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? sendAddress(account) : n
    }

    /// Each account's color in inbox rows: the one picked in Settings → Accounts, else one by the account's place in the list.
    static let accountPalette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .mint, .indigo]
    func accountColorIndex(_ account: String) -> Int? {
        if let i = state.accountColors[account], Self.accountPalette.indices.contains(i) { return i }
        return state.accounts.firstIndex(of: account).map { $0 % Self.accountPalette.count }
    }
    func accountColor(_ account: String) -> Color { accountColorIndex(account).map { Self.accountPalette[$0] } ?? .secondary }

    /// "Work · danny@x.com" for menus where both help.
    func fullLabel(_ address: String, account known: String? = nil) -> String {
        let acct = known ?? account(for: address)
        let n = state.accountNames[acct]?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? address : "\(n) · \(address)"
    }

    /// The address an account sends from unless a reply says otherwise.
    func sendAddress(_ account: String) -> String {
        if let d = state.defaultFrom[account], d == account || (state.aliases[account] ?? []).contains(d) { return d }
        return account
    }

    func setAliases(_ text: String, for account: String) {
        state.aliases[account] = text.split(whereSeparator: { ",; \n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && $0 != account.lowercased() }
    }

    /// Replies go out from whichever of your aliases the original was sent to.
    func replyFrom(_ m: Message, account: String) -> String {
        let to = parseAddresses(m.to + "," + m.cc).map { $0.email.lowercased() }
        return (state.aliases[account] ?? []).first { to.contains($0) } ?? sendAddress(account)
    }
    /// Every error shown to the user goes through here: Google and network errors become plain sentences.
    func report(_ e: Error) {
        if e is CancellationError || (e as? URLError)?.code == .cancelled { return } // -999: we stopped the request ourselves
        // ponytail: demo accounts have no server, so every sync/triage call fails; hide those. AI errors are hidden too.
        if AppFlavor.isDemo { log("demo: \(e.localizedDescription)"); return }
        banner = friendlyNetworkError(e) ?? e.localizedDescription
    }


    // Stored state that the extensions in Store+*.swift use
    var ticking = false
    var bannerToken = 0
    var cooldown: [String: Date] = [:]
    var lastSynced: [String: Date] = [:]
    var quotaHits: [String: Int] = [:]
    var undoStack: [(c: Conversation, kind: UndoKind)] = []
    var lastCalendarRefresh = Date()
    var stickyRow: (tab: String, id: String, index: Int)?   // the opened email keeps its row (see `visible`)
    @Published var pendingSends: [PendingSend] = []
    @Published var vacations: [String: Vacation] = [:]
    @Published var needsSettingsAccess: Set<String> = []
    @Published var gmailLabels: [String: [Gmail.Label]] = [:]
    @Published var search = SearchQuery()
    @Published var searchFiltersOpen = false
    @Published var splitSuggestions: [Split] = []
}

/// Your other events on an invite's day.
struct InviteDay { let uid: String; let day: Date; let events: [CalEvent] }

struct EventDraft: Identifiable {
    let id = UUID()
    var title: String
    var start: Date
    var minutes: Int
    var notes: String
    var location = ""
    var account = ""                 // the email's account; its Google Calendar is the default destination
    var people: [Address] = []       // everyone on the email except you, offered as guests
    var timeFromEmail = false        // the start time was found in the email text
    var suggestGuests = true         // false for newsletters and automated mail: nobody is pre-selected
}
