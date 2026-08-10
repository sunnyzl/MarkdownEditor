import XCTest
@testable import MarkdownEditor

// PaneMode：三模式循环切换纯函数（遗留 #4，批次 2；S-022）
// Pure enum, no isolation requirement, so no @MainActor needed
final class PaneModeTests: XCTestCase {
    func testNextCyclesThroughModes() {
        XCTAssertEqual(PaneMode.editorOnly.next, .previewOnly)
        XCTAssertEqual(PaneMode.previewOnly.next, .split)
        XCTAssertEqual(PaneMode.split.next, .editorOnly)
    }

    func testFullCycleCloses() {
        var mode = PaneMode.editorOnly
        for _ in 0..<3 { mode = mode.next }
        XCTAssertEqual(mode, .editorOnly, "三模式循环闭合（editorOnly → previewOnly → split → editorOnly）")
    }

    func testToolbarIconMapping() {
        XCTAssertEqual(PaneMode.editorOnly.toolbarIcon, "sidebar.left")
        XCTAssertEqual(PaneMode.previewOnly.toolbarIcon, "sidebar.right")
        XCTAssertEqual(PaneMode.split.toolbarIcon, "rectangle.split.2x1")
    }

    // ⚠️ S-028（FR-106）追加：String rawValue 契约（PaneSettings 持久化读取面）

    func testRawValuesMatchPersistenceKeys() {
        XCTAssertEqual(PaneMode.editorOnly.rawValue, "editorOnly")
        XCTAssertEqual(PaneMode.previewOnly.rawValue, "previewOnly")
        XCTAssertEqual(PaneMode.split.rawValue, "split")
    }

    func testInitFromRawValueRoundTrip() {
        XCTAssertEqual(PaneMode(rawValue: "split"), .split)
        XCTAssertEqual(PaneMode(rawValue: "editorOnly"), .editorOnly)
        XCTAssertEqual(PaneMode(rawValue: "previewOnly"), .previewOnly)
        XCTAssertNil(PaneMode(rawValue: "bogus"), "非法值 nil（PaneSettings 回落 .split）")
    }
}
