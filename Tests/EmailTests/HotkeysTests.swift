import XCTest
import AppKit
@testable import Email

final class HotkeysTests: XCTestCase {
    func testRemapMovesTheCommandAndFreesNothingElse() {
        let o = ["c": "n"] // compose moved from C to N
        XCTAssertEqual(Hotkeys.resolve("n", o), "c")   // N now composes
        XCTAssertEqual(Hotkeys.resolve("c", o), "")    // C no longer composes
        XCTAssertEqual(Hotkeys.resolve("r", o), "r")   // untouched commands keep their key
        XCTAssertEqual(Hotkeys.resolve("1", o), "1")   // unrelated keys pass through
        XCTAssertEqual(Hotkeys.owner(of: "n", o), "c")
        XCTAssertNil(Hotkeys.owner(of: "c", o))
    }
    func testSwappedKeys() {
        let o = ["e": "s", "s": "e"]
        XCTAssertEqual(Hotkeys.resolve("s", o), "e")
        XCTAssertEqual(Hotkeys.resolve("e", o), "s")
    }
    func testDefaultKeysAreUnique() {
        XCTAssertEqual(Set(Hotkeys.commands.map(\.key)).count, Hotkeys.commands.count)
    }
}

final class BrandLogoTests: XCTestCase {
    func testEveryLogoParses() {
        for id in AIProvider.all.map(\.id) + ["gmail", "icloud", "google"] {
            let svg = BrandLogo.logos[id]?.0
            XCTAssertNotNil(svg, id)
            XCTAssertNotNil(NSImage(data: Data((svg ?? "").utf8)), id)
        }
    }
}

final class AIModelTests: XCTestCase {
    func testEveryProviderOffersModelsAndPassesThePickedOneToItsCLI() {
        for p in AIProvider.all {
            XCTAssertFalse(p.models.isEmpty, p.id)
            XCTAssertEqual(Set(p.models.map(\.id)).count, p.models.count, p.id)
            let m = p.models[0].id, args = p.args(m)
            let flag = args.firstIndex(of: m).map { args[$0 - 1] }
            XCTAssertTrue(flag == "--model" || flag == "-m", "\(p.id): \(args)")
            XCTAssertFalse(p.args(nil).contains { $0 == "--model" || $0 == "-m" }, p.id) // Default = no flag
        }
    }
}

final class SettingsGrantTests: XCTestCase {
    let ok: Set<String> = ["https://www.googleapis.com/auth/gmail.modify", GoogleAuth.settingsScope]
    func testWrongAccountPicked() {
        XCTAssertTrue(settingsGrantOutcome(requested: "a@gmail.com", signedIn: "b@gmail.com", scopes: ok)!.contains("not a@gmail.com"))
    }
    func testBoxLeftUnticked() {
        XCTAssertTrue(settingsGrantOutcome(requested: "a@gmail.com", signedIn: "A@gmail.com", scopes: ["https://www.googleapis.com/auth/gmail.modify"])!.contains("tick"))
    }
    func testGranted() {
        XCTAssertTrue(settingsGrantOutcome(requested: "a@gmail.com", signedIn: "a@gmail.com", scopes: ok)!.contains("granted"))
    }
}

final class RecoveryTests: XCTestCase {
    func testPicksNewestSetAsideCopyPerFile() {
        let r = setAsideToRestore(["state.json", "state.json.unreadable-100", "state.json.unreadable-200", "cache2.json.unreadable-150",
                                   "state.json.restored-50", "google_client.json", "x.unencrypted-9"])
        XCTAssertEqual(r.map(\.0), ["cache2.json.unreadable-150", "state.json.unreadable-200"])
        XCTAssertEqual(r.map(\.1), ["cache2.json", "state.json"])
    }
}

final class SignatureColorTests: XCTestCase {
    func attr(_ html: String) -> NSAttributedString {
        try! NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    }
    func color(_ s: NSAttributedString, at i: Int) -> NSColor? { s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }

    func testBlackFollowsTheScreenButIsSavedBlack() {
        let original = attr(#"<p>Thank you, Danny</p><p style="color:#cc0000">PGA</p>"#)
        let screen = SignatureColors.forScreen(original)
        XCTAssertEqual(color(screen, at: 0), .textColor)                       // follows light/dark on screen
        let red = color(screen, at: screen.length - 2)?.usingColorSpace(.sRGB)
        XCTAssertEqual(red?.redComponent ?? 0, 0.8, accuracy: 0.02)              // a chosen colour is untouched
        let saved = SignatureColors.forSending(screen)
        XCTAssertTrue(SignatureColors.isBlack(color(saved, at: 0)!))           // recipients get black, never white
        // Saved even while the app is in dark mode: the HTML must not carry light text.
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let html = RichTextEditor.Coordinator.bodyHTML(saved).lowercased()
        XCTAssertFalse(html.contains("#ffffff") || html.contains("255, 255, 255") || html.contains("#fff;"), html)
    }
}
