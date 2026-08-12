import Foundation
import AppKit

// MainContentState.swift — 每窗口状态容器（P1 后置：MainApp 拆分纯重构）
// 原 MainApp.swift 迁移（零行为变化；含 P1-1 editorRawText / P1-2 toggleFoldAtCursor 修正版）
// ⚠️ FixD（评审偏差）：toggleFoldAtCursor 从现行已修正 MainApp.swift 复制（非 batch-03.md 快照——
// 快照为修复前旧版，无 NSNotFound 守卫与 FoldMarker.rawLine 折叠感知映射）
// ⚠️ 修复 #2（第 9 轮）：状态容器化——WKWebView/parser/preprocessor/coordinator 全部移入
// MainContentState（@StateObject）。View struct 重建时（窗口恢复 isRestorable/Scene 重求值）
// StateObject 保留同一实例，避免"新 webview 创建、旧 coordinator 向已离树的旧 webview 发消息
// → 预览失效"。POC 验证模式是 @StateObject 容器（POC-S-003 HarnessViewModel），此处对齐。
// 批次 5（第 9/10 轮）：ThemeService 加入容器（生命周期与 webview 一致）；fileOps 由 App 注入
// ⚠️ 遗留 #7（批次 3）：fileOps 下沉——每窗口独立实例（方案①：单文档语义保持）
@MainActor
final class MainContentState: ObservableObject {
    let previewWebView = PreviewWebView()
    let parser = DownParser()
    let preprocessor = MermaidPreprocessor()
    var errorHandler = ErrorHandling()
    let coordinator: RenderCoordinator
    // ⚠️ 修复 #6（第 5 轮）+ 第 9 轮重构：差异式新增属性（MainContentState 内）——
    // 批次 3 已有成员（previewWebView/parser/preprocessor/errorHandler/coordinator）保持不动
    let imeHandling = IMEHandling()   // ⚠️ 第 10 轮：去 private（容器成员需 internal 供 MainContentAssembly 经 state. 访问）
    let scrollSync: ScrollSync        // 同上：容器成员 internal

    // 批次 5 新增（第 9/10 轮）+ 遗留 #7（批次 3）：
    let fileOps: FileOperations              // ⚠️ 遗留 #7：容器内部创建（每窗口实例），不再 App 注入
    let themeService: ThemeService           // ⚠️ 第 10 轮：去 private（容器成员供 MainContentAssembly 经 state. 访问）
    var themeIndex = 0                       // ⚠️ 修复 #3：容器为 class，普通 var 即允许闭包内自增（非 View 不可用 @State）
    // ⚠️ S-020：命令通道（每窗口实例，与 fileOps/themeService 同生命周期，设计 §4 方案 1）
    // Command channel (per-window instance, same lifecycle as fileOps/themeService, design §4 option 1)
    let shortcutManager = ShortcutManager()
    let commandExecutor: CommandExecutor
    // ⚠️ S-026/S-024：预览配置存储（UserDefaults）+ 最新编辑文本——
    // onSelectionDidChange 只带 NSRange，选区定位需要全文上下文；latestEditorText 由 body 的
    // onTextDidChange 闭包维护（避免 @State 捕获快照坑：SwiftUI 闭包捕获 View struct 快照不更新）
    let previewSettings: PreviewSettings
    var latestEditorText = ""
    // ⚠️ P1-1：编辑器原始文本（保存/导出数据源）——优先 textView.rawText（折叠态下
    // 完整原文）；未挂接 textView（previewOnly 模式/测试环境）回落 latestEditorText
    var editorRawText: String {
        commandExecutor.textView?.rawText ?? latestEditorText
    }
    // ⚠️ S-027：设置广播订阅 token（font/mermaidTheme/katexSingleDollar 键 → 预览下发；deinit 移除防泄漏）
    private var settingsObserver: NSObjectProtocol?
    // ⚠️ S-029：查找协调器（会话状态 + 匹配/替换执行；textView 经 attachTextView 注入）
    let findCoordinator = FindCoordinator()
    // ⚠️ S-030：自动保存调度器（attach 于 WindowCloseGuard.install——拿到 window 后；30s 定时 + 失焦）
    let autoSave = AutoSave()
    // ⚠️ S-031：导出管理器（HTML 组装 + PDF 打印）
    let exportManager = ExportManager()
    /// ⚠️ S-031：最近一次 renderDone 时间（onRenderDone 闭包维护；导出等待锚点）
    private(set) var lastRenderDoneAt: Date?

