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
