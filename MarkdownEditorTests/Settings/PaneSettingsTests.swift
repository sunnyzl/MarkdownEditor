import XCTest
@testable import MarkdownEditor

// PaneSettings：默认值 / rawValue round-trip / 持久化 / 非法值容错（S-028 AC；FR-106）
@MainActor
final class PaneSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "pane-settings-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsSplit() {
        let s = PaneSettings(defaults: makeDefaults())
        XCTAssertEqual(s.paneMode, .split, "默认分栏（现状行为）")
    }

    func testSetPaneModePersists() {
        let defaults = makeDefaults()
        let s = PaneSettings(defaults: defaults)
        s.setPaneMode(.editorOnly)
        XCTAssertEqual(s.paneMode, .editorOnly)
        let reloaded = PaneSettings(defaults: defaults)
        XCTAssertEqual(reloaded.paneMode, .editorOnly, "重启保留（UserDefaults 持久化）")
    }

    func testCorruptStoredValueFallsBackToSplit() {
        let defaults = makeDefaults()
        defaults.set("bogus", forKey: PaneSettings.Key.paneMode)
        let s = PaneSettings(defaults: defaults)
        XCTAssertEqual(s.paneMode, .split, "手改 defaults 非法值回落 split")
    }

    func testRawValuesRoundTrip() {
        // 三态 rawValue 完整闭环（与 PaneModeTests 互补：此处验证 PaneSettings 读取面）
        for mode in PaneMode.allCases {
            XCTAssertEqual(PaneMode(rawValue: mode.rawValue), mode, "rawValue round-trip")
        }
    }
}