    // ⚠️ 第八轮修复（S-015/FR-083）：主题循环纯函数——跳过与当前 effectiveMode 相同的候选。
    // 三态 [light, dark, system] 中 system 在 dark 系统下解析为 dark → 从 dark 切 system 时
    // effectiveMode 不变 → 无视觉变化（用户感知"没反应"）；循环前进直到候选 effective ≠ 当前。
    // 终止性：light 与 dark 的 effective 永远不同 → repeat-while 必然 ≤3 步终止（无死循环）。
    // Pure function for theme cycling: skip candidates whose effective mode equals the current one.
    // - Parameters:
    //   - currentIndex: 当前主题索引（0=light, 1=dark, 2=system，与 themeIndex 对齐）
    //   - currentEffective: 当前 effectiveMode（ThemeService 已解析 system，永不为 .system）
    //   - resolveSystem: system 候选解析（生产默认 ThemeService.systemMode()；
    //     测试注入模拟系统外观——dark 系统 → .dark，light 系统 → .light）
    // - Returns: 下一个候选索引（其 effective ≠ currentEffective）
    static func nextThemeIndex(currentIndex: Int,
                               currentEffective: ThemeMode,
                               resolveSystem: (ThemeMode) -> ThemeMode = { _ in ThemeService.systemMode() }) -> Int {
        let modes: [ThemeMode] = [.light, .dark, .system]
        var candidate = currentIndex
        repeat {
            candidate = (candidate + 1) % modes.count
            let mode = modes[candidate]
            let effective = mode == .system ? resolveSystem(mode) : mode
            if effective != currentEffective { return candidate }
        } while true
    }

    // ⚠️ 遗留 #4（批次 2）：分栏三模式（S-022）——@Published 驱动 MainContentAssembly body 重算
    // ⚠️ S-028（批次 B）：初始值改由 init 注入（PaneSettings 读默认，FR-106——声明处不再给默认值；
    // 运行中切换仍由 @Published 驱动，保持现状）
    @Published var paneMode: PaneMode

    // ⚠️ T3.2（S-034）：聚焦模式正交标志——@Published 驱动 MainWindowView body 重算
    //（isFocusMode 注入；toggleFocusMode 翻转 + 工具栏隐藏，⌃⌘F 命令路由入口）
    @Published var isFocusMode = false
    // ⚠️ T3.2（FR-087）：状态栏开关——init 读 defaults（SettingsChangeKey.statusBarEnabled，
    // T3.5 SettingsApplier 写入端）；settingsObserver 广播重读实时生效
    @Published var showStatusBar = true
    // ⚠️ T3.2（S-034）：当前选区（onSelectionDidChange 闭包维护——与 latestEditorText 同模式，
    // 状态栏行列计数数据源；@Published 驱动选区移动 → statusText 重算）
    @Published var latestSelection = NSRange(location: 0, length: 0)

    // ⚠️ 遗留 #7：窗口 ↔ 状态关联注册表（weak-weak，防循环；key window 路由 + Cmd-Q 遍历数据源）
    private static let windowRegistry = NSMapTable<NSWindow, MainContentState>.weakToWeakObjects()
    // ⚠️ T3.2（S-034）：关联窗口（weak 防循环——AutoSave 同构；WindowCloseGuard 经 register 注入；
    // toggleFocusMode 工具栏隐藏消费；测试环境未注册 → nil 静默跳过）
    weak var window: NSWindow?

