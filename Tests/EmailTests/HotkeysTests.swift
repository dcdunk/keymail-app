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
