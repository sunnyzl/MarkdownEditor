import AppKit

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

    /// ⚠️ S-030：Dock/Finder 拖拽打开（FR-078）
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        sender.reply(toOpenOrPrint: .success)
        // ⚠️ 路由约定：优先 key window（前端窗口）；无 key window 降级 allStates.first（单窗口兜底）
        let state = keyWindowState() ?? MainContentState.allStates.first
        for url in DragDrop.urls(from: filenames) {
            state?.fileOps.open(url: url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd-Q 语义定稿（修复 #3/第 1 轮）：遍历所有窗口（weak 注册表已剔除已关窗口）
        for state in MainContentState.allStates {
            if !state.fileOps.shouldCloseWindow() { return .terminateCancel }
        }
        return .terminateNow
    }
}