    /// 新建窗口动作（MainContentAssembly.onAppear 注册 openWindow(id: "editor")；
    /// 菜单 Cmd-N 经此触发——.commands 闭包无 @Environment(\.openWindow) 访问权）
    static var openWindowHandler: (() -> Void)?
    /// 与 openWindowHandler 配对的场景 token（onDisappear 仅清空指向本窗口的闭包）
    static var openWindowHandlerToken: ObjectIdentifier?
    /// 兜底建窗（AppDelegate 注册；drain 无 handler 可用时调用——冷启动外部事件启动）
    static var manualWindowCreator: (() -> Void)?
    static var manualWindowCreated = false
    /// App 级待打开文件队列（FIFO；替代单槽位 pendingOpenURL——多请求竞态不丢失）
    static var pendingOpenURLs: [URL] = []
    /// 是否已注册过窗口（冷启动歧义判定：首窗注册前 = 默认窗口可能将至，须延时决策）
    static var hasEverRegisteredWindow = false
    private static var drainScheduled = false   // drain 互斥：同一时刻至多一个在途
    private static var drainSpinCount = 0        // drain 自旋计数（防无窗口永久空转）
    static let drainMaxSpins = 60                // 30s 上限

    /// 当前文档关联文件（standardized；nil = 空白窗口）
    var currentFileURL: URL? { fileOps.currentFileURL }

    /// 文件 → 窗口映射（线性扫描 allStates；standardized 归一化比较）
    static func state(forFile url: URL) -> MainContentState? {
        let target = url.standardizedFileURL
        return allStates.first { $0.currentFileURL == target }
    }

    /// 空白窗口：从未打开/新建过文档（currentDocument == nil），或未编辑的 Untitled。
    /// 接管它不会覆盖任何用户内容——"绝不出现空白窗口"的安全垫
    static func firstBlankState() -> MainContentState? {
        allStates.first { state in
            guard let doc = state.fileOps.currentDocument else { return true }
            return doc.fileURL == nil && !doc.hasUnsavedChanges
        }
    }

    /// 待打开队列即时接管：空白窗口注册时调用（冷启动竞态窗口：注册即渲染）
    static func consumePendingIfBlank(_ state: MainContentState) {
        // ⚠️ 修复 D：onTextRead 未挂接时不消费（WindowCloseGuard 可能先于 onAppear 执行 →
        // open 时回填闭包未就绪 → 文件打开但编辑器空白）；onAppear 兜底消费
        guard state.fileOps.onTextRead != nil,
              state.fileOps.currentDocument == nil,
              let url = pendingOpenURLs.first else { return }
        pendingOpenURLs.removeFirst()
        state.fileOps.open(url: url)
    }

    /// 请求建窗统一入口：**不直接建窗**——统一走 drain（500ms 延时）：
    /// ① 系统双击自动创建的默认窗口先出现 → drain 空白接管复用（单窗口）
    /// ② 若 drain 时仍无空白窗口（运行中无窗口且系统未建）→ 兜底建窗
    /// 修复（双窗口根因）：此前 hasEver=true 直接建窗 → 与系统默认窗口双建
    static func requestWindow() {
        scheduleDrain()
    }

