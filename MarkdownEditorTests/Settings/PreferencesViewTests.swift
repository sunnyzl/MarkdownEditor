import XCTest
import AppKit
@testable import MarkdownEditor

// SettingsApplier：写 defaults + 广播变更键（S-028；post 闭包注入 Mock 观察者——
// 设计测试策略"设置通知：广播 → 订阅端行为断言（Mock 观察者）"）
// SettingsApplier: writes defaults + broadcasts changed keys (S-028; post closure
// injects a Mock observer per the design's notification test strategy)
@MainActor
final class PreferencesViewTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "settings-applier-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// 注入 Mock 观察者：收集广播键集合；设置对象共享同一 defaults 实例（写断言用）
    /// Injects a Mock observer that collects posted key-sets; settings objects share
    /// the same defaults instance so write assertions observe the same store.
    private func makeApplier(defaults: UserDefaults) -> (SettingsApplier, () -> [[String]]) {
        var posted: [[String]] = []
        let applier = SettingsApplier(
            font: FontSettings(defaults: defaults),
            preview: PreviewSettings(defaults: defaults),
            pane: PaneSettings(defaults: defaults),
            defaults: defaults,
            post: { keys in posted.append(keys) })
        return (applier, { posted })
    }

    func testSetEditorFontWritesDefaultsAndBroadcastsFontKey() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setEditorFont(NSFont(name: "Menlo", size: 18)!)
        // ⚠️ NSFont.fontName 返回 PostScript 名（"Menlo" → "Menlo-Regular"，批 1 实证先例）
        XCTAssertEqual(FontSettings(defaults: defaults).fontName, "Menlo-Regular", "写 defaults（fontName）")
        XCTAssertEqual(FontSettings(defaults: defaults).pointSize, 18, "写 defaults（pointSize）")
        XCTAssertEqual(posted(), [[SettingsChangeKey.font]], "广播 font 键")
    }

    func testSetMermaidThemeWritesAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setMermaidTheme("forest")
        XCTAssertEqual(PreviewSettings(defaults: defaults).mermaidTheme, "forest")
        XCTAssertEqual(posted(), [[SettingsChangeKey.mermaidTheme]])
    }

    func testSetKatexSingleDollarWritesAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setKatexSingleDollar(false)
        XCTAssertFalse(PreviewSettings(defaults: defaults).katexSingleDollar)
        XCTAssertEqual(posted(), [[SettingsChangeKey.katexSingleDollar]])
    }

    func testSetHighlightEnabledWritesDefaultsAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setHighlightEnabled(false)
        XCTAssertFalse(SyntaxHighlighter.isEnabled(defaults: defaults), "写 syntaxHighlightEnabled")
        XCTAssertEqual(posted(), [[SettingsChangeKey.highlightEnabled]])
    }

    func testSetLineNumbersEnabledWritesDefaultsAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setLineNumbersEnabled(true)
        XCTAssertTrue(LineNumberPreference.isEnabled(defaults: defaults), "写 lineNumbersEnabled")
        XCTAssertEqual(posted(), [[SettingsChangeKey.lineNumbersEnabled]])
        XCTAssertFalse(LineNumberPreference.isEnabled(defaults: makeDefaults()), "默认关（未设置 → false）")
    }

    func testSetPaneModeWritesAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setPaneMode(.editorOnly)
        XCTAssertEqual(PaneSettings(defaults: defaults).paneMode, .editorOnly)
        XCTAssertEqual(posted(), [[SettingsChangeKey.paneMode]])
    }

    // ── T3.5（FR-087/FR-104/FR-007）：状态栏 + debounce Slider + 自动缩进/括号配对 ──

    func testSetStatusBarEnabledWritesDefaultsAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setStatusBarEnabled(false)
        XCTAssertEqual(defaults.object(forKey: SettingsChangeKey.statusBarEnabled) as? Bool, false,
                       "写 statusBarEnabled（MainApp 读同键）")
        XCTAssertEqual(posted(), [[SettingsChangeKey.statusBarEnabled]], "广播 statusBarEnabled 键")
    }

    func testSetAutoIndentEnabledWritesDefaultsAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setAutoIndentEnabled(false)
        XCTAssertFalse(AutoIndent.isEnabled(defaults: defaults), "写 autoIndentEnabled（批次 2 同键）")
        XCTAssertEqual(posted(), [[SettingsChangeKey.autoIndentEnabled]])
        XCTAssertTrue(AutoIndent.isEnabled(defaults: makeDefaults()), "默认开启（未设置 → true）")
    }

    func testSetAutoPairEnabledWritesDefaultsAndBroadcasts() {
        let defaults = makeDefaults()
        let (applier, posted) = makeApplier(defaults: defaults)
        applier.setAutoPairEnabled(false)
        XCTAssertFalse(AutoPair.isEnabled(defaults: defaults), "写 autoPairEnabled（批次 2 同键）")
        XCTAssertEqual(posted(), [[SettingsChangeKey.autoPairEnabled]])
        XCTAssertTrue(AutoPair.isEnabled(defaults: makeDefaults()), "默认开启（未设置 → true）")
    }

    func testDefaultPostBroadcastsNotification() {
        // 生产默认广播出口 = NotificationCenter.post（object: nil + changedKeys userInfo）
        // Production default post outlet = NotificationCenter.post (object: nil + changedKeys userInfo)
        let defaults = makeDefaults()
        let applier = SettingsApplier(
            font: FontSettings(defaults: defaults),
            preview: PreviewSettings(defaults: defaults),
            pane: PaneSettings(defaults: defaults),
            defaults: defaults)
        var received: [String]?
        let token = NotificationCenter.default.addObserver(
            forName: .editorSettingsDidChange, object: nil, queue: .main) { note in
            received = note.userInfo?[SettingsNotificationUserInfoKey.changedKeys] as? [String]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        applier.setHighlightEnabled(false)
        XCTAssertEqual(received, [SettingsChangeKey.highlightEnabled], "生产默认出口 = NotificationCenter 广播")
    }

    // ⚠️ P1 后置（FR-065 录制）：UI 数据管道——录制写入（ShortcutManager.record）→
    // conflictMessage 冲突提示（面板展示 note 的数据源；NSEvent 捕获本身手动验收）
    func testRecordingWriteThenConflictMessageDetected() {
        let defaults = makeDefaults()
        // 模拟 UI 录制路径：按键捕获后调用 ShortcutManager.record（T2.3 startRecording 内部）
        ShortcutManager.record("s", modifiers: [.command], for: .bold, defaults: defaults)
        XCTAssertEqual(ShortcutManager.storedKey(for: .bold, defaults: defaults), "s", "录制已落盘")
        XCTAssertEqual(ShortcutManager.conflictMessage(for: .bold, defaults: defaults),
                       "⌘S 已被「保存」占用，无法绑定",
                       "录制 Cmd+S → 面板展示冲突提示（保存占用）")
    }

    // ⚠️ 收尾批次（标签刷新）追加：静态推导单一事实源——实例与静态同源（T2.3 标签 @AppStorage 复用）
    func testPreviewBodyFontFamilyStaticMatchesInstanceAndDefault() {
        let defaults = makeDefaults()
        // 未设置 → 默认栈（实例与静态一致）
        XCTAssertEqual(FontSettings.previewBodyFontFamily(for: ""),
                       FontSettings.defaultBodyFontFamily, "空字体名 → 默认栈")
        XCTAssertEqual(FontSettings(defaults: defaults).previewBodyFontFamily,
                       FontSettings.previewBodyFontFamily(for: ""), "实例与静态同源")
        // 已设置 → fontName + 回退栈（实例读存储键，静态读同键值 → 等价）
        defaults.set("Menlo-Regular", forKey: FontSettings.Key.fontName)
        let fs = FontSettings(defaults: defaults)
        XCTAssertEqual(fs.previewBodyFontFamily,
                       FontSettings.previewBodyFontFamily(for: fs.fontName),
                       "实例推导与静态推导同源（标签 @AppStorage 复用静态）")
        XCTAssertEqual(FontSettings.previewBodyFontFamily(for: "Menlo-Regular"),
                       "Menlo-Regular, -apple-system, BlinkMacSystemFont, sans-serif")
    }

    // ⚠️ 收尾批次（清理⑤）追加：@AppStorage 键与 FontSettings 键锁定——键漂移即标签刷新失效
    func testFontSettingsKeysBackAppStorageWiring() {
        XCTAssertEqual(FontSettings.Key.fontName, "editorFontName",
                       "@AppStorage 同键订阅（键漂移 → 标签不刷新）")
        XCTAssertEqual(FontSettings.Key.pointSize, "editorFontPointSize",
                       "pointSize 键锁定（与 FontSettings 存储契约一致）")
    }
}
