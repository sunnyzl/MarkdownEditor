import XCTest
import AppKit
@testable import MarkdownEditor

// MainContentState 命令通道接线（S-020）：keyWindowState 路由的 state 侧——
// shortcutManager → commandExecutor → textView 完整链路（keyWindowState 层依赖 NSApp.keyWindow，
// 由真实窗口环境验收，此处测容器侧分发；MainContentState() 可构造先例：WindowCloseGuardTests）
// Command channel wiring (S-020): state-side of the keyWindowState route — the full
// shortcutManager → commandExecutor → textView chain (keyWindowState layer depends on
// NSApp.keyWindow, accepted in real-window environment; container-side dispatch tested here;
// MainContentState() constructible precedent: WindowCloseGuardTests)
@MainActor
final class MainContentStateTests: XCTestCase {
    /// S-028：suiteName 隔离 defaults（防本机 .standard 存储干扰断言）
    @MainActor
    private func makeDefaults() -> UserDefaults {
        let name = "main-content-state-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testShortcutManagerDispatchesThroughExecutorToTextView() {
        let state = MainContentState()
        let tv = MarkdownTextView()
        tv.string = "hello world"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        state.attachTextView(tv)
        state.shortcutManager.execute(.bold)
        XCTAssertEqual(tv.string, "**hello** world", "菜单路由：shortcutManager → executor → performFormatting")
    }

    // ⚠️ S-028 改造：注入 suiteName 隔离 defaults——本机 .standard 存储了分栏默认时
    // 初始断言会漂移（PaneSettings 注入生效的副作用），隔离后断言确定
    func testTogglePaneCyclesPaneMode() {
        let state = MainContentState(defaults: makeDefaults())
        XCTAssertEqual(state.paneMode, .split, "默认 split 模式（未设置回落）")
        state.shortcutManager.execute(.togglePane)
        XCTAssertEqual(state.paneMode, .editorOnly, "split → editorOnly（PaneMode.next 语义）")
        state.shortcutManager.execute(.togglePane)
        XCTAssertEqual(state.paneMode, .previewOnly)
        state.shortcutManager.execute(.togglePane)
        XCTAssertEqual(state.paneMode, .split)
    }

    func testToolbarChannelExecutesInlineCode() {
        // 工具栏按钮经同一 shortcutManager 通道（FR-084 复用，设计 §8 定稿）
        // Toolbar buttons share the same shortcutManager channel (FR-084 reuse, §8 final)
        let state = MainContentState()
        let tv = MarkdownTextView()
        tv.string = "let x = 1"
        tv.setSelectedRange(NSRange(location: 4, length: 1))   // 选 "x"
        state.attachTextView(tv)
        state.shortcutManager.execute(.inlineCode)
        XCTAssertEqual(tv.string, "let `x` = 1")
    }

    func testExecuteBeforeTextViewAttachNoCrash() {
        // 视图树未挂接（无 textView）时菜单命令静默
        // Menu commands are silent when no textView is attached (view tree not mounted)
        let state = MainContentState()
        state.shortcutManager.execute(.bold)
        state.shortcutManager.execute(.table)
    }

    // ⚠️ S-026 追加：init 即下发预览配置（FR-035/046；receivedConfig 为测试确定性证据）
    func testInitSendsPreviewConfig() {
        // ⚠️ 修复：测试不再假设 .standard 无污染（用户运行时可能改过 Mermaid 主题）——
        // 清除相关键后构造，断言基于隔离后的干净状态
        let defaults = makeDefaults()
        defaults.removeObject(forKey: "previewMermaidTheme")
        defaults.removeObject(forKey: "previewKatexSingleDollar")
        let state = MainContentState(defaults: defaults)
        let expected = PreviewConfig(
            mermaidTheme: ThemeService.systemMode() == .dark ? "dark" : "default",
            katexSingleDollar: true)
        XCTAssertEqual(state.previewWebView.receivedConfig, expected, "init 组装并下发 PreviewConfig")
    }

    // ⚠️ S-024 追加：最新编辑文本容器成员（onSelectionDidChange 接线读取面；更新由 body 闭包执行）
    func testLatestEditorTextDefaultsEmpty() {
        let state = MainContentState()
        XCTAssertEqual(state.latestEditorText, "", "初始空文本")
    }

