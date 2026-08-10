import XCTest
@testable import MarkdownEditor

// PreviewSettings：默认值 / 持久化 / 跟随解析 / 非法值容错（S-026 AC；FR-035/046）
@MainActor
final class PreviewSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "preview-settings-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaults() {
        let s = PreviewSettings(defaults: makeDefaults())
        XCTAssertEqual(s.mermaidTheme, PreviewSettings.followThemeMarker, "默认跟随（FR-046 默认行为保持）")
        XCTAssertTrue(s.katexSingleDollar, "单 $ 默认开（FR-035 现状行为不变）")
    }

    func testSetMermaidThemePersists() {
        let defaults = makeDefaults()
        let s = PreviewSettings(defaults: defaults)
        s.setMermaidTheme("forest")
        XCTAssertEqual(s.mermaidTheme, "forest")
        let reloaded = PreviewSettings(defaults: defaults)
        XCTAssertEqual(reloaded.mermaidTheme, "forest", "重启保留（UserDefaults 持久化）")
    }

    func testSetKatexSingleDollarPersists() {
        let defaults = makeDefaults()
        let s = PreviewSettings(defaults: defaults)
        s.setKatexSingleDollar(false)
        XCTAssertFalse(s.katexSingleDollar)
        let reloaded = PreviewSettings(defaults: defaults)
        XCTAssertFalse(reloaded.katexSingleDollar, "重启保留")
    }

    func testInvalidMermaidThemeIgnored() {
        let s = PreviewSettings(defaults: makeDefaults())
        s.setMermaidTheme("rainbow")
        XCTAssertEqual(s.mermaidTheme, PreviewSettings.followThemeMarker, "非法值忽略（仅四选项 + 跟随）")
    }

    func testCorruptStoredValueFallsBackToFollow() {
        let defaults = makeDefaults()
        defaults.set("rainbow", forKey: PreviewSettings.Key.mermaidTheme)
        let s = PreviewSettings(defaults: defaults)
        XCTAssertEqual(s.mermaidTheme, PreviewSettings.followThemeMarker, "手改 defaults 非法值回退跟随")
    }

    func testEffectiveThemeExplicitValue() {
        let s = PreviewSettings(defaults: makeDefaults())
        s.setMermaidTheme("neutral")
        XCTAssertEqual(s.effectiveMermaidTheme(), "neutral", "显式四选项原值生效")
    }

    func testEffectiveThemeFollowResolvesSystem() {
        let s = PreviewSettings(defaults: makeDefaults())
        // 跟随解析与 ThemeService.systemMode 联动（dark 系统 → dark，否则 default）
        let expected = ThemeService.systemMode() == .dark ? "dark" : "default"
        XCTAssertEqual(s.effectiveMermaidTheme(), expected)
    }

    func testExplicitFalseStoredDistinctFromUnset() {
        let defaults = makeDefaults()
        let s = PreviewSettings(defaults: defaults)
        s.setKatexSingleDollar(false)
        XCTAssertFalse(PreviewSettings(defaults: defaults).katexSingleDollar, "显式 false 与未设置区分（object(forKey:) 语义）")
    }

    // ⚠️ S-028 追加：onChange 回调（值实际变更才触发；同值/非法值 guard 短路不触发）

    func testOnChangeFiresOnMermaidThemeChange() {
        let s = PreviewSettings(defaults: makeDefaults())
        var fired = 0
        s.onChange = { _ in fired += 1 }
        s.setMermaidTheme("forest")
        XCTAssertEqual(fired, 1, "值变更 → onChange 触发")
        s.setMermaidTheme("forest")
        XCTAssertEqual(fired, 1, "同值不触发（guard 短路）")
        s.setMermaidTheme("rainbow")
        XCTAssertEqual(fired, 1, "非法值不触发（guard 短路）")
    }

    func testOnChangeFiresOnSingleDollarChange() {
        let s = PreviewSettings(defaults: makeDefaults())
        var fired = 0
        s.onChange = { _ in fired += 1 }
        s.setKatexSingleDollar(false)
        XCTAssertEqual(fired, 1)
        s.setKatexSingleDollar(false)
        XCTAssertEqual(fired, 1, "同值不触发")
    }
}
