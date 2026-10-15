import XCTest
@testable import Email

final class SettingsSearchTests: XCTestCase {
    func testFindsPagesAndSingleSettings() {
        let hits = SettingsPanel.search("undo")
        XCTAssertEqual(hits.first?.section.id, "general")                       // keyword match on the page
        XCTAssertTrue(hits.contains { $0.item == "Undo send" })                 // and the row itself
        XCTAssertTrue(SettingsPanel.search("opacity").contains { $0.item == "Email card opacity" })
        XCTAssertEqual(SettingsPanel.search("").count, SettingsPanel.sections.count)
        XCTAssertTrue(SettingsPanel.search("zzz").isEmpty)
    }

    func testGroupsKeepSidebarOrder() {
        XCTAssertEqual(SettingsPanel.groups.flatMap { $0.sections.map(\.id) }, SettingsPanel.sections.map(\.id))
        XCTAssertEqual(Set(SettingsPanel.sections.map(\.id)).count, SettingsPanel.sections.count)
    }

    /// Every searchable setting must have a row to jump to, or search would land on the page and highlight nothing.
    func testEverySearchableSettingHasAnAnchor() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/Email/Views")
        let source = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for item in SettingsPanel.sections.flatMap(\.items) {
            let direct = source.contains(".settingAnchor(\"\(item)\")")
            let viaSlider = source.contains("opacitySlider(\"\(item)\"")
            XCTAssertTrue(direct || viaSlider, "No .settingAnchor for \(item)")
        }
    }
}
