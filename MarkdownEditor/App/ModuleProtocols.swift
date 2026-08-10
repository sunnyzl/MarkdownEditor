import AppKit

// ModuleProtocols.swift — AD-2 跨模块协议（6 模块边界，跨模块通信唯一通道）
// 消息协议 schema 定稿（设计 §5.1）：Swift enum/struct 与 MessageBridge.js 常量锁定

// 主题模式（AD-10；S-015 ThemeService 单一事实源）
enum ThemeMode: String, CaseIterable, Codable {
    case light, dark, system
}

// ── Preview 模块协议（S-009 PreviewWebView 实现）──
// Swift → Web 四入口 + Web → Swift 三回调（设计 §5.1）
// ⚠️ 修复 #2：@MainActor 标注（PreviewWebView 是 @MainActor，非隔离协议会导致
//   Swift 6 语言模式 #ConformanceIsolation 编译错误；ScrollSync/ThemeService/测试 Mock 均受益）
@MainActor
protocol PreviewProtocol: AnyObject {
    /// 阶段 4 注入入口：window.setContent(html)（morphdom 主 + innerHTML 兜底，JS 侧实现）
    func setContent(_ html: String)
    /// 主题双轨下发：window.setTheme(mode)（AD-10）
    func setTheme(_ mode: ThemeMode)
    /// 预览配置下发：window.setConfig(config)（S-026，mermaid 主题 + katex 单$开关，FR-035/046）
    func setConfig(_ config: PreviewConfig)
    /// 滚动同步：window.setViewport(scrollTop)（S-013）
    func setViewport(_ scrollTop: Double)
    /// 精确滚动同步（S-032/T1.4）：window.setScrollToSource(startLine, endLine)
    /// （T1.5 已交付 JS 入口；source map 命中块 → 精确行定位，与比例路径共存）
    func setViewportSource(_ startLine: Int, _ endLine: Int)
    /// renderDone 回调（FR-016 时机，驱动 ScrollSync）
    var onRenderDone: ((RenderDonePayload) -> Void)? { get set }
    /// linkClicked 回调（外链上报，S-025 增强）
    var onLinkClicked: ((URL) -> Void)? { get set }
    /// errorOccurred 回调（NFR-012 基础容错）
    var onErrorOccurred: ((String, String) -> Void)? { get set }
}

// ── S-026 预览配置（FR-035/046/047；Swift → JS window.setConfig 契约）──
struct PreviewConfig: Equatable {
    /// Mermaid 主题（default/dark/forest/neutral——跟随已由 PreviewSettings 解析为具体值）
    let mermaidTheme: String
    /// 单 $ 分隔符开关（false 时 JS 移除 $ 单分隔符，R-M1 缓解）
    let katexSingleDollar: Bool
}

// renderDone payload（设计 §5.1：status/error/scrollHeight + elapsed 埋点扩展）
// ⚠️ Epic-6 T1.4：sourceMap 字段（data-sourcepos 字符串数组，JS 侧 T1.5 上报）
// ⚠️ Swift 语义适配：memberwise init 对带默认值的 let 属性不生成参数（"extra argument"编译错误），
// 显式 init 带默认参数恢复同等契约——现有 4 参数调用（sourceMap 省略 → []）与新增 5 参数调用均兼容
struct RenderDonePayload {
    let status: String
    let error: String?
    let scrollHeight: Double
    let elapsed: Double
    /// 精确滚动同步 source map（S-032/T1.4：字符串数组，Swift 侧透传不解析，ScrollSync 消费）
    /// 仅 setContent 上报点携带（setTheme/setConfig/setFont 无此字段）→ 默认 []
    let sourceMap: [String]

    init(status: String, error: String?, scrollHeight: Double, elapsed: Double, sourceMap: [String] = []) {
        self.status = status
        self.error = error
        self.scrollHeight = scrollHeight
        self.elapsed = elapsed
        self.sourceMap = sourceMap
    }
}

// ── RenderPipeline 模块协议（S-010 实现方依赖）──
protocol MarkdownParsing {
    /// 阶段 2：Markdown → HTML（Down-gfm；GFM 由 GfmPostProcessor 后处理（S-011，批次 4））
    func render(markdown: String) throws -> String
}

protocol MermaidPreprocessing {
    /// 阶段 3：Mermaid 代码块转换（Swift 正则主，设计 §5.2 方案 B）
    func transform(html: String) -> MermaidTransformResult
}

// 转换结果：needsJsFallback = 正则未覆盖残留（触发 JS DOM 兜底，方案 A）
struct MermaidTransformResult {
    let html: String
    let needsJsFallback: Bool
}