    // ⚠️ S-028 追加：分栏默认从 PaneSettings 注入（FR-106——启动/新窗口生效）

    func testInitReadsPaneModeDefaultFromSettings() {
        let defaults = makeDefaults()
        defaults.set(PaneMode.previewOnly.rawValue, forKey: PaneSettings.Key.paneMode)
        let state = MainContentState(defaults: defaults)
        XCTAssertEqual(state.paneMode, .previewOnly, "init 从 PaneSettings 读默认分栏（FR-106）")
    }

    // ⚠️ S-028 追加：PreviewSettings.onChange → setConfig 重发（补 S-026 仅 init 一次性下发缺口；
    // receivedConfig 为测试确定性证据——MockPreview 记录先例）
    // ⚠️ 适配（批次 B 实测修复）：注入 suiteName 隔离 defaults——本用例 setMermaidTheme 会
    // didSet 落盘，写 .standard 会污染 testInitSendsPreviewConfig 的字面量断言（其依赖
    // "全项目测试均用 suiteName 隔离 defaults，.standard 无污染"）；隔离后测试意图不变
    func testPreviewSettingsChangeResendsConfig() {
        let state = MainContentState(defaults: makeDefaults())
        state.previewSettings.setMermaidTheme("forest")   // setter 触发 onChange → 容器重发
        XCTAssertEqual(state.previewWebView.receivedConfig?.mermaidTheme, "forest",
                       "onChange → setConfig 重发（receivedConfig 记录）")
    }

