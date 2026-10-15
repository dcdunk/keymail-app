import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

@main
struct EmailApp: App {
    @StateObject private var store = AppStore()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Keymail") {
            RootView().environmentObject(store).environmentObject(store.calendar)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear { store.start(); NSApp.activate(ignoringOtherApps: true) }
        }
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
