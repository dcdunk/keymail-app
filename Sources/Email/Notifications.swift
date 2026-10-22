import AppKit
import UserNotifications
import EmailCore

/// New-mail notifications and the Dock badge.
/// Settings: "notifyMode" = important | all | off, "badgeMode" = important | all | off.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var store: AppStore?
    @Published var denied = false
    @Published var badgeBlocked = false   // macOS only draws the Dock badge when "Badge app icon" is allowed

    static var notifyMode: String { UserDefaults.standard.string(forKey: "notifyMode") ?? "important" }
    static var sound: Bool { UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true }
    static var badgeMode: String { UserDefaults.standard.string(forKey: "badgeMode") ?? "important" }

    func start(_ store: AppStore) {
        self.store = store
        UNUserNotificationCenter.current().delegate = self
        if Self.notifyMode != "off" || Self.badgeMode != "off" { requestPermission() }
        updateBadge()
    }

    /// macOS asks once; after that the user's choice lives in System Settings → Notifications.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in self.refreshStatus() }
        }
    }

    /// Reads what the user allowed in System Settings → Notifications → Keymail.
    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let denied = s.authorizationStatus == .denied, badge = s.badgeSetting != .enabled
            Task { @MainActor in self.denied = denied; self.badgeBlocked = badge; self.updateBadge() }
        }
    }

    func notify(_ arrivals: [(message: Message, conversationId: String)]) {
        guard Self.notifyMode != "off", !arrivals.isEmpty, let store else { return }
        // Notch style: only while you're in another app, same as banners. Fewer than 5 each get a turn in the notch.
        if NotchBanner.enabled, !NSApp.isActive, arrivals.count <= 4 {
            let shown = arrivals.allSatisfy { a in
                let from = parseAddresses(a.message.from).first
                return NotchBanner.shared.show(.init(
                    title: from?.display ?? a.message.from,
                    subtitle: store.state.accounts.count > 1 ? "\(store.label(a.message.account)) · \(a.message.subject)" : a.message.subject,
                    body: a.message.snippet, sender: from, open: { [weak self] in self?.open(a.conversationId) }))
            }
            if shown { return }
        }
        let center = UNUserNotificationCenter.current()
        // A burst (for example after waking the Mac) becomes one summary instead of a wall of banners.
        if arrivals.count > 4 {
            let c = UNMutableNotificationContent()
            c.title = "\(arrivals.count) new emails"
            c.body = arrivals.suffix(3).compactMap { parseAddresses($0.message.from).first?.display }.joined(separator: ", ")
            c.sound = Self.sound ? .default : nil
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            return
        }
        for a in arrivals {
            let c = UNMutableNotificationContent()
            c.title = parseAddresses(a.message.from).first?.display ?? a.message.from
            c.subtitle = a.message.subject
            c.body = a.message.snippet
            c.threadIdentifier = a.conversationId // macOS groups replies in one thread together
            c.userInfo = ["conversation": a.conversationId]
            if store.state.accounts.count > 1 { c.subtitle = "\(store.label(a.message.account)) · \(a.message.subject)" }
            c.sound = Self.sound ? .default : nil
            center.add(UNNotificationRequest(identifier: a.message.key, content: c, trigger: nil))
        }
    }

    /// Settings → "Send a test notification". Shows even while Keymail is in front.
    func sendTest() {
        let c = UNMutableNotificationContent()
        c.title = "Keymail"; c.body = "Notifications are working."; c.sound = Self.sound ? .default : nil
        c.userInfo = ["test": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(UUID())", content: c, trigger: nil)) { err in
            if let err { Task { @MainActor in self.store?.log("notify: test failed: \(err.localizedDescription)") } }
        }
    }

    /// Unread conversations in Important (or the whole inbox), shown on the Dock icon.
    func updateBadge() {
        guard let store else { return }
        var n = 0
        if Self.badgeMode != "off" {
            let inbox = store.allConversations.filter { $0.inInbox && $0.isUnread }
            n = Self.badgeMode == "all" ? inbox.count : {
                let ctx = store.context(store.allConversations)
                return inbox.filter { isImportant($0, ctx) }.count
            }()
        }
        let label = n == 0 ? nil : n > 999 ? "999+" : "\(n)"
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // Banners only when you're not already looking at Keymail.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let test = notification.request.content.userInfo["test"] != nil
        Task { @MainActor in done(NSApp.isActive && !test ? [.list] : (Self.sound ? [.banner, .list, .sound] : [.banner, .list])) }
    }

    // Clicking a notification opens that email.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["conversation"] as? String
        Task { @MainActor in self.open(id); done() }
    }

    func open(_ id: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let id, let store, let c = store.allConversations.first(where: { $0.id == id }) { store.open(c) }
    }
}
