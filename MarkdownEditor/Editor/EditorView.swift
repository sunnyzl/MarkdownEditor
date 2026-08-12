import SwiftUI
import AppKit

// EditorView.swift — NSTextView 经 NSViewRepresentable 桥接（S-007，AD-1）
// 事件闭包供 RenderCoordinator（S-010）/IMEHandling（S-008）/ScrollSync（S-013）订阅
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    var onTextDidChange: ((String) -> Void)?
    // ⚠️ P1-1：原始文本通道（保存/导出数据源）——与 onTextDidChange 同构；
    // 折叠态下携带完整原文（含折叠区间行），渲染通道仍为 renderingText 折叠语义
    var onRawTextDidChange: ((String) -> Void)?
    var onSelectionDidChange: ((NSRange) -> Void)?
    var onScrollRatio: ((Double) -> Void)?
    var onComposeStateChange: ((Bool) -> Void)?
    // ⚠️ 遗留 #5：主题同步源（MainContentAssembly 挂接 state.themeService.effectiveMode）；
    // makeNSView 挂接后立即主动同步一次（防初始广播丢失——容器 init apply() 早于视图订阅）
    var themeProvider: (() -> ThemeMode)?
    // ⚠️ S-020：编辑器创建上报（makeNSView 时上报 textView → 容器 attachTextView → CommandExecutor 注入）
    // Editor-created callback: reports the textView at makeNSView time so the per-window
    // CommandExecutor can be wired (same shape as ScrollTracker.attach)
    var onTextViewCreated: ((MarkdownTextView) -> Void)?
    var onFileDrop: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextDidChange: onTextDidChange,
                    onRawTextDidChange: onRawTextDidChange,
                    onSelectionDidChange: onSelectionDidChange,
                    onScrollRatio: onScrollRatio,
                    onComposeStateChange: onComposeStateChange,
                    onTextViewCreated: onTextViewCreated)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // ⚠️ 修复（真机验收）：底部留白 24pt（覆盖状态栏高度 + 末行呼吸空间）——
        // 最后一行滚动到底仍可见可编辑；contentInsets 仅底部（顶部不受影响）
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
        scroll.automaticallyAdjustsContentInsets = false

        let textView = MarkdownTextView()
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        // 事件 → Coordinator → 外部闭包（SwiftUI 闭包捕获语义）
        // ⚠️ 修复 #5：成员访问不可作捕获名，用 `[weak coordinator = context.coordinator]`
        textView.onTextDidChange = { [weak coordinator = context.coordinator] text in
            coordinator?.onTextDidChange?(text)
        }
        textView.onRawTextDidChange = { [weak coordinator = context.coordinator] text in
            coordinator?.onRawTextDidChange?(text)
        }
        textView.onSelectionDidChange = { [weak coordinator = context.coordinator] range in
            coordinator?.onSelectionDidChange?(range)
        }
        textView.onScrollRatio = { [weak coordinator = context.coordinator] ratio in
            coordinator?.onScrollRatio?(ratio)
        }
        textView.onComposeStateChange = { [weak coordinator = context.coordinator] composing in
            coordinator?.onComposeStateChange?(composing)
        }
        // ⚠️ 遗留 #5：主题初始值同步（订阅后主动同步一次——覆盖显式 dark 启动场景）
        textView.themeProvider = themeProvider
        // 非图片文件拖入回调（FR-078：.md 拖到文本区直接打开）
        textView.onFileDrop = onFileDrop
        textView.syncThemeFromProvider()
        // ⚠️ S-020：上报 textView（与 ScrollTracker.attach 同构）
        context.coordinator.onTextViewCreated?(textView)

        scroll.documentView = textView
        context.coordinator.tracker.attach(to: scroll, textView: textView)
        // ⚠️ 修复（focus-fix，根因 2）：初始聚焦——makeNSView 时 window 尚未挂接，
        // Task 延后至挂接后执行（与 WindowCloseGuard makeNSView 先例同模式）；
        // 修复前无初始聚焦，点击聚焦又因嵌套链路（NSSplitView → NSHostingView →
        // NSScrollView → NSTextView）失效 → 编辑器无法获得焦点
        Task { @MainActor in
            scroll.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    // ⚠️ 合并修复 #11：单个 updateNSView 同时做闭包刷新 + 文本回填（勿拆两个同签名方法）
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // ① Coordinator 闭包同步刷新（makeCoordinator 仅首次创建，闭包集可能跨批次变化）
        context.coordinator.onTextDidChange = onTextDidChange
        context.coordinator.onRawTextDidChange = onRawTextDidChange
        context.coordinator.onSelectionDidChange = onSelectionDidChange
        context.coordinator.onScrollRatio = onScrollRatio
        context.coordinator.onComposeStateChange = onComposeStateChange
        context.coordinator.onTextViewCreated = onTextViewCreated
        // ② 文本回填（防预览更新循环 / 光标跳变）——focus-fix（根因 1）：
        // 走 setTextProgrammatically（内部值比较 + 置位抑制 didChangeNotification），
        // 替代直接 string 赋值——打破 回填→通知→onTextDidChange→@State 写→updateNSView
        // 同帧循环 → AttributeGraph cycle → UI 冻结 的故障链
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        // ⚠️ 遗留 #5：themeProvider 刷新（闭包集跨批次变化；sync 仅 makeNSView 一次——
        // 后续主题变化由广播驱动，重复 sync 幂等无害但无必要）
        textView.themeProvider = themeProvider
        // ⚠️ 与 themeProvider 同模式：闭包集跨批次刷新
        textView.onFileDrop = onFileDrop
        // IME compose 期间跳过回填：S-014 打开文件恰逢 compose 时不销毁候选串（FR-006）；
        // 值比较已内置于 setTextProgrammatically（相同文本短路，不再需要外部 != 判断）
        // ⚠️ FixD2b（评审 IMPORTANT #1）：折叠激活时跳过回填——折叠态显示由 toggleFold 维护，
        // 回填陈旧 editorText（折叠前全文）会 removeAllFolds + 显示重置（静默清折叠）；
        // 打开/新建文件路径经 onTextRead 先清折叠再写 editorText（MainApp 侧配对修复），
        // 此处守卫不阻断文档切换。
        if !textView.hasMarkedText(), textView.foldState.folded.isEmpty {
            // ⚠️ 修订（审查 CRITICAL #2 第 2 轮）：wrote 后显式触发渲染——
            // 抑制通知 ≠ 阻断渲染链路：回填不再触发 didChangeNotification →
            // onTextDidChange 不调用 → coordinator.input 不执行 → 打开/新建文件
            // 后预览不更新（功能回归）。写入后显式调 onTextDidChange：
            // coordinator.input → editorText 值相同（onTextRead 已写）→ 不再回填 → 收敛
            let wrote = textView.setTextProgrammatically(text)
            if wrote {
                context.coordinator.onTextDidChange?(text)
            }
        }
    }

    // MARK: - Coordinator

    // ⚠️ 适配（Swift 6.2 SE-0411）：ScrollTracker 为 @MainActor，`let tracker = ScrollTracker()`
    // 作为非隔离类存储属性默认值触发 "main actor-isolated default value in a nonisolated context"；
    // 与 T1.6 先例一致：类补 @MainActor（makeCoordinator/makeNSView/updateNSView 均为 @MainActor 上下文）
    @MainActor
    final class Coordinator {
        var onTextDidChange: ((String) -> Void)?
        var onRawTextDidChange: ((String) -> Void)?
        var onSelectionDidChange: ((NSRange) -> Void)?
        var onScrollRatio: ((Double) -> Void)?
        var onComposeStateChange: ((Bool) -> Void)?
        var onTextViewCreated: ((MarkdownTextView) -> Void)?
        let tracker = ScrollTracker()

        init(onTextDidChange: ((String) -> Void)?,
             onRawTextDidChange: ((String) -> Void)?,
             onSelectionDidChange: ((NSRange) -> Void)?,
             onScrollRatio: ((Double) -> Void)?,
             onComposeStateChange: ((Bool) -> Void)?,
             onTextViewCreated: ((MarkdownTextView) -> Void)?) {
            self.onTextDidChange = onTextDidChange
            self.onRawTextDidChange = onRawTextDidChange
            self.onSelectionDidChange = onSelectionDidChange
            self.onScrollRatio = onScrollRatio
            self.onComposeStateChange = onComposeStateChange
            self.onTextViewCreated = onTextViewCreated
        }
    }
}
