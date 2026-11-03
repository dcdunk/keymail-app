import AppKit
import CryptoKit
import Foundation
import SwiftUI
import EmailCore

/// Notes when the app stops responding, and what was on screen, in a small local file (⌘K → Show freeze log).
/// A background thread pings the main thread, so it can still write while the main thread is stuck: a "started" line
/// with no "ended" after it means the freeze never let go and the app was force quit. Nothing is written unless a
/// freeze happens, and nothing leaves this Mac.
/// ponytail: the file is never trimmed; at about 300 bytes a freeze that takes years to matter. Trim at launch if it does.
final class FreezeRecorder: @unchecked Sendable {
    static let shared = FreezeRecorder(log: Disk.dir.appendingPathComponent("freezes.log"))

    let log: URL
    private let threshold: TimeInterval, interval: TimeInterval
    private let lock = NSLock()
    private var screen = ""
    private var running = false
    private let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    init(log: URL, threshold: TimeInterval = 3, interval: TimeInterval = 1) {
        self.log = log; self.threshold = threshold; self.interval = interval
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func note(_ s: String) { lock.lock(); screen = s; lock.unlock() }
    func stop() { lock.lock(); running = false; lock.unlock() }

    @MainActor func start(snapshot: @escaping @MainActor () -> String) {
        guard !isRunning else { return }
        lock.lock(); running = true; lock.unlock()
        note(snapshot())   // now, so a freeze in the very first layout still says what was on screen
        let t = Thread { [self] in watch(snapshot) }
        t.name = "Keymail freeze recorder"
        t.qualityOfService = .utility
        t.start()
    }

    private func watch(_ snapshot: @escaping @MainActor () -> String) {
        while isRunning {
            let answered = DispatchSemaphore(value: 0)
            let sent = DispatchTime.now()   // doesn't count while the Mac sleeps, so sleeping isn't a freeze
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { note(snapshot()) }
                answered.signal()
            }
            if answered.wait(timeout: sent + threshold) == .timedOut {
                lock.lock(); let on = screen; lock.unlock()
                write("\(Date().ISO8601Format()) v\(version) FREEZE started | \(on)")
                answered.wait()
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e9
                write("\(Date().ISO8601Format()) v\(version) FREEZE ended after \(String(format: "%.1f", seconds))s")
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: log) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: log.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

extension AppStore {
    /// What's needed to reproduce a freeze, and nothing personal: no addresses, subjects, previews or message text.
    var freezeSnapshot: String {
        let screen = calendarOpen ? "calendar" : toolScreen.map { "\($0)" } ?? (threadOpen ? "thread" : "list")
        var parts = ["screen=\(screen)", "layout=\(inboxLayout)", "shown=\(visible.count)",
                     "window=\(Int(mainFrame.width))x\(Int(mainFrame.height))", "context=\(contextVisible)", "folders=\(foldersVisible)",
                     "scrollbars=\(NSScroller.preferredScrollerStyle == .legacy ? "always" : "overlay")", "textScale=\(Font.scale)"]
        if settingsOpen { parts.append("settings=open") }
        if composing != nil { parts.append("compose=open") }
        if let c = selected {
            parts += ["email=\(Self.freezeSafeID(c.threadId))", "account=\(state.accounts.firstIndex(of: c.account) ?? -1)",
                      "messages=\(c.messages.count)", "htmlBytes=\(c.messages.reduce(0) { $0 + ($1.html?.utf8.count ?? 0) })",
                      "attachments=\(c.messages.reduce(0) { $0 + $1.attachments.count })", "invite=\(c.messages.contains { $0.calendar != nil })"]
        }
        return parts.joined(separator: " ")
    }

    /// Gmail and Outlook thread IDs are opaque. iCloud and Yahoo ones are built from a message's header or even its
    /// subject (see threadKey), so those are hashed.
    static func freezeSafeID(_ id: String) -> String {
        guard id.hasPrefix("<") || id.hasPrefix("subject:") else { return id }
        return "sha-" + SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func noteScreenForFreezes() {
        if FreezeRecorder.shared.isRunning { FreezeRecorder.shared.note(freezeSnapshot) }
    }

    func showFreezeLog() {
        let log = FreezeRecorder.shared.log
        guard FileManager.default.fileExists(atPath: log.path) else { banner = "No freezes recorded on this Mac."; return }
        if !AppFlavor.isTesting { NSWorkspace.shared.activateFileViewerSelecting([log]) }
    }
}
