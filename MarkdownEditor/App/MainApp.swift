import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MainApp.swift — SwiftUI 应用入口（S-006）+ S-010 集成连线（批次 3）
// 组装：RenderCoordinator（5 阶段管线）← MarkdownTextView.textDidChange
//       → DownParser → MermaidPreprocessor → PreviewWebView.setContent
// 预览加载由 PreviewWebView 内部 loadFileURL 完成（AD-5）
// 批次 5（T5.4）：File（S-014）+ Theme（S-015）挂接——fileOps 上提 App 级、
// themeService 入状态容器、关闭确认经 WindowCloseGuard 挂接（FR-076）
// ⚠️ 遗留 #7（批次 3）：多窗口路由（方案①）——fileOps 从 App 级下沉 MainContentState
//（每窗口独立实例，消除多窗口互相覆盖 currentDocument 的结构性矛盾）；
// Cmd-N = openWindow 新建窗口；打开/保存/另存为走 key window 路由（NSApp.keyWindow → 关联 state）；
// Cmd-Q = applicationShouldTerminate 遍历所有窗口确认（NFR-011 防丢数据）
@main
struct MarkdownEditorApp: App {
    // ⚠️ 遗留 #7：App 级 fileOps 删除（下沉至每窗口 MainContentState 实例）；
    // init() 的 shouldCloseHandler 挂接删除（Cmd-Q 由 AppDelegate 遍历 windowRegistry）
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // ⚠️ S-030：最近文件菜单动态数据源——通知驱动重载（@Published urls 更新），
    // @StateObject objectWillChange 触发 App.body（含 .commands）重算（审查 MINOR #4 修正）
    @StateObject private var recentFilesMenu = RecentFilesMenuModel()
    // ⚠️ T3.4（FR-065）：快捷键菜单动态刷新数据源——defaults 变化 → version +1 →
    // @StateObject objectWillChange → App.body（含 .commands 格式菜单）重算 → mergedBindings 重读
    //（RecentFilesMenuModel 同模式；"不依赖 keyWindowState"约束保持——刷新经 defaults 通知 + 纯静态查询）
    @StateObject private var shortcutMenuModel = ShortcutMenuModel()

