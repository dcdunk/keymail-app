import Foundation

/// The single-key inbox commands and the user's remappings of them (Settings → Hotkeys).
/// Commands are identified by their default key; a remap is stored as "hotkey.<default>" in UserDefaults.
enum Hotkeys {
    static let commands: [(key: String, title: String)] = [
        ("c", "Compose"), ("r", "Reply"), ("a", "Reply all"), ("f", "Forward"),
        ("e", "Mark done"), ("s", "Star / unstar"), ("u", "Mark read / unread"), ("#", "Trash"), ("!", "Mark as junk"),
        ("h", "Remind me"), ("l", "Label"), ("b", "Create calendar event"), ("i", "Summarize thread"),
        ("o", "Open email"), ("j", "Next email"), ("k", "Previous email"), ("/", "Search"), ("g", "Go to… (then i, s, t, e, h, d, or c for Calendar)"),
    ]
    /// Shown in Settings only; these use modifiers or special keys and aren't remappable.
    static let fixed: [(key: String, title: String)] = [
        ("⌘K", "Command palette"), ("⌘R", "Fetch mail"), ("⌘Z", "Undo"), ("⌘,", "Settings"), ("⌘1–9 / ⌘0", "Switch account / all accounts"),
        ("⇧R", "Instant reply"), ("⇧U", "Unsubscribe"), ("⇧M", "Mute thread"), ("1–3", "Use instant reply"),
        ("Tab / ⇧Tab", "Next / previous split"), ("↑ ↓", "Previous / next email"), ("← →", "Folders / context panel"),
        ("Return", "Open email"), ("Esc", "Back"), ("⌫", "Trash"),
        ("Space", "Open the next collapsed email in a conversation"), ("⇧O", "Open or close all emails in a conversation"),
        ("." , "Show or hide earlier messages"), ("R on your draft", "Continue editing it"),
        ("⇧⌘F", "Compose: send from"), ("⇧⌘C / ⇧⌘B", "Compose: add Cc / Bcc"), ("⇧⌘S", "Compose: signature"),
        ("⇧⌘I", "Compose: insert snippet"), ("⌘B / ⌘I", "Compose: bold / italic"), ("⌘K in a draft", "Compose: add or edit a link"), ("⇧⌘A", "Compose: attach"), ("⌥⌘⌫", "Compose: remove last attachment"),
        ("⇧⌘.", "Compose: show quoted text"), ("⇧⌘↵", "Compose: send later / remind me"), ("⇧⌘⌫", "Compose: discard"),
        ("⌘F", "Search: more filters"), ("⌘↵", "Link warning: open anyway"),
        ("G C / G I", "Calendar / back to mail"), ("Calendar: J K", "Next / previous event"), ("Calendar: H L", "Previous / next day, week or month"),
        ("Calendar: T", "Today"), ("Calendar: D W M", "Day, week or month view"), ("Calendar: C", "New event (type it in plain words)"),
        ("Calendar: E", "Edit event"), ("Calendar: ⌫", "Delete event"), ("Calendar: ⇧J", "Join the event's video call"), ("Y / ? / N", "Answer an invite: yes, maybe, no"),
    ]

    /// True while Settings is waiting for a new key, so the inbox and Esc-to-close leave it alone.
    static var recording = false

    static var overrides: [String: String] {
        var o: [String: String] = [:]
        for c in commands { if let v = UserDefaults.standard.string(forKey: "hotkey." + c.key) { o[c.key] = v } }
        return o
    }
    static func key(for command: String, _ o: [String: String] = overrides) -> String { o[command] ?? command }
    /// Uppercased for menus and the palette, e.g. "C".
    static func label(_ command: String) -> String { key(for: command).uppercased() }

    static func set(_ command: String, to key: String?) {
        if let key, key != command { UserDefaults.standard.set(key, forKey: "hotkey." + command) }
        else { UserDefaults.standard.removeObject(forKey: "hotkey." + command) }
    }
    static func resetAll() { commands.forEach { set($0.key, to: nil) } }

    /// The command (by default key) another command already uses `key` for, so Settings can refuse duplicates.
    static func owner(of key: String, _ o: [String: String] = overrides) -> String? {
        commands.first { Self.key(for: $0.key, o) == key }?.key
    }

    /// Turns a pressed key into the default key of the command it triggers. A default key the user moved
    /// elsewhere returns "" so it no longer fires; unrelated keys pass through unchanged.
    static func resolve(_ pressed: String, _ o: [String: String] = overrides) -> String {
        if let c = owner(of: pressed, o) { return c }
        return commands.contains { $0.key == pressed } ? "" : pressed
    }
}
