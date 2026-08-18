import XCTest
import AppKit
@testable import MarkdownEditor

// MarkdownTextView 事件暴露（S-007 AC-3/AC-4）
// ⚠️ 修复 C1（第 7 轮）：didChangeText() 可见但 didChangeSelection() 不可见（@UIActor 隐藏），
// 且通知订阅路径下显式 post 通知是确定性触发方式
final class MarkdownTextViewTests: XCTestCase {
    @MainActor
    func testTextDidChangeFiresCallback() {
        let tv = MarkdownTextView()
        var received: String?
        tv.onTextDidChange = { received = $0 }
        tv.string = "# Hello"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertEqual(received, "# Hello")
    }

    @MainActor
    func testSelectionDidChangeFiresCallback() {
        let tv = MarkdownTextView()
        var received: NSRange?
        tv.onSelectionDidChange = { received = $0 }
        tv.string = "# Hello"  // ⚠️ 修复 #13（T2.1）：空文本上 setSelectedRange 超出范围会被 AppKit clamp 为 {0,0} → 先设文本（与 testTextDidChangeFiresCallback 对称）
        tv.setSelectedRange(NSRange(location: 2, length: 3))
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: tv)
        XCTAssertEqual(received, NSRange(location: 2, length: 3))
    }

    @MainActor
    func testScrollRatioClamped() {
        let tv = MarkdownTextView()
        var ratios: [Double] = []
        tv.onScrollRatio = { ratios.append($0) }
        tv.reportScroll(visibleMinY: 450, visibleHeight: 100, contentHeight: 1000)   // 450/900 → 0.5
        tv.reportScroll(visibleMinY: -10, visibleHeight: 100, contentHeight: 1000)   // clamp → 0
        tv.reportScroll(visibleMinY: 2000, visibleHeight: 100, contentHeight: 1000)  // clamp → 1
        tv.reportScroll(visibleMinY: 100, visibleHeight: 0, contentHeight: 1000)     // 零可见高度 → 不触发
        tv.reportScroll(visibleMinY: 0, visibleHeight: 500, contentHeight: 100)      // 内容不足一屏 → 0
        XCTAssertEqual(ratios, [0.5, 0, 1, 0])
    }

    @MainActor
    func testIsPlainText() {
        let tv = MarkdownTextView()
        XCTAssertFalse(tv.isRichText, "MVP 编辑器为纯文本（FR-003 高亮在 S-023）")
    }

    // ⚠️ 新增（T2.1 审查修复 1）：弯引号自动替换必须关闭，避免 " 被替换为 “” 污染落盘内容
    @MainActor
    func testQuoteSubstitutionDisabled() {
        let tv = MarkdownTextView()
        XCTAssertFalse(tv.isAutomaticQuoteSubstitutionEnabled, "Markdown 源码编辑器禁止弯引号自动替换（与关闭链接检测同理）")
    }

    // ⚠️ 新增（T2.1 审查修复 2）：重复 attach 后再 detach 不应残留 stale observer（修复前旧 observer 泄漏）
    @MainActor
    func testDuplicateAttachDoesNotLeaveStaleObserver() {
        let scrollView = NSScrollView()
        let tv = MarkdownTextView()
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 300)  // 保证 contentHeight > 0，触发 reportScroll
        let tracker = ScrollTracker()
        var callbacks = 0
        tv.onScrollRatio = { _ in callbacks += 1 }

        tracker.attach(to: scrollView, textView: tv)
        tracker.attach(to: scrollView, textView: tv)  // 修复前：第二次 attach 覆盖 observer 属性，旧 observer 残留
        tracker.detach()                              // 应移除全部 observer

        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        XCTAssertEqual(callbacks, 0, "重复 attach 后 detach 不应有 stale observer 残留回调")
    }

    // ⚠️ 遗留 #5（批次 1）追加：主题广播订阅（AD-10 ①）——post light/dark effectiveMode → 颜色断言
    // 广播 object 恒为 effectiveMode；勿测 .system 死分支（设计 §5.1 #5）
    // ⚠️ 修订（T1.1）：动态色改固定色——light 断言黑字白底（与系统外观解耦，防黑字黑底不可见）
    @MainActor
    func testThemeNotificationLightAppliesFixedColors() {
        let tv = MarkdownTextView()
        tv.textColor = .red                 // 先污染，断言被广播复位
        tv.insertionPointColor = .red
        tv.backgroundColor = .red
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.light)
        XCTAssertEqual(tv.textColor, .black, "light 模式固定黑字（解耦系统外观）")
        XCTAssertEqual(tv.insertionPointColor, .black, "light 模式固定黑色光标")
        XCTAssertEqual(tv.backgroundColor, .white, "light 模式固定白底")
    }

    @MainActor
    func testThemeNotificationDarkAppliesExplicitColors() {
        let tv = MarkdownTextView()
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        XCTAssertEqual(tv.textColor, .white, "dark 模式显式深色文本")
        XCTAssertEqual(tv.insertionPointColor, .white, "dark 模式显式深色光标")
        // ⚠️ 修复（T1.1 第 1 轮审查）：dark 模式须显式深底——系统亮色 + 应用 dark 时避免白字白底不可读
        // Fix (T1.1 round-1 review): dark mode must set explicit dark background to avoid unreadable white-on-white when the system is in light appearance
        // ⚠️ 修订（T1.1）：深底提亮 0.12 → 0.18（0.12 过黑提亮，与实现侧固定色一致）
        XCTAssertEqual(tv.backgroundColor, NSColor(white: 0.18, alpha: 1))
    }

    // ⚠️ 遗留 #5：订阅后主动同步一次（容器 init apply() 广播先于视图订阅——初始广播丢失场景；
    // 显式 dark 启动由此覆盖）
    @MainActor
    func testSyncThemeFromProviderAppliesInitial() {
        let tv = MarkdownTextView()
        tv.themeProvider = { .dark }        // 模拟外部注入 effectiveMode
        tv.syncThemeFromProvider()
        XCTAssertEqual(tv.textColor, .white, "主动同步一次覆盖显式 dark 启动场景")
    }

    // ⚠️ 新增（focus-fix，根因 1）：setTextProgrammatically 抑制通知回调——
    // 修复前 updateNSView 直接 string 赋值 → 同步 didChangeNotification → onTextDidChange →
    // editorText 写 → body 重算 → updateNSView 同帧循环（AttributeGraph cycle → UI 冻结）
    @MainActor
    func testSetTextProgrammaticallySuppressesCallback() {
        let tv = MarkdownTextView()
        var received: [String] = []
        tv.onTextDidChange = { received.append($0) }

        // ⚠️ 修订（审查 CRITICAL #1）：无法在 XCTest 中构造"赋值期间的通知"——
        // setTextProgrammatically 内 defer 在函数返回时复位标志，调用返回后显式 post
        // 已不在抑制窗口内。改用 internal 标志直接验证抑制机制：
        // ① 置位 → post → 断言回调被拦截 → 复位
        tv.isProgrammaticUpdate = true   // ⚠️ 改 internal（测试可访问；生产仅 setTextProgrammatically 使用）
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertTrue(received.isEmpty, "程序化更新期间 didChangeNotification 回调应被抑制")
        tv.isProgrammaticUpdate = false

        // ② 程序化回填：文本写入生效 + 返回 Bool（供回填后显式渲染）
        let wrote = tv.setTextProgrammatically("# Hello")
        XCTAssertTrue(wrote, "内容变化时应返回 true")
        XCTAssertEqual(tv.string, "# Hello", "程序化回填应写入文本")
        // ⚠️ 加固（盲审 B2）：赋值期间抑制契约——XCTest 中 didChangeNotification 异步投递，此刻 received 必为空；若 SDK 行为变化为同步投递，此断言立即暴露，防生产循环回归
        XCTAssertTrue(received.isEmpty, "程序化赋值期间通知回调应被抑制")

        // ③ 相同值回填：值比较短路，不重复写入，返回 false
        let wroteSame = tv.setTextProgrammatically("# Hello")
        XCTAssertFalse(wroteSame, "相同值回填应短路返回 false")

        // ④ 非抑制期（用户输入路径）：回调正常触发（回归保护——抑制不得误伤用户输入）
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertEqual(received, ["# Hello"], "非抑制期回调应正常触发")
    }

    // ⚠️ 新增（round4 T1.1，根因 1）：typingAttributes 显式着色断言——
    // textColor setter 派生不完整，新输入字符须显式携带前景色 + font（黑字黑底不可见根因）
    // ⚠️ 修订（round5 T1.1）：typingAttributes 不再带字符级 backgroundColor——
    // 文本自身 bg 与视图 bg 叠加出错觉；背景统一由视图 backgroundColor + drawsBackground 承载
    @MainActor
    func testApplyThemeSetsTypingAttributesExplicitly() {
        let tv = MarkdownTextView()
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        let attrs = tv.typingAttributes
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, .white,
                       "typingAttributes 前景色 = 主题前景色（新输入可见）")
        XCTAssertNil(attrs[.backgroundColor], "typingAttributes 不携带字符级背景（防同色系叠加）")
        XCTAssertNotNil(attrs[.font], "typingAttributes 携带 font（编辑态字体一致）")
    }

    // ⚠️ 新增（round4 T1.1，根因 1）：程序化回填后重着色断言——
    // string 回填的已有文本默认 attributedString 无前景色 → 黑字黑底不可见；
    // setTextProgrammatically 后应已按当前主题前景色整段着色
    @MainActor
    func testRecolorTextStorageAfterProgrammaticSet() {
        let tv = MarkdownTextView()
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        tv.setTextProgrammatically("# Hello")
        let attr = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(attr, .white, "回填文本按当前主题前景色着色（dark：白字）")
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.light)
        tv.setTextProgrammatically("# World")
        let attrLight = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(attrLight, .black, "主题切换后回填按新主题着色（light：黑字）")
    }

    // ⚠️ 修订（round5 T1.1）：语义迁移——round4 断言"recolor 重写字符级背景"；
    // round5 设计字符级背景彻底退出（视图背景承载），断言"回填/recolor 均不写入字符级背景"
    @MainActor
    func testRecolorWritesForegroundOnly() {
        let tv = MarkdownTextView()
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        tv.setTextProgrammatically("# Hello")
        // ① attributedString 构造：回填文本无字符级背景
        XCTAssertNil(tv.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
                     "回填 attributedString 不携带字符级背景")
        // ② 主题切换：recolor 只写前景色，不写入字符级背景
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.light)
        XCTAssertEqual(tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .black, "主题切换后前景色整段覆盖（light：黑字）")
        XCTAssertNil(tv.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
                     "recolor 不写入字符级背景")
    }

    // ⚠️ 新增（round5 T1.1，根因 1）：drawsBackground 断言——NSTextView 未显式设置时可能
    // 不绘制 backgroundColor → 显示父视图背景（白色）→ dark 白字白底不可见；init + applyTheme 均须为 true
    @MainActor
    func testDrawsBackgroundEnabled() {
        let tv = MarkdownTextView()
        XCTAssertTrue(tv.drawsBackground, "init 默认绘制背景（防父视图背景透出）")
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.light)
        XCTAssertTrue(tv.drawsBackground, "applyTheme(light) 保持绘制背景")
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        XCTAssertTrue(tv.drawsBackground, "applyTheme(dark) 保持绘制背景")
    }

    // ⚠️ 新增（round5 T1.1，根因 1）：attributedString 构造断言——回填文本整段显式携带
    // 前景色（effectiveRange 覆盖全量），验证 setTextProgrammatically 不依赖
    // textColor/typingAttributes 的 SDK 派生路径（macOS 26 行为不明）
    @MainActor
    func testBackfilledTextCarriesForegroundColor() {
        let tv = MarkdownTextView()
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        tv.setTextProgrammatically("# Hello")
        var effectiveRange = NSRange(location: 0, length: 0)
        let fg = tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: &effectiveRange) as? NSColor
        XCTAssertEqual(fg, .white, "回填文本首字符前景色 = 主题前景色（dark：白字）")
        XCTAssertEqual(effectiveRange, NSRange(location: 0, length: (tv.string as NSString).length),
                       "前景色覆盖全量文本（attributedString 构造驱动，非逐段派生）")
    }

    // ⚠️ 新增（round6 T1.1，根因 1）：输入路径强制着色——typingAttributes 可能被
    // IME/撤销/自动替换重建重置（用户环境复现），textDidChange 通知闭包须在抑制标志下
    // 强制 recolorTextStorage（不依赖 typingAttributes 的 SDK 派生路径）
    // 验证三件事：① 输入路径 recolor 生效（污染后恢复主题色）② dark/light 双主题
    // ③ 无循环（recolor 不产生额外 onTextDidChange 回调）
    @MainActor
    func testInputPathForcesRecolorOnTextDidChange() {
        let tv = MarkdownTextView()
        var callbacks: [String] = []
        tv.onTextDidChange = { callbacks.append($0) }
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)

        // 模拟输入：程序化回填建立着色基线
        tv.setTextProgrammatically("Hello")
        // 模拟 round6 真实症状：typingAttributes 被 IME/撤销重置 → 新文字颜色错误
        tv.typingAttributes = [.foregroundColor: NSColor.red]

        // 输入路径：post didChange 通知（非程序化）→ typingAttributes 漂移检测 → recolor
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertEqual(tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .white, "typingAttributes 漂移时输入路径重着色恢复主题色（dark：白字）")
        XCTAssertEqual(callbacks, ["Hello"], "输入通知回调触发一次；recolor 不产生额外回调（无循环）")

        // 主题切换后输入路径同样生效（light：黑字）——再次污染 typingAttributes
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.light)
        tv.typingAttributes = [.foregroundColor: NSColor.red]
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertEqual(tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .black, "typingAttributes 漂移时输入路径重着色恢复主题色（light：黑字）")
        // ⚠️ 修订（盲审 IMPORTANT #3）：phase 2 追加回调计数断言——phase 1 的计数断言
        // 处于抑制标志窗口内（guard 拦截 recolor 触发的 didChange → 症状被遮蔽），无法暴露
        // "recolor 触发 didChange" 类回归；applyTheme 内部 recolor（未置抑制标志）若触发通知
        // 将在此处爆发为 ["Hello","Hello","Hello"]（生产无限循环），此断言是唯一探测点
        XCTAssertEqual(callbacks, ["Hello", "Hello"], "主题切换后输入路径回调仍只触发一次；recolor 不产生额外回调（无循环）")
    }

    // ── S-021：命令执行 → textStorage 变化（原生编辑链路）──

    @MainActor
    func testPerformFormattingBoldWrapsSelection() {
        let tv = MarkdownTextView()
        tv.string = "hello world"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.performFormatting(.bold)
        XCTAssertEqual(tv.string, "**hello** world")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 9), "包裹后选中包裹内容")
    }

    @MainActor
    func testPerformFormattingBoldAtCaretInsertsPlaceholder() {
        let tv = MarkdownTextView()
        tv.string = "abc"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.performFormatting(.bold)
        XCTAssertEqual(tv.string, "a**粗体文本**bc")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 7, length: 0), "光标居中于 placeholder 之后")
    }

    @MainActor
    func testPerformFormattingHeadingAtCaretLine() {
        let tv = MarkdownTextView()
        tv.string = "first line\ntitle line"
        tv.setSelectedRange(NSRange(location: 16, length: 0))   // 第二行 "title line" 内
        tv.performFormatting(.heading1)
        XCTAssertEqual(tv.string, "first line\n# title line")
    }

    @MainActor
    func testPerformFormattingTogglePaneNoop() {
        let tv = MarkdownTextView()
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.performFormatting(.togglePane)   // 布局命令 → 文本不变
        XCTAssertEqual(tv.string, "hello")
    }

    @MainActor
    func testPerformFormattingTriggersDidChangeCallback() {
        // 原生编辑链路 → didChangeNotification → onTextDidChange（渲染管线输入）
        let tv = MarkdownTextView()
        var received: String?
        tv.onTextDidChange = { received = $0 }
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.performFormatting(.italic)
        XCTAssertEqual(received, "*hello*")
    }

    // ⚠️ 计划 MINOR 风险（已处理，方案②）：无窗口环境中 NSTextView.undoManager 可能为 nil
    //（undoManager 由窗口/responder chain 提供；NSResponder.undoManager 为 readonly——
    // SDK 头文件确认 `nullable, readonly, strong` → 方案①注入不可编译）→ undo() 静默不执行。
    // 处理：条件断言——撤销进栈行为由原生编辑链保证（设计已 Verified），断言仅在可验证时执行。
    // 无需改实现语义（shouldChangeText 注册 undo + replaceCharacters 生效，原生编辑链）。
    @MainActor
    func testPerformFormattingIsUndoable() {
        let tv = MarkdownTextView()
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.performFormatting(.bold)
        XCTAssertEqual(tv.string, "**hello**")
        if let undo = tv.undoManager {
            undo.undo()
            XCTAssertEqual(tv.string, "hello", "撤销自动进 undo 栈（原生编辑链）")
        }
    }

    // ── S-023：高亮集成（真实 Highlightr，POC-S-005 已验证可用）──

    /// 收集 textStorage 全部前景色集合
    @MainActor
    private func foregroundColors(in tv: MarkdownTextView) -> Set<NSColor> {
        var colors: Set<NSColor> = []
        tv.textStorage?.enumerateAttribute(.foregroundColor,
                                           in: NSRange(location: 0, length: tv.textStorage?.length ?? 0),
                                           options: []) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        return colors
    }

    // 高亮开启（默认）→ 双层高亮多色属性（污染-断言模式：先 .red 污染再断言主题复位复用）
    @MainActor
    func testHighlightEnabledProducesMultiColorAttributes() {
        let tv = MarkdownTextView()
        tv.string = "# Title\n\n```swift\nlet x = 1\n```\n"
        // 先全量污染为红 → 高亮后应有主题色区间（非全红 = 多色）
        tv.textStorage?.addAttribute(.foregroundColor, value: NSColor.red,
                                     range: NSRange(location: 0, length: tv.string.utf16.count))
        tv.highlightNow()
        let colors = foregroundColors(in: tv)
        XCTAssertGreaterThan(colors.count, 1, "高亮后存在多色属性区间（非全红污染残留）")
        XCTAssertFalse(colors.contains(.red), "高亮结果覆盖污染色")
    }

    // 高亮关闭 → 单色 recolor 保持（纯文本路径零回归）
    // ⚠️ 审查修复（IMPORTANT #2）：纯 string 赋值不携带前景色属性且 didChange 异步 →
    // 直接断言颜色集合为 0 必失败；先 post editorThemeDidChange 触发 applyTheme →
    // recolorTextStorage 全量刷主题前景色（与 testThemeNotificationLightAppliesFixedColors
    // 同模式），再验证高亮关闭时单色保持
    @MainActor
    func testHighlightDisabledKeepsSingleColor() {
        let suite = UserDefaults(suiteName: "test-tv-highlight-off")!
        suite.removePersistentDomain(forName: "test-tv-highlight-off")
        suite.set(false, forKey: SyntaxHighlighter.enabledKey)
        let tv = MarkdownTextView(defaults: suite)
        tv.string = "**bold** `code`"
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.light)   // 触发 recolor（单色）
        tv.highlightNow()   // 开关关闭 → 无操作，recolor 单色保持
        let colors = foregroundColors(in: tv)
        XCTAssertEqual(colors.count, 1, "高亮关闭 → 单色（recolor 语义保持，零回归）")
        XCTAssertEqual(colors.first, .black, "light 主题单色 = 主题前景色")
    }

    // 主题切换 → 高亮器主题重放（dark → github-dark；多色保持）
    // ⚠️ 修订（T5.1 收尾）：初始 light 主题 = github-gist（Highlightr 2.3.0 stripTheme 正则
    // 不解析复合选择器，github light 主题颜色损坏；POC-S-005 已验证 github-gist）
    @MainActor
    func testThemeChangeReplaysHighlightWithDarkTheme() {
        let tv = MarkdownTextView()
        tv.string = "```python\nprint(1)\n```\n"
        tv.highlightNow()
        XCTAssertEqual(tv.syntaxHighlighter.currentThemeName, "github-gist", "初始 light 主题 = github-gist")
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        XCTAssertEqual(tv.syntaxHighlighter.currentThemeName, "github-dark", "dark → github-dark（AD-8 双轨）")
        // 自动重放（450ms debounce）后多色
        let exp = expectation(description: "replay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertGreaterThan(foregroundColors(in: tv).count, 1, "主题切换后自动重放高亮（多色）")
    }

    // 输入触发 didChange → 自动调度高亮（开关默认开；停笔后多色出现）
    // ⚠️ 修订（T5.1 收尾）：轮询等待高亮落地——前序测试的全局 editorThemeDidChange 广播
    //（queue: .main 异步投递）可能在本测试窗口内反复触发 applyTheme → 重置 450ms debounce；
    // 固定 0.6s 等待会早于最后一次调度+0.45s 落地而断言失败。轮询至 deadline 2s，落地即断。
    // Poll until the highlight lands: global editorThemeDidChange broadcasts from prior tests
    // (delivered async on the main queue) may repeatedly trigger applyTheme and reset the
    // 450ms debounce; a fixed 0.6s wait can fire before the last schedule lands. Poll up to 2s.
    @MainActor
    func testInputTriggersScheduledHighlight() {
        let tv = MarkdownTextView()
        tv.string = "```js\nlet a = 1\n```\n"
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText("\nlet b = 2", replacementRange: tv.selectedRange())   // 原生编辑 → didChange → 调度
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, foregroundColors(in: tv).count <= 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(foregroundColors(in: tv).count, 1, "输入停笔后自动高亮（多色）")
    }

    // ⚠️ S-024 追加：selection 通知程序化抑制（与 didChange 对称——回填改选区防误触发定位）
    @MainActor
    func testSelectionNotificationSuppressedDuringProgrammaticUpdate() {
        let tv = MarkdownTextView()
        var received: [NSRange] = []
        tv.onSelectionDidChange = { received.append($0) }
        tv.string = "# Hello"   // 先设文本：空文本上 setSelectedRange 会被 AppKit clamp 为 {0,0}（与默认选区相同，不触发通知）
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        received.removeAll()   // 清掉 setSelectedRange 触发的真实通知（避免污染断言）
        tv.isProgrammaticUpdate = true
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: tv)
        XCTAssertTrue(received.isEmpty, "抑制标志期间不得触发定位同步")
        tv.isProgrammaticUpdate = false
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: tv)
        XCTAssertEqual(received.count, 1, "复位后正常触发")
    }

    // ── S-027/S-028 追加：字体（init 读取 / 设置广播应用 / recolor 连带 / 高亮结果统一 / 开关实时路径）──
    // ⚠️ 实证修正（批 1 T1.2 先例）：NSFont.fontName 返回 PostScript 名——存储 "Menlo" 解析后
    // fontName == "Menlo-Regular"（FontSettingsTests.swift:61 同款断言）；涉及 fontName 的断言
    // 统一用 "Menlo-Regular"，测试意图（字体从 FontSettings 读取/统一）不变

    @MainActor
    private func makeFontSuite(name: String, size: CGFloat) -> UserDefaults {
        let suiteName = "test-tv-font-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        if !name.isEmpty { suite.set(name, forKey: FontSettings.Key.fontName) }
        suite.set(Double(size), forKey: FontSettings.Key.pointSize)
        return suite
    }

    @MainActor
    func testInitReadsFontFromSettings() {
        let tv = MarkdownTextView(defaults: makeFontSuite(name: "Menlo", size: 16))
        XCTAssertEqual(tv.font?.fontName, "Menlo-Regular", "init 从 FontSettings 读取字体名（S-027）")
        XCTAssertEqual(tv.font?.pointSize, 16, "init 从 FontSettings 读取字号")
    }

    @MainActor
    func testInitDefaultFontIsMonospaced14() {
        let tv = MarkdownTextView(defaults: makeFontSuite(name: "", size: 14))
        XCTAssertEqual(tv.font, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                       "默认等宽 14（现状行为保持）")
    }

    @MainActor
    func testSettingsFontNotificationAppliesFont() {
        let suite = makeFontSuite(name: "Menlo", size: 16)
        let tv = MarkdownTextView(defaults: suite)
        tv.setTextProgrammatically("# Hello")
        // 面板改字号后广播（模拟：改 defaults + 广播 font 键）
        suite.set(20.0, forKey: FontSettings.Key.pointSize)
        NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil,
                                        userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.font]])
        XCTAssertEqual(tv.font?.pointSize, 20, "广播后 font 改写（FontSettings 现读）")
        let storageFont = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(storageFont?.pointSize, 20, "textStorage 整段 font 重写（recolor 连带）")
        XCTAssertEqual((tv.typingAttributes[.font] as? NSFont)?.pointSize, 20, "typingAttributes 跟随（新输入用新字体）")
    }

    @MainActor
    func testRecolorWritesFontAlongsideForeground() {
        let suite = makeFontSuite(name: "Menlo", size: 16)
        let tv = MarkdownTextView(defaults: suite)
        NotificationCenter.default.post(name: .editorThemeDidChange, object: ThemeMode.dark)
        tv.setTextProgrammatically("# Hello")
        // 污染 typingAttributes font（round6 真实症状：IME/撤销重置 → 新输入字体错）→ 输入路径 recolor → font 恢复
        tv.typingAttributes[.font] = NSFont.systemFont(ofSize: 99)
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        let storageFont = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(storageFont?.fontName, "Menlo-Regular", "输入路径 recolor 连带恢复 font（fg+font 重写）")
    }

    @MainActor
    func testHighlightResultFontUnified() {
        let tv = MarkdownTextView(defaults: makeFontSuite(name: "Menlo", size: 16))
        tv.string = "```swift\nlet x = 1\n```\n"
        tv.highlightNow()   // 真实 Highlightr 输出 Courier 14 → 覆盖为用户字体
        let storageFont = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(storageFont?.fontName, "Menlo-Regular", "高亮结果整段 font 覆盖（Courier 消除，字体统一）")
    }

    @MainActor
    func testHighlightSwitchOffClearsAndReplayOn() {
        let suiteName = "test-tv-hl-switch-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let tv = MarkdownTextView(defaults: suite)
        // ⚠️ 实证修正（批 2 RED）：```python\nprint(1)``` 在 github-gist（light）下为单色——
        // 既有多色基线先例 testHighlightEnabledProducesMultiColorAttributes 用 ```swift\nlet x = 1```
        // （github-gist 下多色已验证）；dark 重放路径才用 python（github-dark 多色，见既有测试）
        tv.string = "```swift\nlet x = 1\n```\n"
        tv.highlightNow()   // 开 → 多色高亮落地
        XCTAssertGreaterThan(foregroundColors(in: tv).count, 1, "高亮开启基线（多色）")

        // 关闭：写 defaults + 广播 → recolor fg+font 整段重写（单色清除残留）
        suite.set(false, forKey: SyntaxHighlighter.enabledKey)
        NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil,
                                        userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.highlightEnabled]])
        XCTAssertEqual(foregroundColors(in: tv).count, 1, "关闭后整段单色（Highlightr 残留色清除）")
        XCTAssertEqual(tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, tv.font,
                       "关闭后 font 统一（残留字体清除）")

        // 开启：写 defaults + 广播 → 重放（450ms debounce；轮询至 2s——全局广播异步投递先例）
        suite.set(true, forKey: SyntaxHighlighter.enabledKey)
        NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil,
                                        userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.highlightEnabled]])
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, foregroundColors(in: tv).count <= 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(foregroundColors(in: tv).count, 1, "开启后自动重放高亮（多色）")
    }

    // ⚠️ S-029 追加：行号纯函数 + 开关分发

    @MainActor
    func testLineNumberForCharacterIndex() {
        let text = "第一行\n第二行\n第三行"
        XCTAssertEqual(LineNumbers.lineNumber(forCharacterIndex: 0, in: text), 1)
        XCTAssertEqual(LineNumbers.lineNumber(forCharacterIndex: 3, in: text), 1, "首个 \\n 之前属第 1 行")
        XCTAssertEqual(LineNumbers.lineNumber(forCharacterIndex: 4, in: text), 2, "第一个 \\n 之后属第 2 行")
        XCTAssertEqual(LineNumbers.lineNumber(forCharacterIndex: (text as NSString).length, in: text), 3)
    }

    @MainActor
    func testIsLineStart() {
        let text = "ab\ncd"
        XCTAssertTrue(LineNumbers.isLineStart(characterIndex: 0, in: text))
        XCTAssertFalse(LineNumbers.isLineStart(characterIndex: 1, in: text))
        XCTAssertTrue(LineNumbers.isLineStart(characterIndex: 3, in: text), "换行后首字符为行首")
        XCTAssertFalse(LineNumbers.isLineStart(characterIndex: 10, in: text), "越界 → 非行首")
    }

    @MainActor
    func testLineCount() {
        XCTAssertEqual(LineNumbers.lineCount(in: "a\nb\nc"), 3)
        XCTAssertEqual(LineNumbers.lineCount(in: ""), 1)
        XCTAssertEqual(LineNumbers.lineCount(in: "x\n"), 2)
    }

    // ⚠️ 适配（headless macOS 26 实证）：NSView.needsDisplay getter 不反映 setter——KVO 观察
    // set true → 回调 false；窗口挂接/激活/runloop 均无效（实现侧 verbatim，生产正确）
    // → 改验证开关分发的可观测契约：drawBackground 现读 defaults —— 开启 → gutter 绘制行号，
    // 关闭 → 无（两次渲染 gutter 像素签名不同）
    @MainActor
    func testSettingsLineNumbersKeyTriggersRedisplay() {
        let suiteName = "test.epic5.markdowntextview.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        let tv = MarkdownTextView(defaults: d)
        tv.string = "第一行\n第二行\n第三行"
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        func renderGutterSignature() -> [UInt32] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            tv.drawBackground(in: NSRect(x: 0, y: 0, width: 400, height: 200))
            NSGraphicsContext.restoreGraphicsState()
            var sig: [UInt32] = []
            for y in 0..<200 {
                for x in 0..<48 {   // gutter 区域（textContainerInset 48pt）
                    if let c = rep.colorAt(x: x, y: y) {
                        sig.append(UInt32(c.redComponent * 255) << 16 |
                                   UInt32(c.greenComponent * 255) << 8 |
                                   UInt32(c.blueComponent * 255))
                    }
                }
            }
            return sig
        }

        // 关闭（默认）→ drawBackground 不绘制行号
        let off = renderGutterSignature()
        // 开启 → 广播行号开关键（分发路径）→ drawBackground 现读 defaults 绘制行号
        d.set(true, forKey: LineNumberPreference.enabledKey)
        tv.applySettingsChange(keys: [SettingsChangeKey.lineNumbersEnabled])
        let on = renderGutterSignature()
        XCTAssertNotEqual(on, off, "行号开关变更 → 重绘（drawBackground 现读 defaults 绘制行号）")
    }

    // ── Epic-6 批次 2（T2.2）：折叠集成（原始文本访问器 + ▸ 标记显示）──

    // 测试 1：toggleFold 后 textStorage 为 ▸ 标记单行（折叠区间替换断言）
    @MainActor
    func testToggleFoldReplacesSectionWithMarkerLine() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)   // 折叠 "## Sub" 章节（foldingRange：[3,4] 含 End 行）
        XCTAssertEqual(tv.string.components(separatedBy: "\n"),
                       ["# Title", "Intro", "More text", "▸ ## Sub"],
                       "折叠后章节区间替换为 ▸ 标记单行（textStorage 单行 ▸）")
    }

    // 测试 2：renderingText 按 FoldState 折叠区间剔除行（其余行原样保留）
    @MainActor
    func testRenderingTextExcludesFoldedLines() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)
        XCTAssertEqual(tv.renderingText, "# Title\nIntro\nMore text",
                       "renderingText 剔除折叠区间行（折叠语义渲染输入）")
    }

    // 测试 3：折叠后渲染链路触发——didChangeText 补发 + 显式 onTextDidChange(renderingText)
    @MainActor
    func testToggleFoldTriggersRenderCallback() {
        let tv = MarkdownTextView()
        var received: [String] = []
        tv.onTextDidChange = { received.append($0) }
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        received.removeAll()   // 回填期间通知被抑制 → 清空基线
        tv.toggleFold(at: 3)
        XCTAssertEqual(received, ["# Title\nIntro\nMore text"],
                       "折叠后渲染链路收到折叠语义文本（onTextDidChange 被调用）")
    }

    // 测试 4：展开恢复原始行区间（▸ 标记行 → 原文行）
    @MainActor
    func testToggleFoldUnfoldRestoresOriginalText() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n▸ ## Sub", "折叠前置状态（单 ▸ 行）")
        tv.toggleFold(at: 3)   // 展开
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n## Sub\nEnd", "展开恢复原始行区间")
        XCTAssertEqual(tv.renderingText, tv.string, "展开后渲染文本回归原文")
    }

    // ⚠️ 新增（T2.2-fix1，评审 CRITICAL + IMPORTANT）：折叠态编辑数据丢失修复回归测试

    // 测试 1：折叠 → 编辑可见行 → 展开，断言 rawText 完整（含折叠区间行）
    // 修复前：didChange 闭包无条件 rawText = self.string（显示文本含 ▸、缺折叠行）→
    // 折叠态编辑后折叠区间原文永久丢失（"End" 行消失 + ▸ 残留）
    @MainActor
    func testFoldThenEditThenUnfoldRestoresOriginal() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)   // 折叠 "## Sub" 章节（foldingRange：[3,4] 含 End 行）
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n▸ ## Sub", "前置：折叠后显示 ▸ 单行")

        // 模拟折叠态下用户编辑可见行（Intro → IntroX）：显示文本改写 + didChange 通知
        tv.string = "# Title\nIntroX\nMore text\n▸ ## Sub"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)

        // 展开 → rawText 须完整保留原文（编辑行同步 + 折叠区间行恢复）
        tv.toggleFold(at: 3)
        XCTAssertEqual(tv.rawText, "# Title\nIntroX\nMore text\n## Sub\nEnd",
                       "折叠态编辑后原文完整（编辑同步到锚点行 + 区间行恢复，无 ▸ 残留/无行丢失）")
        XCTAssertEqual(tv.string, "# Title\nIntroX\nMore text\n## Sub\nEnd", "展开恢复原文行")
    }

    // 测试 2：setTextProgrammatically 回填新文档 → 折叠状态清空、无 ▸ 残留（换文档残留防护）
    // 修复前：回填不重置 foldState.folded → 旧折叠区间指向新文档行号 → ▸ 错位残留
    @MainActor
    func testSetTextProgrammaticallyClearsFolds() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n▸ ## Sub", "前置：折叠生效（显示 ▸）")

        // 回填新文档（换文档场景）→ 折叠区间清空 + 无 ▸ 残留
        tv.setTextProgrammatically("# New Doc\nBody")
        XCTAssertTrue(tv.foldState.folded.isEmpty, "回填新文档后折叠区间清空（换文档残留防护）")
        XCTAssertEqual(tv.string, "# New Doc\nBody", "回填文本无 ▸ 残留")
        XCTAssertFalse(tv.string.contains("▸"), "显示文本不含 ▸ 标记")
    }

    // 测试 3：不可折叠行（H1）toggle → 回滚：folded 空、文本无 ▸（回归保护——修复不得破坏回滚守卫）
    @MainActor
    func testToggleFoldOnNonFoldableLineRollsBack() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 0)   // H1 行 → foldingRange nil → 折叠路径守卫回滚
        XCTAssertTrue(tv.foldState.folded.isEmpty, "不可折叠行 toggle 回滚 → 折叠区间为空")
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n## Sub\nEnd", "文本无 ▸ 残留")
        XCTAssertFalse(tv.string.contains("▸"), "显示文本不含 ▸ 标记")
    }

    // 测试 4：代码围栏折叠 → ▸ 单行 → 展开恢复原文（围栏区间 round-trip 回归保护）
    @MainActor
    func testToggleFoldOnFenceRoundTrips() {
        let tv = MarkdownTextView()
        tv.setTextProgrammatically("before\n```swift\nlet x = 1\n```\nafter")
        tv.toggleFold(at: 1)   // 折叠围栏区间 [1,3]
        XCTAssertEqual(tv.string, "before\n▸ ```swift\nafter", "围栏折叠 → ▸ 单行（区间替换）")
        tv.toggleFold(at: 1)   // 展开
        XCTAssertEqual(tv.string, "before\n```swift\nlet x = 1\n```\nafter", "展开恢复围栏原文")
    }

    // ── P1-2（折叠 UI 接线）：FoldMarker ▸ 行判定纯函数 ──

    // 测试 1：命中——单折叠区间，▸ 标记显示行 → 原文锚点行
    @MainActor
    func testFoldMarkerHitReturnsRawAnchorLine() {
        let raw = "# Title\nIntro\nMore text\n## Sub\nEnd"
        let folded = [FoldRange(startLine: 3, endLine: 4)]
        let display = "# Title\nIntro\nMore text\n▸ ## Sub"
        let index = (display as NSString).range(of: "▸").location   // ▸ 行首
        XCTAssertEqual(FoldMarker.rawLineForMarker(at: index, display: display, raw: raw, folded: folded),
                       3, "▸ 标记行 → 原文行 3（显示行 3 == 原文行 3，单区间场景）")
    }

    // 测试 2：未命中——普通行（非标记行）→ nil
    @MainActor
    func testFoldMarkerMissOnNormalLine() {
        let raw = "# Title\nIntro\nMore text\n## Sub\nEnd"
        let folded = [FoldRange(startLine: 3, endLine: 4)]
        let display = "# Title\nIntro\nMore text\n▸ ## Sub"
        let index = (display as NSString).range(of: "More").location
        XCTAssertNil(FoldMarker.rawLineForMarker(at: index, display: display, raw: raw, folded: folded),
                     "普通行 → nil（不触发展开）")
    }

    // 测试 3：多折叠区间映射——显示行 2 的 ▸ → 原文行 4（折叠态显示行号 ≠ 原文行号）
    @MainActor
    func testFoldMarkerSecondFoldMapsCorrectRawLine() {
        let raw = "# A\n## B\nb1\nb2\n## C\nc1\nc2\n# D"
        let folded = [FoldRange(startLine: 1, endLine: 3), FoldRange(startLine: 4, endLine: 6)]
        let display = "# A\n▸ ## B\n▸ ## C\n# D"
        let secondMarker = (display as NSString).range(of: "▸ ## C").location
        XCTAssertEqual(FoldMarker.rawLineForMarker(at: secondMarker, display: display, raw: raw, folded: folded),
                       4, "第二个 ▸ 显示行 2 → 原文行 4（区间消耗多行，映射必须按原文索引）")
    }

    // 测试 4：边界——index 0（首行普通行）→ nil；index == 末尾（末行 ▸）→ 原文锚点
    @MainActor
    func testFoldMarkerEdgeIndexes() {
        let raw = "# Title\nIntro\nMore text\n## Sub\nEnd"
        let folded = [FoldRange(startLine: 3, endLine: 4)]
        let display = "# Title\nIntro\nMore text\n▸ ## Sub"
        XCTAssertNil(FoldMarker.rawLineForMarker(at: 0, display: display, raw: raw, folded: folded),
                     "index 0 = 首行普通行 → nil")
        XCTAssertEqual(FoldMarker.rawLineForMarker(at: (display as NSString).length,
                                                   display: display, raw: raw, folded: folded),
                       3, "index == 末尾（clamp 到末行 ▸）→ 原文行 3")
    }

    // ── Epic-6 批次 2（T2.3）：自动缩进（shouldChangeText 拦截 \n 注入前导空白）──

    // 测试 1：普通行回车补 0（无列表/引用标记 → 仅前导空白或无注入）
    @MainActor
    func testAutoIndentPlainLineAddsOnlyLeadingWhitespace() {
        let tv = MarkdownTextView()
        // 无前导空白 → 原样 \n
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "hello\n", "普通行回车补 0（无前导空白 → 无注入）")
        // 前导空白保留场景
        tv.string = "  hello"
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "  hello\n  ", "普通行回车仅保留前导空白")
    }

    // 测试 2：列表项回车补 `- ` 缩进（含前导空白场景）
    @MainActor
    func testAutoIndentListContinuation() {
        let tv = MarkdownTextView()
        // 无前导空白列表项
        tv.string = "- item"
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "- item\n- ", "列表项回车续行补 `- ` 缩进")
        // 前导空白 + 列表项
        tv.string = "  - item"
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "  - item\n  - ", "带前导空白的列表项续行补 `  - ` 缩进")
    }

    // 测试 3：引用块回车补 `> `
    @MainActor
    func testAutoIndentBlockquoteContinuation() {
        let tv = MarkdownTextView()
        tv.string = "> quote"
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "> quote\n> ", "引用块回车续行补 `> ` 缩进")
    }

    // 测试 4：开关关闭不注入（defaults 注入 false → 原样 \n）
    @MainActor
    func testAutoIndentDisabledDoesNotInject() {
        let suiteName = "test.epic6.t2.3.autoindent.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set(false, forKey: AutoIndent.enabledKey)
        let tv = MarkdownTextView(defaults: suite)
        tv.string = "- item"
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "- item\n", "开关关闭 → 原样 `\\n`（不注入 `- ` 缩进）")
    }

    // ⚠️ 新增（T2.3-fix1，评审 IMPORTANT #3）：闭合围栏行回车不注入 4 空格——
    // 修复前围栏开闭不分：闭合 ``` 行回车同样注入 4 空格 → 围栏后段落被 4 空格缩进变代码块
    @MainActor
    func testAutoIndentClosingFenceNoInjection() {
        let tv = MarkdownTextView()
        // 开围栏行回车 → 4 空格注入（代码块缩进上下文）
        tv.string = "```swift"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "```swift\n    ", "开围栏行回车补 4 空格（代码块缩进上下文）")
        // 闭合围栏行回车 → 不注入（围栏后段落保持普通行）
        tv.string = "```swift\nlet x = 1\n```"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "```swift\nlet x = 1\n```\n", "闭合围栏行回车不注入缩进（围栏后段落不变代码块）")
    }

    // ⚠️ 新增（T2.3-fix1，评审 IMPORTANT #4）：performFormatting 守卫——列表行上执行
    // codeBlock 命令（replacement 含 \n）→ 输出不被缩进分支劫持注入 `- ` 前缀（既有功能回归）
    @MainActor
    func testAutoIndentSkipsFormattingEdits() {
        let tv = MarkdownTextView()
        tv.string = "- item"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.performFormatting(.codeBlock)
        // 修复前：缩进分支劫持 → "- item```\n- code\n- ```"（\n 后注入 "- " 前缀）
        XCTAssertEqual(tv.string, "- item```\ncode\n```", "codeBlock 命令输出不被自动缩进劫持（无 `- ` 前缀注入）")
    }

    // ⚠️ 新增（T2.3-fix1，评审 IMPORTANT #2）：纯空白行回车保留前导空白——
    // 修复前 guard !rest.isEmpty 返回 "" → 代码块内 "    " 空行回车续行缩进断裂
    @MainActor
    func testAutoIndentKeepsWhitespaceOnBlankLine() {
        let tv = MarkdownTextView()
        // 代码块内纯空白行（4 空格）回车 → 续行保留 4 空格
        tv.string = "```swift\n    "
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("\n", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "```swift\n    \n    ", "纯空白行回车保留前导空白（代码块续行断裂修复）")
    }

    // ── Epic-6 批次 2（T2.4）：括号配对自动补全（shouldChangeText 拦截开括号插入配对）──

    // 测试 1：输入 `(` 自动补全 `)`，光标位于开括号之后
    @MainActor
    func testAutoPairOpenParenInsertsPairAndPlacesCaret() {
        let tv = MarkdownTextView()
        tv.string = "ab"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.insertText("(", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "a()b", "开括号输入自动补全闭合括号")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 0), "光标位于开括号之后")
    }

    // 测试 2：光标后已有 `)` 不重复补对（仅插入开括号，防 naive 补对产生 "())"）
    @MainActor
    func testAutoPairSkipsWhenClosingBracketFollows() {
        let tv = MarkdownTextView()
        tv.string = "ab)"
        tv.setSelectedRange(NSRange(location: 2, length: 0))   // 光标后字符已是 )
        tv.insertText("(", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "ab()", "光标后已有闭合括号 → 仅插入开括号（不重复补对）")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 3, length: 0), "光标位于插入的开括号后")
    }

    // 测试 3：IME compose（hasMarkedText）期间不自动补全（输入法未上屏跳过）
    @MainActor
    func testAutoPairSkipsWhenMarkedTextActive() {
        let tv = MarkdownTextView()
        tv.string = "ab"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        // 模拟 IME compose：插入标记文本（未上屏状态）
        tv.setMarkedText("中", selectedRange: NSRange(location: 2, length: 0),
                         replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(tv.hasMarkedText(), "前置断言：setMarkedText 后 hasMarkedText() 为 true")
        // hasMarkedText → 跳过配对分支 → shouldChangeText 放行（返回 true 不拦截）
        let allowed = tv.shouldChangeText(in: tv.selectedRange(), replacementString: "(")
        XCTAssertTrue(allowed, "IME compose 期间不拦截开括号输入（guard !hasMarkedText 跳过自动补全）")
        XCTAssertEqual(tv.string, "a中b", "shouldChangeText 是纯查询（不修改文本）")
    }

    // length==0 守卫：选中文本输入开括号时不配对（防删除选中文本被 () 覆盖）
    @MainActor
    func testAutoPairSkipsWhenReplacingSelection() {
        let suite = UserDefaults(suiteName: "test.autoPair.selection")!
        suite.removePersistentDomain(forName: "test.autoPair.selection")
        let tv = MarkdownTextView(defaults: suite)
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 1, length: 3))
        tv.insertText("(", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "h(o")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 2, length: 0))
    }

    // 开关关闭：仅插入开括号不配对（与 testAutoIndentDisabledDoesNotInject 对称）
    @MainActor
    func testAutoPairDisabledWhenSwitchOff() {
        let suite = UserDefaults(suiteName: "test.autoPair.off")!
        suite.removePersistentDomain(forName: "test.autoPair.off")
        suite.set(false, forKey: AutoPair.enabledKey)
        let tv = MarkdownTextView(defaults: suite)
        tv.string = "ab"
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.insertText("(", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "a(b")
    }

    // ── P1-1（保存通道收敛）：onRawTextDidChange 触发断言 ──

    // 测试 1：未折叠编辑 → raw 回调 == string（显示 == 原文）
    @MainActor
    func testRawTextCallbackFiresWithStringWhenUnfoldedEdit() {
        let tv = MarkdownTextView()
        var received: [String] = []
        tv.onRawTextDidChange = { received.append($0) }
        tv.setTextProgrammatically("# Title\nIntro")
        received.removeAll()
        tv.string = "# Title\nIntroX"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertEqual(received, ["# Title\nIntroX"],
                       "未折叠编辑 → raw 回调携带显示文本（== 原文）")
    }

    // 测试 2：折叠态编辑可见行 → raw 回调携带完整原文（含折叠区间行——数据完整性核心）
    @MainActor
    func testRawTextCallbackFiresWithFullRawWhenFoldedEdit() {
        let tv = MarkdownTextView()
        var received: [String] = []
        tv.onRawTextDidChange = { received.append($0) }
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)
        received.removeAll()
        // 折叠态编辑可见行（Intro → IntroX）：显示文本改写 + didChange 通知
        tv.string = "# Title\nIntroX\nMore text\n▸ ## Sub"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
        XCTAssertEqual(received, ["# Title\nIntroX\nMore text\n## Sub\nEnd"],
                       "折叠态编辑 → raw 回调携带完整原文（折叠区间行未丢失）")
    }

    // 测试 3：程序化回填 → raw 回调携带新文本（updateNSView 回填路径数据源）
    @MainActor
    func testRawTextCallbackFiresOnProgrammaticBackfill() {
        let tv = MarkdownTextView()
        var received: [String] = []
        tv.onRawTextDidChange = { received.append($0) }
        tv.setTextProgrammatically("# New Doc\nBody")
        XCTAssertEqual(received, ["# New Doc\nBody"],
                       "setTextProgrammatically 回填 → raw 回调携带新文本")
    }

    // ── FR-056（收尾批次）：拖拽图片插入（handleImageDrop 分离 NSDraggingInfo——确定性可测）──

    /// 临时图片 URL（存在性无关——插入仅用路径；含空格覆盖转义断言）
    private func makeImageURLs() -> [URL] {
        [URL(fileURLWithPath: "/tmp/my photo.png")]
    }

    @MainActor
    func testImageDropInsertsMarkdownAtCursor() {
        let tv = MarkdownTextView()
        tv.string = "abc"
        tv.setSelectedRange(NSRange(location: 1, length: 0))   // 光标在 'a' 后
        let handled = tv.handleImageDrop(urls: makeImageURLs())
        XCTAssertTrue(handled, "图片拖拽应被处理")
        XCTAssertEqual(tv.string, "a![my photo](/tmp/my%20photo.png)bc",
                       "光标处插入 imageMarkdown（空格转义 %20）")
        let markdownLen = "![my photo](/tmp/my%20photo.png)".utf16.count
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 1 + markdownLen, length: 0),
                       "光标移至插入内容之后")
    }

    @MainActor
    func testImageDropMultipleURLsInsertsSequentially() {
        let tv = MarkdownTextView()
        tv.string = ""
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        XCTAssertTrue(tv.handleImageDrop(urls: urls))
        XCTAssertEqual(tv.string, "![a](/tmp/a.png)![b](/tmp/b.png)", "多图逐个插入")
    }

    @MainActor
    func testImageDropNoURLsReturnsFalseKeepsText() {
        let tv = MarkdownTextView()
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(tv.handleImageDrop(urls: []), "无图片 → 未处理（代理走 super 不拦截）")
        XCTAssertEqual(tv.string, "hello", "文本不变")
    }

    // ⚠️ 计划 MINOR 风险（同 testPerformFormattingIsUndoable 先例）：无窗口环境中
    // undoManager 可能为 nil → 条件断言（撤销进栈由原生编辑链保证，设计已 Verified）
    @MainActor
    func testImageDropIsUndoable() {
        let tv = MarkdownTextView()
        tv.string = "abc"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.handleImageDrop(urls: makeImageURLs())
        XCTAssertEqual(tv.string, "![my photo](/tmp/my%20photo.png)abc")
        if let undo = tv.undoManager {
            undo.undo()
            XCTAssertEqual(tv.string, "abc", "撤销自动进 undo 栈（原生编辑链）")
        }
    }

    @MainActor
    func testImageURLsFiltersNonImageFiles() {
        let name = "image-drop-test-\(UUID().uuidString)"
        let pb = NSPasteboard(name: NSPasteboard.Name(name))
        pb.clearContents()
        pb.writeObjects([NSURL(fileURLWithPath: "/tmp/photo.png") as NSURL,
                         NSURL(fileURLWithPath: "/tmp/notes.md") as NSURL])
        let urls = MarkdownTextView.imageURLs(from: pb)
        XCTAssertEqual(urls.map(\.path), ["/tmp/photo.png"], "仅图片文件（.md 被过滤——非图片不拦截）")
        // ⚠️ doc-reviewer 复审 #1：fileURLs 谓词直接断言——FR-078 非回归保证
        //（非图片拖入 → 拒绝落窗口级 onDrop）的拒绝分支谓词必须有直接覆盖：
        // 若 fileURLs 被误加图片过滤（返回仅图片），拒绝分支静默失效而现有测试仍绿
        XCTAssertEqual(MarkdownTextView.fileURLs(from: pb).map(\.path),
                       ["/tmp/photo.png", "/tmp/notes.md"],
                       "fileURLs 返回全部文件（图片+非图片），拖拽拒绝分支依赖此全量谓词")
        pb.releaseGlobally()
    }

    // ⚠️ 修复（审查 IMPORTANT #1）：插入被拒（delegate shouldChangeText → false）→
    // handleImageDrop 返回 false（拖拽不消费，防图片无声丢失）
    @MainActor
    func testImageDropReturnsFalseWhenInsertRejected() {
        let tv = MarkdownTextView()
        tv.string = "abc"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.delegate = RejectingTextDelegate()
        XCTAssertFalse(tv.handleImageDrop(urls: makeImageURLs()), "插入被拒 → false（拖拽不消费）")
        XCTAssertEqual(tv.string, "abc", "文本不变")
        tv.delegate = nil
    }
}

// MARK: - FR-056 测试辅助（delegate 拒绝 shouldChangeText——NSTextViewDelegate 可构造）
private final class RejectingTextDelegate: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool { false }
}
