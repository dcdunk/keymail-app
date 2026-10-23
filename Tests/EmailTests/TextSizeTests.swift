import XCTest
import SwiftUI
@testable import Email

final class TextSizeTests: XCTestCase {
    func testStepWalksTheSizesAndStopsAtTheEnds() {
        let d = UserDefaults.standard, saved = d.object(forKey: "textScale")
        defer { d.set(saved, forKey: "textScale") }
        d.removeObject(forKey: "textScale")
        XCTAssertEqual(Font.scale, 1)                       // unset means default
        Font.step(1); XCTAssertEqual(Font.scale, 1.15)
        for _ in 0..<10 { Font.step(1) }; XCTAssertEqual(Font.scale, 1.5)
        for _ in 0..<10 { Font.step(-1) }; XCTAssertEqual(Font.scale, 0.9)
    }
}

@MainActor
final class AccountColorTests: XCTestCase {
    func testEachAccountGetsItsOwnStableColor() {
        let store = AppStore()
        store.state.accounts = ["a@gmail.com", "b@pga.com", "c@icloud.com"]
        let colors = store.state.accounts.map(store.accountColor)
        XCTAssertEqual(Set(colors.map { "\($0)" }).count, 3, "three accounts, three colors")
        store.state.accounts.append("d@outlook.com")
        XCTAssertEqual(store.state.accounts.prefix(3).map(store.accountColor), colors, "adding an account doesn't repaint the others")
    }
    func testPickedColorWinsAndIsForgottenOnRemove() {
        let store = AppStore()
        store.state.accounts = ["a@gmail.com", "b@pga.com"]
        store.state.accountColors["b@pga.com"] = 4
        XCTAssertEqual(store.accountColorIndex("b@pga.com"), 4)
        XCTAssertEqual(store.accountColor("b@pga.com"), AppStore.accountPalette[4])
        store.state.accountColors["a@gmail.com"] = 99   // out of range (palette shrank): falls back, no crash
        XCTAssertEqual(store.accountColorIndex("a@gmail.com"), 0)
        let saved = try! JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(store.state))
        XCTAssertEqual(saved.accountColors["b@pga.com"], 4, "the pick survives a relaunch")
        store.state.forget("b@pga.com")
        XCTAssertNil(store.state.accountColors["b@pga.com"], "removing the account forgets its color")
    }
}
