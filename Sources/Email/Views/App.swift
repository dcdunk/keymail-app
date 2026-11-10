import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

/// Quitting (or an update relaunching Keymail) while an email waits out Undo Send sends it first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = AppStore.current, !store.pendingSends.isEmpty else { return .terminateNow }
        Task { @MainActor in
            await store.flushPendingSends()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { AppStore.current?.flushState() }
}

@main
struct EmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // A closed socket or pipe (an AI tool that quit mid-request, curl stopping early) must be an error, not a crash.
        signal(SIGPIPE, SIG_IGN)
    }
    var body: some Scene {
        WindowGroup("Keymail") {
            RootView().environmentObject(store).environmentObject(store.calendar)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear { store.start(); NSApp.activate(ignoringOtherApps: true) }
                // Email links open a draft in this window; without this, macOS opened a second Keymail window.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in store.compose(mailto: url) }
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.settingsOpen ? (store.settingsOpen = false) : store.openSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") { Font.step(1) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { Font.step(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("Default Text Size") { UserDefaults.standard.set(1.0, forKey: "textScale") }.keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Keymail") { UserDefaults.standard.set("about", forKey: "settingsTab"); store.openSettings() }
                if Updates.shared.enabled { Button("Check for Updates…") { Updates.shared.check() } }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("writingToolsButton") private var writingToolsButton = false
    @AppStorage("textScale") private var textScale = 1.0
    var body: some View {
        Group {
            if !store.state.onboarded || store.state.accounts.isEmpty { OnboardingView() }
            else { MainView() }
        }
        .glassButtons()
        // The hidden title bar no longer answers a double-click; this strip does, the way the person set it up.
        .overlay(alignment: .top) { TitleBarStrip().frame(height: 28).ignoresSafeArea() }
        .modifier(WritingToolsSetting(on: writingToolsButton))
        .font(.scaled(.body))
        .id(textScale) // fonts read the size when drawn, so a new size redraws everything
    }
}

/// Settings → General → "Show Apple's Writing Tools button while typing", for every text field in the app
/// (search, settings, compose fields), not only the email body.
struct WritingToolsSetting: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.writingToolsBehavior(on ? .automatic : .disabled) } else { content }
    }
}

/// What double-clicking a title bar does, from System Settings → Desktop & Dock ("Fill", "Zoom", "Minimize", "None").
enum TitleBarDoubleClick: Equatable { case zoom, minimize, nothing
    static func from(action: String?, legacyMinimize: Bool) -> TitleBarDoubleClick {
        switch action?.lowercased() {
        case "minimize": return .minimize
        case "none": return .nothing
        case nil: return legacyMinimize ? .minimize : .zoom   // never changed: macOS zooms
        default: return .zoom   // "Fill", "Maximize", "Zoom"
        }
    }
    static var current: TitleBarDoubleClick {
        let g = UserDefaults(suiteName: UserDefaults.globalDomain)
        return from(action: g?.string(forKey: "AppleActionOnDoubleClick"), legacyMinimize: g?.bool(forKey: "AppleMiniaturizeOnDoubleClick") ?? false)
    }
}

/// An invisible strip along the top edge: drag it to move the window, double-click it to zoom (or minimize).
/// ponytail: "Fill" zooms the window to fill the screen, which looks the same; macOS has no public call for its own Fill.
private struct TitleBarStrip: NSViewRepresentable {
    final class Strip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            guard e.clickCount == 2, let w = window else { window?.performDrag(with: e); return }
            switch TitleBarDoubleClick.current {
            case .zoom: w.zoom(nil)
            case .minimize: w.miniaturize(nil)
            case .nothing: break
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Strip() }
    func updateNSView(_ v: NSView, context: Context) {}
}
