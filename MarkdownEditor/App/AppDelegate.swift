import AppKit
import SwiftUI

// AppDelegate.swift — 退出确认适配器（P1 后置：MainApp 拆分纯重构）
// 原 MainApp.swift 迁移（零行为变化）；退出确认（NFR-011）：Cmd-Q/Dock 退出/系统注销前
// 经所有窗口 fileOps 确认
// ⚠️ 遗留 #7（批次 3）：单闭包 shouldCloseHandler 删除——遍历 windowRegistry 全部窗口
//（每窗口独立 fileOps 依次 confirmCloseIfNeeded；任一取消 → terminateCancel，防 NFR-011 丢数据）
// ⚠️ 适配（与 WindowCloseGuard.Coordinator 先例一致）：NSApplicationDelegate 是 @MainActor 协议，
// 补 @MainActor 避免 Swift 6 语言模式 #ConformanceIsolation 编译错误
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 修复：关闭最后一个窗口后应用保持运行（macOS 标准——System Preferences 等行为）
    /// 否则用户关窗后 File 菜单消失/无法打开文件
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 禁用应用状态恢复（macOS 14 可用；配合修复 A 场景恢复禁用）
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    /// 冷启动激活 + 兜底注册（修复：删除循环重试 Task——双定时器竞态放大器；
    /// pending 消费/建窗由 drain 循环 + manualWindowCreator 兜底闭合）
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // 兜底注册：drain 无法经 openWindowHandler 物化场景窗口时（冷启动外部事件启动）
        MainContentState.manualWindowCreator = { [weak self] in self?.createWindowManually() }
        MainContentState.manualWindowCreated = false
    }

    // MARK: - 文件打开路由（统一收敛——修复"多次双击多窗口/部分不渲染"）

    /// 统一打开路由：三个 delegate 入口（openFiles/openFile/open）共用。
    /// ⚠️ 修复（真机验收，问题 1）：
    /// ① 运行中 → 复用 key window（currentDocument 替换 + onTextRead 回填，单文档语义），
    ///    不再产生多窗口（此前每次双击可能命中不同 state/pending 单槽位 → 只有第一个渲染）
    /// ② 无窗口 → 暂存 pending + 立即建窗（修复死端：此前只存 pending 不建窗 → 文件永不开）
    /// ③ 冷启动 → 默认窗口 onAppear 消费 pending（MainApp onAppear 先挂 onTextRead 再消费）
    /// 统一打开路由（多文档窗口模型）：三分支——
    /// ① 同文件窗口已存在 → 聚焦（不重载）
    /// ② 存在空白窗口 → 即时接管渲染（不建窗）
    /// ③ 否则 → 入队 + 请求建窗（新窗口 onAppear 消费队首）
    private func routeOpen(_ urls: [URL]) {
        for url in urls {
            openFileViaRouter(url)
        }
    }

    private func openFileViaRouter(_ url: URL) {
        NSLog("[DIAG-ROUTE] openFileViaRouter: %@ allStates=%d pending=%d",
              url.lastPathComponent, MainContentState.allStates.count, MainContentState.pendingOpenURLs.count)
        // ① 同文件窗口 → 聚焦
        if let state = MainContentState.state(forFile: url) {
            NSLog("[DIAG-ROUTE] ① focus existing window, currentFileURL=%@", state.currentFileURL?.lastPathComponent ?? "nil")
            state.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // ② 空白窗口 → 即时接管
        if let blank = MainContentState.firstBlankState() {
            NSLog("[DIAG-ROUTE] ② blank takeover")
            blank.fileOps.open(url: url)
            blank.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // ③ 入队 + 请求建窗
        NSLog("[DIAG-ROUTE] ③ queue + requestWindow")
        if !MainContentState.pendingOpenURLs.contains(url) {
            MainContentState.pendingOpenURLs.append(url)
        }
        MainContentState.requestWindow()
    }

    /// Dock/Finder 拖拽打开（FR-078）
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        sender.reply(toOpenOrPrint: .success)
        routeOpen(DragDrop.urls(from: filenames))
    }

    /// 单文件打开（旧 API 入口）
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        sender.reply(toOpenOrPrint: .success)
        routeOpen([URL(fileURLWithPath: filename)])
        return true
    }

    /// 现代统一打开入口（macOS 10.13+；无 NSDocumentClass 文档类型 → 优先走此方法）
    func application(_ application: NSApplication, open urls: [URL]) {
        routeOpen(urls)
    }

    /// 手动创建窗口（双击 md 启动时 SwiftUI 场景不建窗的终极兜底）：
    /// NSHostingView 包裹 MainContentAssembly（Assembly 无参 init，内部自建 state）
    private func createWindowManually() {
        // 防御：已存在未显示窗口（场景已物化但未 orderFront）→ 显示而非新建
        if let hidden = NSApp.windows.first(where: { !$0.isVisible && $0.canBecomeMain }) {
            hidden.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hostingView = NSHostingView(rootView: MainContentAssembly())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MarkdownEditor"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // ⚠️ 修复（最后窗口关闭崩溃）：窗口仅被 NSApp.windows 持有，关闭不释放 →
        // contentView（NSHostingView + MainContentState）成 zombie 永不 teardown。
        // willClose 时卸载 contentView → SwiftUI 视图树销毁 → onDisappear/state deinit 正常
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            window?.contentView = nil
        }
        NSLog("[DIAG-LAUNCH] manual window created")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd-Q 语义定稿（修复 #3/第 1 轮）：遍历所有窗口（weak 注册表已剔除已关窗口）
        for state in MainContentState.allStates {
            if !state.fileOps.shouldCloseWindow() { return .terminateCancel }
        }
        return .terminateNow
    }
}