    static func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            drainScheduled = false
            drainSpinCount += 1
            drainPendingOpen()
        }
    }

    /// 队列处理（drain）：空白接管队首 → 仍非空则请求建窗
    static func drainPendingOpen() {
        if let blank = firstBlankState(), let url = pendingOpenURLs.first {
            pendingOpenURLs.removeFirst()
            blank.fileOps.open(url: url)
        }
        // 仍非空 → 无空白窗口可接管 → 兜底建窗
        if !pendingOpenURLs.isEmpty {
            if MainContentState.openWindowHandler != nil {
                MainContentState.openWindowHandler?()
            } else if drainSpinCount < 2 {
                // 1s 宽限：等待场景物化（快启动竞态）
                scheduleDrain()
            } else if let creator = MainContentState.manualWindowCreator,
                      !MainContentState.manualWindowCreated {
                // ⚠️ 修复（冷启动不弹窗）：场景无法物化（handlesExternalEvents 关闭）→
                // 手动建窗兜底（单次防双窗；窗口 onAppear 注册 handler + 消费 pending）
                MainContentState.manualWindowCreated = true
                creator()
            } else {
                NSLog("[DIAG-DRAIN] pending 残留 %d", pendingOpenURLs.count)
            }
        }
    }

    // ⚠️ 遗留 #7：init() 无参（fileOps 容器内创建）；其余原 init 内容
    //（errorHandler/coordinator/scrollSync/回调接线/themeService）保留
    // ⚠️ S-028（批次 B）：defaults 注入参数（PaneSettings 读默认；测试注入 suiteName 隔离——
    // MainContentStateTests 改造，防本机存储干扰断言）
    init(defaults: UserDefaults = .standard) {
        self.fileOps = FileOperations(defaults: defaults)   // ⚠️ S-030：defaults 注入（RecentFiles 隔离）
        // ⚠️ S-028（盲审 #1 修复）：previewSettings 同源注入——声明处 .standard 绑定使
        // makeDefaults() 隔离失效（onChange 测试写真实 .standard → 污染 testInitSendsPreviewConfig
        // 字面量断言，实测第二次运行必红）；生产 defaults 默认 .standard，行为不变。
        // 须在首个 self 捕获闭包（commandExecutor.onTogglePane）之前赋值
        previewSettings = PreviewSettings(defaults: defaults)
        // ⚠️ S-028：默认分栏模式注入（PaneSettings 读默认，FR-106——仅启动/新窗口；
        // 运行中 @Published 驱动保持现状，设计 §数据流）
        paneMode = PaneSettings(defaults: defaults).paneMode
        // ⚠️ T3.2（FR-087）：状态栏开关初始值——defaults 读取（SettingsChangeKey.statusBarEnabled，
        // T3.5 SettingsApplier 写入端）；未设置回落 true（与 MainWindowView 默认一致）。
        // 置于首个捕获 self 闭包（commandExecutor.onTogglePane）之前——Swift 存储属性初始化顺序
        let storedStatusBar = defaults.object(forKey: SettingsChangeKey.statusBarEnabled)
        showStatusBar = storedStatusBar == nil ? true : defaults.bool(forKey: SettingsChangeKey.statusBarEnabled)
        // ⚠️ 修复 #3（第 5 轮）：ErrorHandling 是 struct（值语义）——
        // onReport 必须在 coordinator 创建【之前】赋值（容器内同一实例，链路生效）
        errorHandler.onReport = { error in
            NSLog("[RenderPipeline] %@", String(describing: error))
        }
        coordinator = RenderCoordinator(
            parser: parser,
            preprocessor: preprocessor,
            errorHandler: errorHandler,
            preview: previewWebView,
            defaults: defaults   // ⚠️ T3.3（FR-104）：defaults 注入——init 读 debounce 配置（隔离测试同源）
        )
        // ⚠️ 修复 B：scrollSync 必须在闭包引用前初始化（否则 'self' used before all stored properties initialized）。
        // 注意：此赋值位于 init() 内（属性声明块之后、闭包赋值之前），非类体顶层语句。
        scrollSync = ScrollSync(preview: previewWebView)
        // renderDone 回调 → ScrollSync 同步时机（FR-016）
        previewWebView.onRenderDone = { [weak scrollSync] payload in
            NSLog("[Preview] renderDone status=%@ elapsed=%.0fms", payload.status, payload.elapsed)
            scrollSync?.previewRenderDone(payload)
        }
        // ⚠️ 修复 #4-③：注入前通知 ScrollSync 挂起渲染计时（超时跳过的基础）
        coordinator.onWillInject = { [weak scrollSync] in
            scrollSync?.renderRequested()
        }
        // IME 挂接：compose → 暂停渲染；上屏 → 恢复并立即渲染（S-008）
        imeHandling.onComposeStateChange = { [weak coordinator] composing in
            if composing {
                coordinator?.pause()
            } else {
                coordinator?.resume()
            }
        }
        // renderDone / error 回调：批次 4（ScrollSync）/批次 5（状态栏）接线点
        previewWebView.onErrorOccurred = { phase, message in
            NSLog("[Preview] errorOccurred phase=%@ message=%@", phase, message)
        }
        previewWebView.onLinkClicked = { url in
            // ⚠️ Epic-5 P3（backlog）：scheme 白名单——http/https/mailto 放行，其余拒绝
            guard PreviewWebView.isOpenableScheme(url) else {
                NSLog("[Preview] linkClicked 拒绝 scheme=%@", url.scheme ?? "nil")
                return
            }
            NSWorkspace.shared.open(url)   // FR-029 基础：外链系统浏览器打开
        }
        // 主题服务：容器内创建（生命周期与 webview 一致）——双轨下发 ① 编辑器外观经通知广播
        //（AD-10 ①：editorThemeDidChange 广播——MarkdownTextView 订阅，批次 1 #5 实装）
        // ⚠️ 已知限制（plan-index 记录）：多窗口各自广播，编辑器侧全局同步、非活动窗口 preview
        // CSS 不同步（半同步）；v2 解决跨窗口主题广播
        let theme = ThemeService(
            preview: previewWebView,
            editorSink: { mode in
                NotificationCenter.default.post(name: .editorThemeDidChange, object: mode)
            }
        )
        themeService = theme   // ⚠️ 修复 #7：直接赋存储属性；删除无效的 _themeService = StateObject(...)
        theme.apply()   // 启动即应用已存主题（FR-105，随 T5.3 同源修复）
        themeIndex = [ThemeMode.light, .dark, .system].firstIndex(of: theme.mode) ?? 0   // 初值与实际主题对齐
        // ⚠️ deep-analysis 条件项修复：webview didFinish 后重放主题（启动首帧竞态——
        // init 时 apply() 的 setTheme 在页面未就绪时丢失，didFinish 重发闭合 FR-105）
        previewWebView.onPageLoaded = { [weak themeService] in
            themeService?.apply()
        }
        // ⚠️ S-020：命令通道接线——executor 每窗口实例；togglePane 布局命令 → paneMode 循环
        //（PaneMode.next：editorOnly→previewOnly→split；编辑器文本命令经 attachTextView 注入
        //  textView 后走 performFormatting，见 attachTextView）
        // Command channel wiring — per-window executor; togglePane layout command cycles paneMode
        // (PaneMode.next: editorOnly→previewOnly→split; editor text commands reach the textView
        // injected via attachTextView, then flow through performFormatting — see attachTextView)
        // ⚠️ 适配：commandExecutor 赋值须在捕获 self 的闭包创建之前（Swift 存储属性初始化顺序——
        // 闭包捕获 self 要求全部存储属性已就绪，否则 'self.commandExecutor used before initialized'）
        // Adaptation: commandExecutor must be assigned before the self-capturing closure is created
        // (Swift stored-property init order — a closure capturing self requires every stored
        // property to be initialized first)
        let executor = CommandExecutor()
        self.commandExecutor = executor
        executor.onTogglePane = { [weak self] in
            guard let self else { return }
            self.paneMode = self.paneMode.next
        }
        shortcutManager.registerDispatcher(executor)
        // ⚠️ S-030：自动保存写盘入口（失焦/30s 定时 → fileOps.autoSave——仅已保存路径，保留 edited 标记）
        autoSave.onAutoSave = { [weak self] in
            self?.fileOps.autoSave()
        }
        // ⚠️ S-031（审查 CRITICAL #1 修订）：onRenderDone 整体重赋值（含导出等待锚点）——
        // 原 217 行闭包保持不动；此处 commandExecutor 已赋值（存储属性初始化顺序约束，见本文件 L217 适配注释），
        // 捕获 [weak self] 安全；scrollSync 为 init 局部常量，仍在作用域
        previewWebView.onRenderDone = { [weak scrollSync, weak self] payload in
            NSLog("[Preview] renderDone status=%@ elapsed=%.0fms", payload.status, payload.elapsed)
            self?.lastRenderDoneAt = Date()   // ⚠️ S-031：导出等待锚点（renderDone 时序）
            scrollSync?.previewRenderDone(payload)
        }
        // ⚠️ S-026：预览配置下发（mermaid 主题 + 单$开关，FR-035/046）——
        // 页面未就绪时自动缓冲（PreviewWebView.pendingConfig），didFinish flush 闭合（T3.2）
        // ⚠️ 适配：置于 commandExecutor 初始化之后（Swift 存储属性初始化顺序——调用 self 方法
        // 要求全部存储属性就绪；themeIndex 行处 commandExecutor 尚未赋值，会编译错误）
        // Adaptation: placed after commandExecutor is assigned (Swift stored-property init order —
        // calling a self method requires every stored property ready; at the themeIndex line
        // commandExecutor is not yet assigned and would fail to compile)
        previewWebView.setConfig(PreviewConfig(
            mermaidTheme: previewSettings.effectiveMermaidTheme(),
            katexSingleDollar: previewSettings.katexSingleDollar
        ))
        // ⚠️ S-027：启动下发预览字体（FontSettings 派生 CSS 族；未就绪缓冲 pendingFont，
        // didFinish flush——与 setConfig 同模式；fontName 未设置时下发默认栈 = 现状视觉零变化）
        let fontSettings = FontSettings(defaults: defaults)
        previewWebView.setFont(fontFamily: fontSettings.previewBodyFontFamily,
                               codeFontFamily: fontSettings.previewCodeFontFamily)
        // ⚠️ S-028：PreviewSettings.onChange → setConfig 重发（补 S-026"仅 init 一次性下发"缺口；
        // 面板 Mermaid 主题/单$ 变更实时生效，FR-102/103）
        previewSettings.onChange = { [weak self] _ in
            guard let self else { return }
            self.previewWebView.setConfig(PreviewConfig(
                mermaidTheme: self.previewSettings.effectiveMermaidTheme(),
                katexSingleDollar: self.previewSettings.katexSingleDollar))
        }
        // ⚠️ S-027：设置广播订阅（object: nil 全局——与 editorThemeDidChange 半同步模式一致：
        // 活动窗口即时生效，非活动窗口 setFont/setConfig 幂等下发无害）
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .editorSettingsDidChange, object: nil, queue: .main)
        { [weak self] note in
            let keys = (note.userInfo?[SettingsNotificationUserInfoKey.changedKeys] as? [String]) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                if keys.contains(SettingsChangeKey.font) {
                    let fs = FontSettings(defaults: defaults)
                    // 预览字体
                    self.previewWebView.setFont(fontFamily: fs.previewBodyFontFamily,
                                                codeFontFamily: fs.previewCodeFontFamily)
                    // 编辑器字体（修复：之前只更新预览，编辑器字体不变+高亮消失）
                    if let tv = self.commandExecutor.textView {
                        tv.applyFontChange(fs.font)
                    }
                }
                // ⚠️ T2.5 评审裁决（批次 B 计划缺口修复，必须）：面板 SettingsApplier 的
                // PreviewSettings 与容器 previewSettings 是两个实例——onChange 链路对面板
                // 写入不触发；此处按键重读 defaults 现读重发（defaults 为真源 + 广播为
                // 通知通道，与"订阅端幂等重读"契约一致；FR-102/103 实时生效，M4/M5 验收）
                if keys.contains(SettingsChangeKey.mermaidTheme)
                    || keys.contains(SettingsChangeKey.katexSingleDollar) {
                    let fresh = PreviewSettings(defaults: defaults)
                    self.previewWebView.setConfig(PreviewConfig(
                        mermaidTheme: fresh.effectiveMermaidTheme(),
                        katexSingleDollar: fresh.katexSingleDollar))
                }
                // ⚠️ T3.2（FR-087）：状态栏开关广播——面板写 defaults + post → 重读现读生效
                //（defaults 为真源 + 广播为通知通道，与"订阅端幂等重读"契约一致；T3.5 写入端）
                if keys.contains(SettingsChangeKey.statusBarEnabled) {
                    let stored = defaults.object(forKey: SettingsChangeKey.statusBarEnabled)
                    self.showStatusBar = stored == nil ? true : defaults.bool(forKey: SettingsChangeKey.statusBarEnabled)
                }
                // ⚠️ T3.3（FR-104）：debounce 时长广播——面板写 defaults + post → 重读 clamp 生效
                //（defaults 为真源 + 广播为通知通道，与"订阅端幂等重读"契约一致；100-1000ms）
                if keys.contains(SettingsChangeKey.renderDebounce) {
                    let stored = defaults.object(forKey: SettingsChangeKey.renderDebounce) as? Int
                    self.coordinator.debounceInterval = Double(RenderCoordinator.clampDebounce(stored ?? 300)) / 1000
                }
            }
        }
        // ⚠️ 第 10 轮修正：onTextRead 接线移到 MainContentAssembly（editorText 是其 @State，
        // 容器内无此成员）；此处仅定义回填入口，由 assembly 在 onAppear 挂接
    }

    /// ⚠️ S-020：编辑器上报入口（EditorView.onTextViewCreated → 注入 executor）
    /// 每窗口唯一 textView（NSViewRepresentable 单实例），重复上报幂等
    /// Editor attach entry (EditorView.onTextViewCreated → inject executor);
    /// one textView per window (single NSViewRepresentable instance), idempotent re-report
    func attachTextView(_ textView: MarkdownTextView) {
        commandExecutor.textView = textView
        findCoordinator.textView = textView   // ⚠️ S-029：查找/替换目标注入
    }

    // ⚠️ P1-2：折叠菜单路由——光标所在行 → toggleFold（原文行锚定）；
    // 折叠态下显示文本行号 ≠ 原文行号，须经 FoldMarker 折叠感知映射
    //（评审 CRITICAL #1 修正：selectedRange 是显示文本索引，直接对 rawText 做
    // lineNumber 会在光标上方存在折叠时错位 → 误折叠/误展开上方折叠；
    // FoldMarker.rawLine 做显示行 → 原文行映射）；
    // 未挂接 textView（previewOnly/测试）→ 静默（execute 先例）
    func toggleFoldAtCursor() {
        guard let tv = commandExecutor.textView else { return }
        let location = tv.selectedRange().location
        guard location != NSNotFound else { return }   // 评审 MINOR #4：无选区防护
        let line = FoldMarker.rawLine(at: location, display: tv.string, raw: tv.rawText,
                                      folded: tv.foldState.folded)
            ?? max(LineNumbers.lineNumber(forCharacterIndex: location, in: tv.rawText) - 1, 0)
        tv.toggleFold(at: line)
    }

    // ⚠️ T3.2（S-034）：聚焦模式翻转——@Published 驱动 MainWindowView body 重算（isFocusMode 注入）；
    // 工具栏隐藏经关联窗口（register 注入的 weak window——WindowCloseGuard 同构拿 window）；
    // 测试环境无窗口 → window nil，工具栏操作静默跳过（仅翻转语义生效）
    // ⚠️ 盲审 IMPORTANT-1 修复：记录进入聚焦前的工具栏可见性，退出恢复原值（不覆盖 ⌥⌘T 手动隐藏）
    private var priorToolbarVisible = true

    func toggleFocusMode() {
        isFocusMode.toggle()
        if isFocusMode {
            priorToolbarVisible = window?.toolbar?.isVisible ?? true
            window?.toolbar?.isVisible = false
        } else {
            window?.toolbar?.isVisible = priorToolbarVisible
        }
    }

    // MARK: - 窗口关联（遗留 #7，Open Question #1 定稿：NSMapTable 注册表）
    // 注册时机：WindowCloseGuard 安装时（拿到 window 后）——view 层唯一 window 持有者

    static func register(_ state: MainContentState, for window: NSWindow) {
        hasEverRegisteredWindow = true
        // 迁移守卫对称修复：同一 state 已注册到其他存活窗口时先解除旧映射，
        // 防 allStates 重复（Cmd-Q 重复确认）与注册表残留（weak-weak 表不自动清理同 state 多 key）
        // Migration-guard symmetric fix: if the same state is already registered to another
        // living window, unbind the stale mapping first — prevents duplicate allStates entries
        // (Cmd-Q double confirmation) and registry residue (weak-weak table never auto-cleans
        // the same state under multiple keys)
        // 适配：keyEnumerator() 返回非 Optional NSEnumerator（objectEnumerator() 才是 Optional）——
        // 删除 if let 包装，直接遍历（语义不变：仅命中同 state 的旧窗口键才 remove）
        // Adaptation: keyEnumerator() returns a non-optional NSEnumerator (unlike
        // objectEnumerator()) — drop the if-let wrapper and iterate directly (same
        // semantics: only remove keys mapping to the same state on a different window)
        let enumerator = windowRegistry.keyEnumerator()
        for case let old as NSWindow in enumerator.allObjects where old !== window {
            if windowRegistry.object(forKey: old) === state {
                windowRegistry.removeObject(forKey: old)
            }
        }
        state.window = window   // ⚠️ T3.2：关联窗口注入（toggleFocusMode 工具栏隐藏数据源）
        windowRegistry.setObject(state, forKey: window)
    }

    static func state(for window: NSWindow) -> MainContentState? {
        windowRegistry.object(forKey: window)
    }

    /// 窗口关闭时注销（真机验收修复）：weak-weak 表依赖 state 释放才自动清除，
    /// 而 @StateObject 延迟释放 → 已关窗口 state 残留 allStates → Cmd-Q 重复确认；
    /// 显式注销保证关闭即从路由/退出遍历数据源移除
    static func unregister(_ state: MainContentState, for window: NSWindow) {
        if windowRegistry.object(forKey: window) === state {
            windowRegistry.removeObject(forKey: window)
        }
    }

    /// 所有存活窗口的 state（Cmd-Q 退出确认遍历；weak 注册表自动剔除已关窗口）
    static var allStates: [MainContentState] {
        var result: [MainContentState] = []
        let enumerator = windowRegistry.objectEnumerator()
        while let state = enumerator?.nextObject() as? MainContentState {
            result.append(state)
        }
        return result
    }

    deinit {
        // ⚠️ Swift 6 语言模式：deinit nonisolated——assumeIsolated 显式断言（MarkdownTextView deinit 先例）
        MainActor.assumeIsolated {
            // 批次1 内存诊断埋点（D3）：验证 @StateObject 是否随窗口关闭释放（设计 §批次1 根因③）
            // Leak probe (batch 1, D3): verify @StateObject dealloc on window close.
            NSLog("[LEAK] MainContentState dealloc")
            if let settingsObserver {
                NotificationCenter.default.removeObserver(settingsObserver)
            }
        }
    }
}