// ── Editor 模块协议（S-007 MarkdownTextView 实现）──
// ⚠️ 修复 C2（第 7 轮）：@MainActor — MarkdownTextView 继承 NSTextView（@MainActor 隔离），
// 非隔离协议会触发 #ConformanceIsolation 编译错误（与 PreviewProtocol 修复 #2 同源）
@MainActor
protocol EditorEventSource: AnyObject {
    /// IME compose 状态变化（S-008：compose 暂停渲染，上屏恢复）
    var onComposeStateChange: ((Bool) -> Void)? { get set }
}

// ── File 模块协议（S-014 FileOperations 实现）──
// ⚠️ 修复 F1（第 8 轮）：@MainActor — 唯一 conformer 是 FileOperations（已 @MainActor），
// 与 EditorEventSource/PreviewProtocol 的隔离原则一致（complete 严格模式下才成编译错误）
@MainActor
protocol DocumentHandling: AnyObject {
    func newDocument()
    func openDocument()
    func saveDocument()
    func saveDocumentAs()
}

// ⚠️ 修复 #7（第 7 轮）：ThemeSink 协议删除——无任何 conform 者（ThemeService 用闭包注入
// editorSink 实现双轨下发，AD-2"唯一通信通道"由闭包承担）；保留死协议误导实施者

// ── S-027/S-028 设置广播契约（Settings scene → 各模块；与 editorThemeDidChange 同构）──
// 广播链路（设计 §S-028）：设置面板写 defaults（经 SettingsApplier）→
// post .editorSettingsDidChange(userInfo: [changedKeys: [String]]) →
// 各模块按变更键应用（MarkdownTextView 字体/高亮开关；MainContentState 预览字体 setFont）
extension Notification.Name {
    /// 设置变更广播（userInfo 携带 changedKeys 变更键集合——订阅端按键应用）
    static let editorSettingsDidChange = Notification.Name("editorSettingsDidChange")
}

/// 设置广播 userInfo 键（S-028）
enum SettingsNotificationUserInfoKey {
    /// 变更键集合键（值为 [String]，见 SettingsChangeKey）
    static let changedKeys = "changedKeys"
}

/// 设置变更键（S-028：各模块按键订阅应用；与 S-028 六项设置一一对应）
enum SettingsChangeKey {
    /// 编辑器/预览字体（S-027，FR-101）——订阅端：MarkdownTextView.applyUserFont + MainContentState 预览 setFont
    static let font = "font"
    /// Mermaid 主题（FR-102）——订阅端：PreviewSettings.onChange → setConfig 重发
    static let mermaidTheme = "mermaidTheme"
    /// 单 $ 分隔符开关（FR-103）——同上
    static let katexSingleDollar = "katexSingleDollar"
    /// 编辑器内语法高亮开关（FR-108）——订阅端：MarkdownTextView.applyHighlightSwitch（清除/重放）
    static let highlightEnabled = "highlightEnabled"
    /// 行号开关（FR-107）——仅存储（S-029 消费；"实时生效" AC 时序矛盾显式记录）
    static let lineNumbersEnabled = "lineNumbersEnabled"
    /// 默认分栏模式（FR-106）——仅存储（新窗口/启动生效；运行中 @Published 驱动保持现状）
    static let paneMode = "paneMode"
    /// 状态栏开关（FR-087）——⚠️ T3.2 先加键（MainContentState 订阅读 defaults）；
    /// T3.5 SettingsApplier.setStatusBarEnabled 补写入端（写 defaults + 广播）
    static let statusBarEnabled = "statusBarEnabled"
    /// debounce 时长（FR-104，T3.3）——订阅端：MainContentState.settingsObserver 重读 clamp →
    /// coordinator.debounceInterval = clamp/1000；写入端：SettingsApplier.setRenderDebounce（T3.3 就绪）
    static let renderDebounce = "renderDebounce"
    /// 自动缩进开关（FR-007，T3.5）——写入端：SettingsApplier.setAutoIndentEnabled
    ///（写 AutoIndent.enabledKey "autoIndentEnabled" 同键）；批次 2 AutoIndent.isEnabled 消费
    static let autoIndentEnabled = "autoIndentEnabled"
    /// 括号配对开关（FR-007，T3.5）——写入端：SettingsApplier.setAutoPairEnabled
    ///（写 AutoPair.enabledKey "autoPairEnabled" 同键）；批次 2 AutoPair.isEnabled 消费
    static let autoPairEnabled = "autoPairEnabled"
}
