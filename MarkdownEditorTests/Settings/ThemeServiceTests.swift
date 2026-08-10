import XCTest
@testable import MarkdownEditor

// ThemeService：三态切换 / 双轨下发 / 持久化（S-015 AC，FR-083/105）
@MainActor
final class ThemeServiceTests: XCTestCase {
    final class MockPreview: PreviewProtocol {
        var themes: [ThemeMode] = []
        var onRenderDone: ((RenderDonePayload) -> Void)?
        var onLinkClicked: ((URL) -> Void)?
        var onErrorOccurred: ((String, String) -> Void)?
        func setContent(_ html: String) {}
        func setTheme(_ mode: ThemeMode) { themes.append(mode) }
        func setConfig(_ config: PreviewConfig) {}   // ⚠️ S-026：协议新增（本类不测，保编译）
        func setViewport(_ scrollTop: Double) {}
        func setViewportSource(_ startLine: Int, _ endLine: Int) {}   // ⚠️ S-032（T1.4）：协议新增（本类不测，保编译）
    }

    private func makeDefaults() -> UserDefaults {
        let name = "theme-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultModeIsSystem() {
        let service = ThemeService(defaults: makeDefaults())
        XCTAssertEqual(service.mode, .system, "FR-105 默认跟随系统")
    }

    func testSelectThreeModesDualTrack() {
        let preview = MockPreview()
        var editorModes: [ThemeMode] = []
        let service = ThemeService(preview: preview,
                                   editorSink: { editorModes.append($0) },
                                   defaults: makeDefaults())
        service.select(.light)
        XCTAssertEqual(preview.themes.last, .light)
        XCTAssertEqual(editorModes.last, .light, "双轨同步下发（AD-10 Rule）")
        service.select(.dark)
        XCTAssertEqual(preview.themes.last, .dark)
        service.select(.system)
        XCTAssertEqual(preview.themes.last, ThemeService.systemMode(), "system 解析为 effective")
    }

    func testPersistence() {
        let defaults = makeDefaults()
        let service = ThemeService(defaults: defaults)
        service.select(.dark)
        let reloaded = ThemeService(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .dark, "FR-105 默认主题持久化，重启保留")
    }

    func testInitAppliesInitialState() {
        let preview = MockPreview()
        var editorModes: [ThemeMode] = []
        let service = ThemeService(preview: preview,
                                   editorSink: { editorModes.append($0) },
                                   defaults: makeDefaults())
        XCTAssertEqual(editorModes, [service.effectiveMode], "init 即双轨下发初始状态（FR-105/AD-10）")
        XCTAssertEqual(preview.themes, [service.effectiveMode])
    }
}
