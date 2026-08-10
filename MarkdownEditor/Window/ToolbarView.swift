import SwiftUI

// ToolbarView.swift — 工具栏（S-006，FR-084）
// ToolbarView.swift — Toolbar (S-006, FR-084)
// 9 按钮：新建/打开/保存/粗体/斜体/链接/代码/分栏切换/主题；可隐藏（macOS 原生工具栏行为）
// 9 buttons: new/open/save/bold/italic/link/code/pane-toggle/theme; hideable via native macOS toolbar behavior
// ⚠️ 遗留 #4（批次 2）：分栏图标随模式切换——paneIcon 闭包注入
//（MainContentAssembly 提供 state.paneMode.toolbarIcon；闭包而非 PaneMode 类型参数，
// 避免 ToolbarView 引入跨文件类型依赖）
// ⚠️ Legacy #4 (batch 2): pane icon follows mode switch — paneIcon closure injection
// (MainContentAssembly supplies state.paneMode.toolbarIcon; closure instead of PaneMode type
// parameter avoids cross-file type dependency in ToolbarView)
struct ToolbarView: ToolbarContent {
    let actions: ToolbarActions
    /// 分栏模式图标（S-022 三模式：sidebar.left / sidebar.right / rectangle.split.2x1）
    /// Pane-mode icon (S-022 three modes: sidebar.left / sidebar.right / rectangle.split.2x1)
    var paneIcon: () -> String = { "sidebar.right" }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { actions.newDocument() } label: {
                Label("新建", systemImage: "doc")
            }.help("新建文档 (⌘N)")

            Button { actions.openDocument() } label: {
                Label("打开", systemImage: "folder")
            }.help("打开文档 (⌘O)")

            Button { actions.saveDocument() } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }.help("保存文档 (⌘S)")

            Divider()

            Button { actions.toggleBold() } label: {
                Label("粗体", systemImage: "bold")
            }.help("粗体 (⌘B)")

            Button { actions.toggleItalic() } label: {
                Label("斜体", systemImage: "italic")
            }.help("斜体 (⌘I)")

            Button { actions.insertLink() } label: {
                Label("链接", systemImage: "link")
            }.help("插入链接 (⌘K)")

            Button { actions.insertCode() } label: {
                Label("代码", systemImage: "chevron.left.forwardslash.chevron.right")
            }.help("行内代码")

            Divider()

            Button { actions.togglePane() } label: {
                // ⚠️ 遗留 #4：图标随模式切换（paneIcon 闭包，由 MainContentAssembly 注入）
                // ⚠️ Legacy #4: icon follows mode switch (paneIcon closure, injected by MainContentAssembly)
                Label("分栏", systemImage: paneIcon())
            }.help("分栏模式切换 (⌘\\)")

            Button { actions.cycleTheme() } label: {
                Label("主题", systemImage: "circle.lefthalf.filled")
            }.help("切换主题")

            Divider()

            // ⚠️ 新增（round5 T1.2）：预览缩放按钮组（放大/缩小/重置；快捷键 ⌘+/⌘-/⌘0）
            Button { actions.zoomIn() } label: {
                // ⚠️ 第六轮修复（round6 T1.2，根因 2）：magnifyingglass.plus 是无效 SF Symbol
                // （日志 No symbol named ... found → 按钮 Label 空、不可见）；plus.magnifyingglass 有效
                Label("放大", systemImage: "plus.magnifyingglass")
            }.help("放大预览 (⌘+)")

            Button { actions.zoomOut() } label: {
                // ⚠️ 第六轮修复（round6 T1.2，根因 2）：magnifyingglass.minus 无效 → minus.magnifyingglass
                Label("缩小", systemImage: "minus.magnifyingglass")
            }.help("缩小预览 (⌘-)")

            Button { actions.zoomReset() } label: {
                Label("重置缩放", systemImage: "arrow.counterclockwise")
            }.help("重置缩放 (⌘0)")
        }
    }
}

// 工具栏动作集：闭包默认为空实现；S-014（文件）/S-015（主题）/S-021（格式）接线时替换
// Toolbar action set: closures default to no-op; replaced when wired by S-014 (file)/S-015 (theme)/S-021 (format)
struct ToolbarActions {
    var newDocument: () -> Void = {}
    var openDocument: () -> Void = {}
    var saveDocument: () -> Void = {}
    var toggleBold: () -> Void = {}
    var toggleItalic: () -> Void = {}
    var insertLink: () -> Void = {}
    var insertCode: () -> Void = {}
    var togglePane: () -> Void = {}
    var cycleTheme: () -> Void = {}
    // ⚠️ 新增（round5 T1.2）：预览缩放动作（MainContentAssembly 接线 → state.previewWebView）
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomReset: () -> Void = {}
}