    var body: some Scene {
        // ⚠️ 遗留 #7：WindowGroup 加 id（openWindow(id:) 新建窗口）；fileOps 注入移除（容器自建）
        WindowGroup(id: "editor") {
            MainContentAssembly()
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // ⚠️ 遗留 #7：文件菜单改 key window 路由（每窗口独立 fileOps）
            // Cmd-N 语义定稿（修复 #4/第 1 轮）：= 新建窗口（openWindowHandler 经静态注册；
            // commands 闭包无 @Environment(\.openWindow) 访问权）
            CommandGroup(replacing: .newItem) {
                Button("新建窗口") { MainContentState.openWindowHandler?() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("打开…") { openFileFromMenu() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("保存") { keyWindowState()?.fileOps.saveDocument() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("另存为…") { keyWindowState()?.fileOps.saveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // ⚠️ 修复（round5 T1.2）：预览缩放快捷键（⌘+ / ⌘- / ⌘0）——经 keyWindowState
            // 路由到当前窗口 previewWebView（与文件菜单同模式；多窗口各自缩放）
            CommandGroup(after: .newItem) {
                Button("放大预览") { keyWindowState()?.previewWebView.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小预览") { keyWindowState()?.previewWebView.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("实际大小") { keyWindowState()?.previewWebView.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            // ⚠️ S-029：查找命令——显式接管 Cmd+F/G/Shift+G（SwiftUI 默认 Edit 菜单
            // 存在性 ⚠️ UNVERIFIED，设计不依赖；若与默认菜单冲突，手动验收确认行为）
            CommandGroup(after: .newItem) {
                Button("查找…") { keyWindowState()?.findCoordinator.show() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("查找下一个") { keyWindowState()?.findCoordinator.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("查找上一个") { keyWindowState()?.findCoordinator.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                // ⚠️ S-031：导出（HTML 异步链路 Task；PDF printOperation 模态）
                Button("导出 HTML…") {
                    guard let state = keyWindowState() else { return }
                    Task {
                        await state.exportManager.exportHTML(
                            webView: state.previewWebView,
                            renderDoneTimestamp: { state.lastRenderDoneAt })
                    }
                }
                Button("导出 PDF…") {
                    guard let state = keyWindowState() else { return }
                    Task {
                        await state.exportManager.exportPDF(
                            webView: state.previewWebView,
                            renderDoneTimestamp: { state.lastRenderDoneAt })
                    }
                }
                // ⚠️ T4.3（FR-093）+ P1-1：纯 Markdown 导出/复制（原始源码，无渲染——editorRawText 直出；
                // 命名区分编辑器选区复制：菜单项"复制 Markdown 源码" vs 编辑器内选区 Cmd+C）
                Button("导出 Markdown…") {
                    guard let state = keyWindowState() else { return }
                    state.exportManager.exportMarkdown(text: state.editorRawText, from: state.window)
                }
                Button("复制 Markdown 源码") {
                    guard let state = keyWindowState() else { return }
                    ExportManager.copyMarkdown(state.editorRawText)
                }
                Divider()
                // ⚠️ S-030：最近文件子菜单（动态数据源；空列表不显示）
                if !recentFilesMenu.urls.isEmpty {
                    Menu("最近文件") {
                        ForEach(recentFilesMenu.urls, id: \.self) { url in
                            Button(url.lastPathComponent) { openRecentFromMenu(url) }
                        }
                        Divider()
                        Button("清除最近文件") { RecentFiles.clear() }
                    }
                }
            }
            // ⚠️ S-020/T3.4：格式菜单——声明式数据驱动（ForEach + keyboardShortcut 从
            // mergedBindings 读取（defaults 覆盖 defaultBindings，FR-065），审查 IMPORTANT #3：
            // 菜单构建不依赖 keyWindowState）；Button action 走 keyWindowState 路由（与文件菜单
            // 同模式，设计 §4 方案 1）；T3.4 起菜单动态刷新由 ShortcutMenuModel 驱动
            //（defaults 通知 → version +1 → .commands 重算，审查 MINOR #4 修正）；
            // makeMenuItems 仅作测试面不注入 mainMenu（方案 2 拒绝理由：场景重建菜单丢失/重复）
            // Format menu — declarative data-driven (ForEach + keyboardShortcut read from
            // mergedBindings (defaults override defaultBindings, FR-065), review IMPORTANT #3:
            // menu construction does not depend on keyWindowState); Button actions route through
            // keyWindowState (same pattern as the file menu, design §4 option 1); T3.4: dynamic
            // refresh driven by ShortcutMenuModel (defaults notification → version +1 →
            // .commands re-evaluation, review MINOR #4 fix); makeMenuItems is a test surface
            // only, never injected into mainMenu (option 2 rejected)
            CommandMenu("格式") {
                // ⚠️ 修复（T3.4-fix1，评审 IMPORTANT #4）：显式消费 shortcutMenuModel.version
                // 建立 body 依赖——@StateObject objectWillChange 依赖 SwiftUI 对属性的读取追踪，
                // 无显式读取时重算不可靠；defaults 变更 → version+1 → .commands 重算 → 菜单刷新。
                // 计划要求 .onChange 或 body 依赖二选一，此处选 body 依赖（显式 if 消费）。
                // Fix (T3.4-fix1, review IMPORTANT #4): explicitly consume shortcutMenuModel.version
                // to establish a body dependency — @StateObject objectWillChange relies on SwiftUI's
                // property-read tracking, which is unreliable without an explicit read; defaults change
                // → version+1 → .commands re-evaluates → menu refreshes. The plan allows either
                // .onChange or a body dependency; body dependency chosen (explicit if-consumption).
                if shortcutMenuModel.version >= 0 {
                    ForEach(EditorCommand.allCases, id: \.self) { command in
                        Button(command.title) { keyWindowState()?.shortcutManager.execute(command) }
                            .keyboardShortcut(shortcutKey(for: command), modifiers: shortcutModifiers(for: command))
                    }
                }
                Divider()
                // ⚠️ P1-2：折叠/展开当前标题（Cmd+Shift+F——与既有绑定无冲突，T1.5 已入保留表）
                Button("折叠/展开当前标题") { keyWindowState()?.toggleFoldAtCursor() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            // ⚠️ T3.2（S-034）：聚焦模式命令——⌃⌘F 接管失败适配（记录）：计划 U4 前提无效，
            // CommandGroupPlacement 无 fullScreen 成员（SDK 核实全量清单）；系统"进入全屏"
            // 菜单项由 AppKit 注入，.commands 无法 replacing。按计划备选条款换键位 ⌥⌘F，
            // placement 用 View 菜单 .toolbar 锚点（与"隐藏工具栏"语义相邻；保留 ⌥⌘T 系统项）。
            // Focus-mode command: ⌃⌘F takeover failed (no fullScreen placement in SDK) →
            // fallback key ⌥⌘F per plan, anchored after .toolbar in the View menu.
            CommandGroup(after: .toolbar) {
                Button("聚焦模式") { keyWindowState()?.toggleFocusMode() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }
        // ⚠️ S-028：设置面板（Settings scene——Cmd+, 标准偏好窗口；PreferencesView 4 区 6 项，
        // 全部 UserDefaults 持久化 + 实时生效广播，FR-101~103/106~108）
        // 注意：Settings 是 Scene（非 Commands），必须置于 .commands 块外、与 WindowGroup 平级
        Settings {
            PreferencesView()
        }
    }
}

// ⚠️ 遗留 #7：key window 路由助手——NSApp.keyWindow → 关联 MainContentState（经 windowRegistry）。
// 路由失败降级（设计 §7）：key window nil 时菜单 disabled；多窗口每窗口独立 fileOps 仍正确
@MainActor
func keyWindowState() -> MainContentState? {
    guard let keyWindow = NSApp.keyWindow else { return nil }
    return MainContentState.state(for: keyWindow)
}


/// App 级打开文件（修复：关闭窗口后 keyWindowState nil → 菜单 no-op）
/// 有窗口：直接 keyWindowState 打开；无窗口：NSOpenPanel → 存 pendingURL → 新建窗口
@MainActor
func openFileFromMenu() {
    if let state = keyWindowState() {
        state.fileOps.openDocument()
        return
    }
    // 无窗口：直接弹 NSOpenPanel → 存 pendingURL → 新建窗口读取
    let panel = NSOpenPanel()
    panel.allowedContentTypes = FileOperations.supportedTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else {
            return
    }
    MainContentState.pendingOpenURL = url
    MainContentState.openWindowHandler?()
}

/// 最近文件打开（无窗口时新建窗口再打开）
@MainActor
func openRecentFromMenu(_ url: URL) {
    if let state = keyWindowState() {
        state.fileOps.open(url: url)
        return
    }
    MainContentState.pendingOpenURL = url
    MainContentState.openWindowHandler?()
}


// ⚠️ S-020/T3.4：静态绑定表（+ defaults 覆盖）→ SwiftUI keyboardShortcut 适配
//（NSEvent.ModifierFlags → EventModifiers）。T3.4 起改读 ShortcutManager.mergedBindings
//（defaults 覆盖 defaultBindings，FR-065）；审查 IMPORTANT #3 约束保持——mergedBindings 是
// 纯静态函数，不依赖 keyWindowState（启动时 keyWindow nil 不会回退错误绑定）；
// 动态刷新由 ShortcutMenuModel.version（defaults 通知 → @StateObject objectWillChange →
// .commands 重算，审查 MINOR #4 修正）驱动，与文件菜单字面量同模式，仅数据源合并化
// Static binding table + defaults overrides → SwiftUI keyboardShortcut adaptation.
// Reads ShortcutManager.mergedBindings (defaults override defaultBindings, FR-065);
// review IMPORTANT #3 constraint kept — mergedBindings is a pure static lookup with no
// keyWindowState dependency; dynamic refresh driven by ShortcutMenuModel.version
// (defaults notification → @StateObject objectWillChange → .commands re-evaluation,
// review MINOR #4 fix)
@MainActor
private func shortcutKey(for command: EditorCommand) -> KeyEquivalent {
    let key = ShortcutManager.mergedBindings(defaults: .standard)[command]?.key ?? " "
    // ⚠️ 修复（T3.4-fix1，评审 IMPORTANT）：Character(key) 要求恰好 1 个字符——
    // defaults 用户输入可能存空/多字符键，直接 Character(key) 触发 init 陷阱（precondition 崩溃）。
    // 空/多字符键回退空格（KeyEquivalent(" ") = 无快捷键，等效原 isEmpty 回退语义）
    // Fix (T3.4-fix1, review IMPORTANT): Character(key) requires exactly one character —
    // user defaults may hold an empty/multi-char key and Character(key) would hit the init
    // trap (precondition crash). Empty/multi-char keys fall back to space (no shortcut).
    guard key.count == 1 else { return KeyEquivalent(" ") }
    return KeyEquivalent(Character(key))
}

@MainActor
private func shortcutModifiers(for command: EditorCommand) -> EventModifiers {
    guard let binding = ShortcutManager.mergedBindings(defaults: .standard)[command] else { return .command }
    var result: EventModifiers = []
    if binding.modifiers.contains(.command) { result.insert(.command) }
    if binding.modifiers.contains(.shift) { result.insert(.shift) }
    if binding.modifiers.contains(.option) { result.insert(.option) }
    if binding.modifiers.contains(.control) { result.insert(.control) }
    return result
}

// S-010 集成装配点：编辑器/预览/渲染管线三方连线（所有状态经 state 容器访问）
// 批次 5（T5.4）：fileOps 经 init 注入（与 App 级同一实例）；工具栏/菜单接线 + 关闭确认
// ⚠️ 遗留 #7（批次 3）：init() 无参（fileOps 容器自建）；openWindow 环境值注册 Cmd-N
@MainActor
private struct MainContentAssembly: View {
    @StateObject private var state: MainContentState
    @State private var editorText = ""
    // ⚠️ 遗留 #7：openWindow 环境值（Cmd-N 新建窗口；onAppear 注册到静态 handler）
    @Environment(\.openWindow) private var openWindow

    // ⚠️ 遗留 #7：无 fileOps 注入（容器内部创建）
    init() {
        _state = StateObject(wrappedValue: MainContentState())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MainWindowView(
            left: AnyView(
                EditorView(
                    text: $editorText,
                    // ⚠️ 第 10 轮：state. 前缀统一；P1-1 起 documentDidEdit 已移至 onRawTextDidChange（保存走完整原文）
                    onTextDidChange: { [weak state] text in
                        // ⚠️ 修复（focus-fix，根因 1）：值比较——相同文本跳过 @State 写，
                        // 与 MarkdownTextView 抑制标志双保险（T1.1 拦截程序化回填通知，
                        // 此处兜底用户路径相同值），防同帧 updateNSView 循环 → AttributeGraph cycle
                        // ⚠️ FixD2（deep-analysis CRITICAL）：折叠态下渲染通道携带 renderingText
                        //（折叠语义文本）——不得写回 editorText：写回 → updateNSView 回填 →
                        // setTextProgrammatically 内 removeAllFolds + rawText=截断文本 →
                        // P1-1 保存通道数据丢失。折叠态显示由 toggleFold 维护（rawText 为原文
                        // 基准，expandDisplayToRaw 保完整）；此处仅跳过 @State 写，渲染/选区
                        // 通道保持（预览折叠语义 + 状态栏渲染语义现状不变）
                        if state?.commandExecutor.textView?.foldState.folded.isEmpty ?? true,
                           text != editorText { editorText = text }
                        state?.latestEditorText = text   // ⚠️ S-024：选区定位的文本上下文（光标同步输入）
                        state?.coordinator.input(text)
                        // ⚠️ P1-1：documentDidEdit 移出渲染通道——渲染闭包携带折叠语义文本（renderingText），
                        // 不得写入文档；保存改走 onRawTextDidChange（完整原文）
                        state?.findCoordinator.textDidChange()   // ⚠️ S-029：文本变化 → 匹配过期清理
                    },
                    onRawTextDidChange: { [weak state] text in
                        // ⚠️ P1-1：保存通道 = 原始文本（折叠态下完整原文——数据完整性修复）
                        state?.fileOps.documentDidEdit(text)
                    },
                    onSelectionDidChange: { [weak state] selection in
                        // ⚠️ S-024：光标定位同步（FR-014）——选区变化 → ScrollSync
                        //（150ms debounce 内部；latestEditorText 由 onTextDidChange 维护）
                        state?.latestSelection = selection   // ⚠️ T3.2：状态栏行列计数数据源
                        state?.scrollSync.editorSelectionChanged(
                            text: state?.latestEditorText ?? "",
                            selection: selection)
                    },
                    onScrollRatio: { [weak state] ratio in
                        state?.scrollSync.editorScrolled(ratio: ratio)
                    },
                    onComposeStateChange: { [weak state] composing in
                        state?.imeHandling.setComposing(composing)
                    },
                    // ⚠️ 遗留 #5（批次 1）：主题初始值同步源（订阅后主动同步一次）
                    // 批次1 内存修复(design §批次1 根因④)：[weak state] 与兄弟闭包一致,
                    // 避免强捕获延后 state 释放;state 释放后回落 .light 默认。
                    // Weak capture for consistency with sibling closures (batch 1).
                    themeProvider: { [weak state] in state?.themeService.effectiveMode ?? .light },
                    // ⚠️ S-020：textView 上报 → 容器注入 CommandExecutor
                    // textView report → container injects CommandExecutor
                    onTextViewCreated: { [weak state] textView in
                        state?.attachTextView(textView)
                    }
                )
                // ⚠️ 修复（round4 T1.2b）：.frame(minWidth: 220) 移除——固定下限压过
                // MainWindowView.dynamicMinWidth（窗口 <1100 时 220 > 160 动态下限 → 动态宽度失效）；
                // minWidth 统一交由 MainWindowView HSplitView 内部控制（用户补充需求）
            ),
            right: AnyView(
                PreviewView(preview: state.previewWebView)
                // ⚠️ 修复（round4 T1.2b）：同上，.frame(minWidth: 220) 移除
            ),
            // ⚠️ 遗留 #4（批次 2）：分栏模式注入
            paneMode: state.paneMode,
            // ⚠️ T3.2（S-034/FR-087）：聚焦模式 + 状态栏注入——isFocusMode/showStatusBar 经
            // @Published 驱动重算；statusText 纯函数组装（latestEditorText + latestSelection，
            // 数据由 onTextDidChange/onSelectionDidChange 闭包维护）
            isFocusMode: state.isFocusMode,
            showStatusBar: state.showStatusBar,
            statusText: MainWindowView.statusText(
                text: state.latestEditorText,
                selection: state.latestSelection)
        )
            // ⚠️ S-029：查找面板 overlay（FindPanelHost 内部 @ObservedObject——
            // 嵌套 ObservableObject 变化不触发 state 的 body 重算，须独立观察者视图）
            FindPanelHost(coordinator: state.findCoordinator)
                .padding(.bottom, 28)   // 避开底部状态栏
        }
        .background(
            // ⚠️ 遗留 #7：#8 转发链基础上升级 state 版——安装时注册 state → window
            //（key window 路由 + Cmd-Q 遍历数据源；关闭确认 = state.fileOps.shouldCloseWindow()）
            WindowCloseGuard(state: state)
        )
        // ⚠️ S-030：窗口拖拽打开（FR-078——编辑器外窗口级拖拽；NFR-011 复用 open(url:) 确认链路）
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            DragDrop.handle(providers) { url in
                state.fileOps.open(url: url)
            }
            return true
        }
        .onAppear {
            // ⚠️ 遗留 #7：注册新建窗口动作（每窗口 onAppear 注册，行为一致；onDisappear 不清除——
            // 窗口关闭后 Cmd-N 仍可用，openWindow(id:) 不依赖单窗口生命周期）
            MainContentState.openWindowHandler = { openWindow(id: "editor") }
            // ⚠️ 第 11 轮补全（#4）：打开/新建文件回填编辑器（editorText 是 assembly 的 @State）
            // ⚠️ 修复（round5 T1.3）：onTextRead 直连渲染——previewOnly 模式 EditorView 不在
            // 视图树 → updateNSView 回填链路不执行 → 预览不渲染；直接 coordinator.input 闭合。
            // split 模式回填仍由 updateNSView 处理，双路径幂等（input debounce + editorText 值比较）
            state.fileOps.onTextRead = { [weak state] text in
                // ⚠️ FixD2b（评审 IMPORTANT #1 配对）：文档切换前清会话折叠状态——
                // updateNSView 折叠守卫跳过回填，此处显式清理保证新文档回填不被跳过
                //（setTextProgrammatically 的回填内清理被守卫提前拦截，须在此完成）
                state?.commandExecutor.textView?.foldState.removeAllFolds()
                editorText = text
                state?.latestEditorText = text   // S-024：回填即最新文本，直接维护（消除 updateNSView 合成耦合）
                state?.coordinator.input(text)
            }
            // App 级打开：新窗口读取 pendingOpenURL（关闭窗口后菜单打开路径）
            // ⚠️ 必须在 onTextRead 注册之后——open(url:) 内部调用 onTextRead 回填编辑器
            if let pendingURL = MainContentState.pendingOpenURL {
                MainContentState.pendingOpenURL = nil
                state.fileOps.open(url: pendingURL)
            }
        }
        .onDisappear {
            // 环修复：解除 onTextRead 闭包（闭包经 @StateObject 捕获 state → fileOps → 闭包环），窗口关闭后容器可解脱
            state.fileOps.onTextRead = nil
        }
        .toolbar {
            // 工具栏接线（ToolbarActions 实参；state.fileOps 为每窗口实例——#7 后按钮闭包
            // 天然作用于本窗口，不受 App 级共享影响）
            ToolbarView(actions: ToolbarActions(
                newDocument: { state.fileOps.newDocument() },
                openDocument: { state.fileOps.openDocument() },
                saveDocument: { state.fileOps.saveDocument() },
                // ⚠️ S-020：工具栏格式化按钮复用命令通道（FR-084 粗体/斜体/链接/代码，
                // Epic-1 未实装，S-021 一并接线——设计 §8 Open Question 定稿）
                // Toolbar format buttons reuse the command channel (FR-084 bold/italic/link/code;
                // not implemented in Epic-1, wired together with S-021 — design §8 Open Question final)
                toggleBold: { state.shortcutManager.execute(.bold) },
                toggleItalic: { state.shortcutManager.execute(.italic) },
                insertLink: { state.shortcutManager.execute(.link) },
                insertCode: { state.shortcutManager.execute(.inlineCode) },
                togglePane: { state.paneMode = state.paneMode.next },
                cycleTheme: {
                    let modes: [ThemeMode] = [.light, .dark, .system]   // ⚠️ 修复 #9：顺序 light→dark→system
                    // ⚠️ 第八轮修复：跳过与当前 effectiveMode 相同的候选——system 在 dark 系统下
                    // = dark，从 dark 切 system 无视觉变化（用户感知"没反应"）；每次点击必有视觉变化
                    state.themeIndex = MainContentState.nextThemeIndex(
                        currentIndex: state.themeIndex,
                        currentEffective: state.themeService.effectiveMode
                    )
                    state.themeService.select(modes[state.themeIndex])
                },
                // ⚠️ 修复（round5 T1.2）：预览缩放接线 → 本窗口 previewWebView
                zoomIn: { state.previewWebView.zoomIn() },
                zoomOut: { state.previewWebView.zoomOut() },
                zoomReset: { state.previewWebView.zoomReset() }
            ), paneIcon: { state.paneMode.toolbarIcon })
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - 关闭确认适配器（FR-076，NFR-011）+ 窗口关联注册（遗留 #7）
// 在 MainWindowView 外部挂 NSWindowDelegate.windowShouldClose → state.fileOps.shouldCloseWindow()
//（Document.confirmCloseIfNeeded）；willCloseNotification 不可取消，故用委托拦截。
// ⚠️ 遗留 #8（批次 1）：delegate 转发链——保存原 delegate，windowShouldClose AND 合并（原 false 优先）
// ⚠️ 遗留 #7（批次 3）：安装时把 state 注册到 windowRegistry（key window 路由 + Cmd-Q 遍历数据源）
struct WindowCloseGuard: NSViewRepresentable {
    let state: MainContentState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // ⚠️ 修复 #4（第 7 轮）：Task { @MainActor in } 替代 DispatchQueue.main.async
        Task { @MainActor in
            guard let window = view.window else { return }
            context.coordinator.install(on: window, state: state)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.state = state
        // 竞态修复：makeNSView 的 Task 执行时 window 可能尚未挂接（窗口恢复场景），
        // 此处补装 delegate；仍失败则 NSLog 告警（避免关闭确认静默失效）
        // 补装条件对称修复：视图挂接窗口与已安装窗口不一致时（含首次 nil→窗口、窗口迁移）
        // 才补装；仅当从未安装过且当前无窗口时保留告警日志（迁移场景避免误报）
        // Symmetric reinstall fix: reinstall only when the view's attached window differs from
        // the installed one (covers first-attach nil→window and window migration); keep the
        // warning only when nothing was ever installed and no window is attached (no false
        // alarm on migration)
        if nsView.window !== context.coordinator.window {
            if let window = nsView.window {
                context.coordinator.install(on: window, state: state)
            } else if context.coordinator.window != nil {
                NSLog("[WindowCloseGuard] window 未挂接，关闭确认未安装")
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // ⚠️ 适配（Swift 6 语言模式）：NSWindowDelegate 是 @MainActor 协议，
    // Coordinator 补 @MainActor（与 EditorView.Coordinator 先例一致，避免 #ConformanceIsolation 编译错误）
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        // ⚠️ 遗留 #8（批次 1）：转发链——原 delegate（install 时保存；幂等守卫防自引用）
        weak var originalDelegate: NSWindowDelegate?
        weak var state: MainContentState?
        // ⚠️ 测试注入 fallback（batch-01 测试沿用；生产走 state；state 为 nil 且无注入时放行）
        var onShouldClose: (() -> Bool)?
        // ⚠️ T4.2（FR-077）：didBecomeKey 观察者 token（外部修改检测挂接；deinit 移除防泄漏——
        // AutoSave 同构观察者模式，CWE-772）
        private var keyTokens: [NSObjectProtocol] = []

        /// 安装：注册 state → window（#7 路由数据源）+ 保存原 delegate → 设 self（#8；
        /// 幂等：delegate 已是 self 时不覆盖 originalDelegate——防竞态自引用与转发链断裂）
        func install(on window: NSWindow, state: MainContentState) {
            // ⚠️ 修复（review，T1.5-fix 保留）：窗口迁移守卫——视图挂到另一存活窗口时，
            // 先恢复旧窗口 delegate（若仍指向 self），再装新窗口（防双窗口守卫错位）
            if let previous = self.window, previous !== window, previous.delegate === self {
                previous.delegate = originalDelegate
            }
            self.window = window
            self.state = state
            MainContentState.register(state, for: window)   // #7：key window 路由数据源
            state.autoSave.attach(to: window)   // ⚠️ S-030：自动保存挂接（失焦 + 30s；迁移场景幂等——内部先 detach）
            // ⚠️ T4.2（FR-077）：外部修改检测——didBecomeKey 挂接（AutoSave 同构观察者；
            // 每次窗口成为 key 即比对 mtime；冲突弹窗/静默重载在 fileOps 内部处理）
            // install 幂等/迁移场景：先移除旧 token 防重复注册泄漏
            keyTokens.forEach { NotificationCenter.default.removeObserver($0) }
            keyTokens = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main)
                { [weak self] _ in
                    // _ = 显式丢弃：checkExternalModification 内部已处理弹窗/重载，
                    // 返回值仅供测试断言；显式 Void 化防 assumeIsolated 泛型 T 推断冲突
                    // ⚠️ 修复（真机验收）：模态窗口（设置面板/弹框）期间跳过检测——
                    // 否则设置面板关闭回主窗口 → didBecomeKey → 检测 → 弹框 → 循环滴滴声
                    MainActor.assumeIsolated {
                        if NSApp.modalWindow == nil, NSApp.keyWindow === window {
                            _ = self?.state?.fileOps.checkExternalModification()
                        }
                    }
                },
                // ⚠️ 修复（真机验收）：窗口关闭时注销 registry——否则已关窗口的 state
                // 仍在 allStates（@StateObject 延迟释放），Cmd-Q 退出时对其再次 confirmCloseIfNeeded
                // 弹保存提示（应只在窗口关闭时确认一次）
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main)
                { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let state = self.state else { return }
                        MainContentState.unregister(state, for: window)
                        self.keyTokens.forEach { NotificationCenter.default.removeObserver($0) }
                        self.keyTokens = []
                    }
                },
            ]
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate              // #8：保存原 delegate（转发链）
            window.delegate = self
        }

        deinit {
            // ⚠️ T4.2（FR-077）：移除 didBecomeKey 观察者（CWE-772 防泄漏；AutoSave.detach 同构）
            MainActor.assumeIsolated {
                keyTokens.forEach { NotificationCenter.default.removeObserver($0) }
                keyTokens = []
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // #8 AND 合并：原 delegate 明确 false → 尊重其拦截意图（原 false 优先）
            if let original = originalDelegate,
               let decision = original.windowShouldClose?(sender),
               decision == false {
                return false
            }
            return state?.fileOps.shouldCloseWindow() ?? onShouldClose?() ?? true
        }

        // ⚠️ 修复（review，T1.5-fix 保留）：转发链完整化——windowShouldClose 自行实现（AND 合并），
        // 其余 NSWindowDelegate 方法经标准 NSObject 消息转发交还原 delegate（避免被替换后静默失效）
        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return originalDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if super.responds(to: aSelector) { return nil }
            return originalDelegate
        }
    }
}

// ⚠️ S-030：最近文件菜单动态数据源——监听 UserDefaults.didChangeNotification 重载
//（@Published urls 更新 → @StateObject objectWillChange → App.body 含 .commands 重算；审查 MINOR #4 修正）
@MainActor
final class RecentFilesMenuModel: ObservableObject {
    @Published var urls: [URL] = []
    private var token: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        urls = RecentFiles.list(defaults: defaults)
    }

    deinit {
        MainActor.assumeIsolated {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
