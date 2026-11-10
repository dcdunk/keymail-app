import XCTest
@testable import Email

/// Double-clicking the top of the window follows System Settings → Desktop & Dock.
final class TitleBarTests: XCTestCase {
    func testDoubleClickFollowsTheSystemSetting() {
        XCTAssertEqual(TitleBarDoubleClick.from(action: "Fill", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.from(action: "Maximize", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.from(action: "Zoom", legacyMinimize: false), .zoom)
        XCTAssertEqual(TitleBarDoubleClick.from(action: "Minimize", legacyMinimize: false), .minimize)
        XCTAssertEqual(TitleBarDoubleClick.from(action: "None", legacyMinimize: false), .nothing)
        XCTAssertEqual(TitleBarDoubleClick.from(action: nil, legacyMinimize: false), .zoom, "never changed: macOS zooms")
        XCTAssertEqual(TitleBarDoubleClick.from(action: nil, legacyMinimize: true), .minimize, "the older minimize setting")
    }
}
