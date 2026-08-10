import XCTest
import AppKit
@testable import MarkdownEditor

// FontSettings：默认值 / 持久化 / 非法值容错 / 预览字体派生（S-027 AC；FR-086/101）
@MainActor
final class FontSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "font-settings-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaults() {
        let s = FontSettings(defaults: makeDefaults())
        XCTAssertEqual(s.fontName, "", "默认无字体名（回落默认等宽）")
        XCTAssertEqual(s.pointSize, FontSettings.defaultPointSize, "默认字号 14（保持现状）")
        XCTAssertEqual(s.font, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                       "font 回落 monospacedSystemFont(14)（现状行为不变）")
    }

    func testSetFontPersists() {
        let defaults = makeDefaults()
        let s = FontSettings(defaults: defaults)
        let font = NSFont(name: "Menlo", size: 16)!
        s.setFont(font)
        // NSFont.fontName 返回 PostScript 名（"Menlo-Regular"）——存储即该语义
        XCTAssertEqual(s.fontName, font.fontName)
        XCTAssertEqual(s.pointSize, 16)
        let reloaded = FontSettings(defaults: defaults)
        XCTAssertEqual(reloaded.fontName, font.fontName, "重启保留（UserDefaults 持久化）")
        XCTAssertEqual(reloaded.pointSize, 16)
    }

    func testInvalidPointSizeIgnored() {
        let s = FontSettings(defaults: makeDefaults())
        // NSFont 无法构造 0pt 字体（size: 0 回落默认 12pt）→ 下限分支为防御代码；
        // 上限用可构造的 300pt 验证 ≤288 校验
        s.setFont(NSFont.systemFont(ofSize: 300))
        XCTAssertEqual(s.pointSize, FontSettings.defaultPointSize, "超上限字号忽略（≤288 校验）")
        s.setFont(NSFont(name: "Menlo", size: 16)!)
        XCTAssertEqual(s.pointSize, 16, "合法字号可设置")
        s.setFont(NSFont(name: "Menlo", size: 300)!)
        XCTAssertEqual(s.pointSize, 16, "设置后超上限字号忽略（保持当前值）")
    }

    func testCorruptStoredPointSizeFallsBack() {
        let defaults = makeDefaults()
        defaults.set(-5.0, forKey: FontSettings.Key.pointSize)
        let s = FontSettings(defaults: defaults)
        XCTAssertEqual(s.pointSize, FontSettings.defaultPointSize, "手改 defaults 非法值回落默认字号")
    }

    func testNamedFontResolves() {
        let defaults = makeDefaults()
        defaults.set("Menlo", forKey: FontSettings.Key.pointSize)  // 无关写入（防误用）
        defaults.set("Menlo", forKey: FontSettings.Key.fontName)
        let s = FontSettings(defaults: defaults)
        // 存储 "Menlo" 可解析为 Menlo 字体；NSFont.fontName 返回 PostScript 名
        XCTAssertEqual(s.font.fontName, "Menlo-Regular", "存储字体名可解析")
    }

    func testEmptyNameFallsBackToMonospaced() {
        let s = FontSettings(defaults: makeDefaults())
        XCTAssertEqual(s.font, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                       "空字体名回落默认等宽")
    }

    func testPreviewBodyFollowsFontName() {
        let s = FontSettings(defaults: makeDefaults())
        XCTAssertEqual(s.previewBodyFontFamily, FontSettings.defaultBodyFontFamily, "未设置 → 系统默认栈")
        s.setFont(NSFont(name: "Menlo", size: 16)!)
        // 正文族 = 编辑器字体 PostScript 名 + 回退栈（fontName 为空时才是系统默认栈）
        XCTAssertTrue(s.previewBodyFontFamily.hasPrefix("Menlo-Regular,"), "设置后正文族 = 编辑器字体 + 回退栈")
    }

    func testPreviewCodeStaysMonospace() {
        let s = FontSettings(defaults: makeDefaults())
        s.setFont(NSFont(name: "Menlo", size: 16)!)
        XCTAssertEqual(s.previewCodeFontFamily, FontSettings.defaultCodeFontFamily,
                       "代码字体恒等宽栈（代码块可读性优先；独立配置 → Epic-5）")
    }
}
