import XCTest
@testable import Email

final class WindowOpacityTests: XCTestCase {
    func testTintNeverDropsBelowFloorAndReachesOpaque() {
        XCTAssertEqual(WindowOpacity.tint(0.2), 0.15, accuracy: 1e-9)   // slider minimum keeps 15%
        XCTAssertEqual(WindowOpacity.tint(0), 0.15, accuracy: 1e-9)     // out-of-range clamps
        XCTAssertEqual(WindowOpacity.tint(0.6), 0.575, accuracy: 1e-9)
        XCTAssertEqual(WindowOpacity.tint(1), 1, accuracy: 1e-9)
    }
}

final class WindowBlurTests: XCTestCase {
    // If this fails, macOS dropped the private blur: the app falls back to the grey AppKit material.
    func testPrivateWindowBlurIsFound() { XCTAssertTrue(windowBlurAvailable) }
}