    // ⚠️ S-028 追加（盲审 #2）：广播路径测试——面板写 defaults + post → 容器观察者
    // 重读 defaults 现读重发（生产实时生效链路：SettingsApplier → 广播 → 容器重读 → setConfig；
    // onChange 路径为测试面——面板独立 PreviewSettings 实例不触发容器 onChange）
    func testSettingsBroadcastResendsConfig() {
        let defaults = makeDefaults()
        let state = MainContentState(defaults: defaults)
        defaults.set("forest", forKey: PreviewSettings.Key.mermaidTheme)
        NotificationCenter.default.post(
            name: .editorSettingsDidChange, object: nil,
            userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.mermaidTheme]])
        XCTAssertEqual(state.previewWebView.receivedConfig?.mermaidTheme, "forest",
                       "广播 mermaidTheme 键 → 容器重读 defaults 重发 setConfig（生产链路）")
    }

    // ⚠️ Epic-5 S-029~S-031 追加：容器接线断言

    @MainActor
    func testRenderDoneUpdatesLastRenderDoneAt() {
        let d = UserDefaults(suiteName: "test.epic5.mcs.\(UUID().uuidString)")!
        let state = MainContentState(defaults: d)
        XCTAssertNil(state.lastRenderDoneAt)
        state.previewWebView.onRenderDone?(RenderDonePayload(status: "ok", error: nil, scrollHeight: 0, elapsed: 1))
        XCTAssertNotNil(state.lastRenderDoneAt, "onRenderDone 闭包维护导出等待锚点（S-031）")
    }

    @MainActor
    func testAttachTextViewWiresFindCoordinator() {
        let d = UserDefaults(suiteName: "test.epic5.mcs.\(UUID().uuidString)")!
        let state = MainContentState(defaults: d)
        let tv = MarkdownTextView(defaults: d)
        state.attachTextView(tv)
        XCTAssertTrue(state.findCoordinator.textView === tv, "查找/替换目标注入（S-029）")
    }

    @MainActor
    func testRecentFilesMenuModelReloadsOnDefaultsChange() {
        let d = UserDefaults(suiteName: "test.epic5.menu.\(UUID().uuidString)")!
        let model = RecentFilesMenuModel(defaults: d)
        XCTAssertTrue(model.urls.isEmpty)
        RecentFiles.record(URL(fileURLWithPath: "/tmp/menu.md"), defaults: d)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: d)
        XCTAssertEqual(model.urls.map(\.path), ["/tmp/menu.md"], "defaults 变更 → 菜单数据源重载（S-030）")
    }

    // ⚠️ T3.2（S-034）：toggleFocusMode 翻转断言——聚焦模式正交标志（@Published 驱动
    // MainWindowView body 重算）；工具栏隐藏依赖 windowRegistry 关联窗口（测试环境无窗口
    // → window 为 nil，工具栏操作静默跳过），此处仅验证翻转语义
    @MainActor
    func testToggleFocusModeFlipsIsFocusMode() {
        let state = MainContentState()
        XCTAssertFalse(state.isFocusMode, "初始非聚焦模式")
        state.toggleFocusMode()
        XCTAssertTrue(state.isFocusMode, "首次调用 → 聚焦模式开启")
        state.toggleFocusMode()
        XCTAssertFalse(state.isFocusMode, "再次调用 → 聚焦模式关闭（翻转语义）")
    }

    // ⚠️ T3.2-fix1（评审 IMPORTANT-2 补测）：FR-087 状态栏默认值覆盖——
    // init 读 defaults（SettingsChangeKey.statusBarEnabled，T3.5 写入端）；未设置回落 true
    @MainActor
    func testInitReadsStatusBarEnabledDefault() {
        let state = MainContentState(defaults: makeDefaults())
        XCTAssertTrue(state.showStatusBar, "未设置 → 默认 true（FR-087 回落）")
        let defaults = makeDefaults()
        defaults.set(false, forKey: SettingsChangeKey.statusBarEnabled)
        let stateDisabled = MainContentState(defaults: defaults)
        XCTAssertFalse(stateDisabled.showStatusBar, "defaults set false → init 读 false")
    }

    // ⚠️ T3.2-fix1（评审 IMPORTANT-2 补测）：广播 statusBarEnabled 键 → 容器观察者重读
    // defaults 更新 showStatusBar（生产链路：SettingsApplier 写 defaults + post → 容器重读现读
    // 生效，与 testSettingsBroadcastResendsConfig 同构）
    @MainActor
    func testStatusBarBroadcastUpdatesShowStatusBar() {
        let defaults = makeDefaults()
        let state = MainContentState(defaults: defaults)
        XCTAssertTrue(state.showStatusBar, "广播前默认 true")
        defaults.set(false, forKey: SettingsChangeKey.statusBarEnabled)
        NotificationCenter.default.post(
            name: .editorSettingsDidChange, object: nil,
            userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.statusBarEnabled]])
        XCTAssertFalse(state.showStatusBar, "广播 statusBarEnabled 键 → showStatusBar 更新 false")
    }

    // ⚠️ P1-1（保存/导出通道收敛）：editorRawText 数据源断言——折叠态下返回完整原文
    @MainActor
    func testEditorRawTextReturnsTextViewRawText() {
        let state = MainContentState(defaults: makeDefaults())
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)   // 折叠态：显示文本缺行、rawText 完整
        state.attachTextView(tv)
        XCTAssertEqual(state.editorRawText, "# Title\nIntro\nMore text\n## Sub\nEnd",
                       "折叠态下 editorRawText = 完整原文（MD 导出数据源）")
        // MD 导出端到端：copyMarkdown 走 editorRawText → 剪贴板完整原文
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.markdowneditor.tests.p1.export"))
        ExportManager.copyMarkdown(state.editorRawText, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "# Title\nIntro\nMore text\n## Sub\nEnd",
                       "MD 复制经 editorRawText → 完整原文（FR-093 原始源码语义）")
    }

    // 未挂接 textView（previewOnly/测试）→ 回落 latestEditorText
    @MainActor
    func testEditorRawTextFallsBackToLatestEditorText() {
        let state = MainContentState(defaults: makeDefaults())
        XCTAssertEqual(state.editorRawText, "", "无 textView → 回落 latestEditorText（初始空）")
        state.latestEditorText = "fallback"
        XCTAssertEqual(state.editorRawText, "fallback", "latestEditorText 更新后回落值跟随")
    }

    // ── P1-2（折叠 UI 接线）：toggleFoldAtCursor 路由断言（state 侧分发）──

    // 测试 1：光标落于 H2 行 → 折叠该章节（光标行原文锚定）
    @MainActor
    func testToggleFoldAtCursorFoldsSectionAtCursor() {
        let state = MainContentState(defaults: makeDefaults())
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        state.attachTextView(tv)
        tv.setSelectedRange(NSRange(location: 24, length: 0))   // 光标于 "## Sub" 行首（rawText index 24）
        state.toggleFoldAtCursor()
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n▸ ## Sub",
                       "光标行 H2 → 折叠该章节（▸ 标记单行）")
        XCTAssertEqual(tv.renderingText, "# Title\nIntro\nMore text", "折叠语义渲染输入")
    }

    // 测试 2：再次调用 → 展开恢复原文（toggle 双语义）
    @MainActor
    func testToggleFoldAtCursorUnfoldsOnSecondCall() {
        let state = MainContentState(defaults: makeDefaults())
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        state.attachTextView(tv)
        tv.setSelectedRange(NSRange(location: 24, length: 0))
        state.toggleFoldAtCursor()
        state.toggleFoldAtCursor()
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n## Sub\nEnd", "第二次调用 → 展开恢复原文")
    }

    // 测试 3：未挂接 textView → 静默无崩溃（previewOnly 模式/菜单 disabled 前竞态）
    @MainActor
    func testToggleFoldAtCursorWithoutTextViewNoCrash() {
        let state = MainContentState(defaults: makeDefaults())
        state.toggleFoldAtCursor()   // 无 attach → 静默返回
    }

    // 测试 4（评审 CRITICAL #1 回归）：光标上方已有折叠 → 显示索引 ≠ 原文索引，
    // 折叠感知映射保证折叠光标所在章节（修复前会误展开上方折叠/错位 no-op）
    @MainActor
    func testToggleFoldAtCursorFoldsSectionBelowExistingFold() {
        let state = MainContentState(defaults: makeDefaults())
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\n## Sub A\ntext A\nMore\n## Sub B\ntext B")
        state.attachTextView(tv)
        tv.toggleFold(at: 2)   // 折叠 [2,4]（## Sub A 章节）——光标上方折叠
        // 显示文本 = "# Title\nIntro\n▸ ## Sub A\n## Sub B\ntext B"；"## Sub B" 行首显示索引 25
        tv.setSelectedRange(NSRange(location: 25, length: 0))
        state.toggleFoldAtCursor()
        XCTAssertEqual(tv.string, "# Title\nIntro\n▸ ## Sub A\n▸ ## Sub B",
                       "折叠下方章节被折叠（▸ ## Sub B 标记）——非错位误展开上方折叠")
        XCTAssertEqual(tv.renderingText, "# Title\nIntro",
                       "渲染输入：两处折叠区间（[2,4] 与 [5,6]）整段剔除")
    }

    // ⚠️ FixD2（deep-analysis CRITICAL 回归）：渲染通道污染（latestEditorText 携带折叠语义文本）
    // 不得影响保存/导出数据源——textView 挂接时 editorRawText 恒为完整原文（rawText 权威）；
    // 修复前折叠后 editorText 写回 renderingText → 回填截断 rawText → 保存写残缺文档
    @MainActor
    func testEditorRawTextSurvivesRenderChannelPollutionAfterFold() {
        let state = MainContentState(defaults: makeDefaults())
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        state.attachTextView(tv)
        tv.setSelectedRange(NSRange(location: 24, length: 0))   // 光标于 "## Sub" 行首（rawText index 24）——折叠锚定
        state.toggleFoldAtCursor()   // 折叠 [3,4]（光标行锚定）
        // 渲染通道语义：latestEditorText 被赋 renderingText（折叠语义——S-024 现状）
        state.latestEditorText = tv.renderingText
        XCTAssertEqual(state.latestEditorText, "# Title\nIntro\nMore text", "前置：渲染通道携带折叠语义文本")
        XCTAssertEqual(tv.foldState.folded.isEmpty, false, "折叠仍生效（未被回填清空）")
        XCTAssertEqual(state.editorRawText, "# Title\nIntro\nMore text\n## Sub\nEnd",
                       "textView 挂接 → editorRawText = 完整原文（渲染通道污染不落保存通道）")
    }
}
