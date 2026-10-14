import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import EmailCore
import EventKit
import QuickLook

// MARK: Remote content blocking

enum RemoteContent {
    /// A WebKit rule that blocks every http(s) load inside an email (images, fonts, tracking pixels).
    @MainActor static var blocker: WKContentRuleList?
    @MainActor static func prepare() {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "email-block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#) { list, _ in
            Task { @MainActor in blocker = list }
        }
    }
}

extension UserDefaults {
    func bool(forKey k: String, default d: Bool) -> Bool { object(forKey: k) == nil ? d : bool(forKey: k) }
}
