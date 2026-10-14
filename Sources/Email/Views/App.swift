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
        WindowGroup("Lightmail") {
            RootView().environmentObject(store).environmentObject(store.calendar)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear { store.start(); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lightmail") { UserDefaults.standard.set("about", forKey: "settingsTab"); store.openSettings() }
                if Updates.shared.enabled { Button("Check for Updates…") { Updates.shared.check() } }
            }
        }
        Settings { SettingsView().environmentObject(store).environmentObject(store.calendar) }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Group {
            if !store.state.onboarded || store.state.accounts.isEmpty { OnboardingView() }
            else { MainView() }
        }
        .glassButtons()
    }
}
