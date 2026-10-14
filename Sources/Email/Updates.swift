import SwiftUI
import Sparkle

/// Over-the-air updates via Sparkle. Only release builds have a feed URL; dev and demo builds skip it.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    let enabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    private let controller: SPUStandardUpdaterController?
    @Published var canCheck = false
    private var observer: NSKeyValueObservation?

    private init() {
        controller = enabled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        observer = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            let v = u.canCheckForUpdates
            Task { @MainActor in self?.canCheck = v }
        }
    }

    func check() { controller?.checkForUpdates(nil) }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}
