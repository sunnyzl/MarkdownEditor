import AppKit

// CommandExecutor.swift — 每窗口命令执行器（S-020，AD-2 跨模块通道实现）
// conform CommandDispatcher（@MainActor，协议先例）；每窗口实例挂 MainContentState
//（与 fileOps/themeService 同生命周期，设计 §4 方案 1）；weak 持有 textView（防循环，
// 视图树驱动注入）；文本命令 → textView.performFormatting（原生编辑链路）；
// 布局命令 → onTogglePane 闭包（分栏切换需 state 上下文，闭包注入避免依赖 MainWindowView 类型）
// Per-window command executor: text commands route to the text view's native edit path;
// layout commands (togglePane) route through an injected closure.
@MainActor
final class CommandExecutor: CommandDispatcher {
    /// 编辑器引用（EditorView.onTextViewCreated 上报 → 容器 attachTextView 注入；weak 防循环）
    /// Editor reference injected via EditorView.onTextViewCreated (weak to break cycles)
    weak var textView: MarkdownTextView?

    /// 布局命令回调（.togglePane → 容器切换 paneMode）
    var onTogglePane: (() -> Void)?

    func execute(_ command: EditorCommand) {
        if command == .togglePane {
            onTogglePane?()
            return
        }
        textView?.performFormatting(command)
    }
}
