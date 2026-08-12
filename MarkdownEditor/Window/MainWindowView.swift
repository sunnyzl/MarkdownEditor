import SwiftUI
import AppKit

// MainWindowView.swift — 纯 SwiftUI 分栏容器（S-006，FR-081/082/085）
// ⚠️ 修复（round4 T1.2a，根因 2）：弃 NSSplitView（isHidden 折叠行为在 NSHostingView
// 嵌套下不确定：editorOnly 未生效 / previewOnly divider 残留 / 折叠后聚焦异常）→
// 纯 SwiftUI 三态组合（Group+switch）+ HSplitView 动态最小宽度（dynamicMinWidth 纯函数）
// ⚠️ 用户补充需求（第 1 轮）：分栏宽度动态最小化——窗口宽度 20% 比例 + 绝对下限 160，
// 保证 Mermaid 图展示空间（太窄导致图换行/变形）
// WindowPersistence 保留（FR-085）：窗口大小/位置持久化（依赖 AppKit → import AppKit 保留）

// 分栏三模式（S-022）：editorOnly / previewOnly / split
// Pane mode three-state (S-022): editorOnly / previewOnly / split
// 纯函数 next() 循环切换；toolbarIcon 供 ToolbarView 图标随模式切换
// ⚠️ S-028：补 String rawValue——默认分栏模式持久化契约（PaneSettings 存储；
// editorOnly / previewOnly / split；CaseIterable 与 next/toolbarIcon 不受影响）
enum PaneMode: String, CaseIterable {
    case editorOnly, previewOnly, split

    /// 循环切换：editorOnly → previewOnly → split → editorOnly
    /// Cycle: editorOnly → previewOnly → split → editorOnly
    var next: PaneMode {
        switch self {
        case .editorOnly: return .previewOnly
        case .previewOnly: return .split
        case .split: return .editorOnly
        }
    }

    /// SF Symbol 图标（sidebar.left / sidebar.right / rectangle.split.2x1，macOS 11+）
    var toolbarIcon: String {
        switch self {
        case .editorOnly: return "sidebar.left"
        case .previewOnly: return "sidebar.right"
        case .split: return "rectangle.split.2x1"
        }
    }
}

struct MainWindowView: View {
    let left: AnyView
    let right: AnyView
    // ⚠️ 第四轮重构（T1.2）：三态组合（MainContentState 注入；@Published 变化驱动 body 重算）
    var paneMode: PaneMode = .split
    // ⚠️ T3.1（S-034）：聚焦模式正交标志——不新增 paneMode 枚举（聚焦与分栏正交可组合）；
    // @Published 容器驱动（MainContentState.toggleFocusMode，T3.2 接线），默认 false 兼容现有调用方
    var isFocusMode: Bool = false
    // ⚠️ T3.1（FR-087）：状态栏开关 + 状态栏文本（T3.2 MainContentAssembly 经 StatusMetrics 注入）；
    // 默认值保证批次内独立可编译（T3.2 接线前行为不变）
    var showStatusBar: Bool = true
    var statusText: String = ""

    var body: some View {
        // ⚠️ 第四轮重构（T1.2，根因 2）：弃 NSSplitView（isHidden 折叠行为在 NSHostingView
        // 嵌套下不确定：editorOnly 未生效 / previewOnly divider 残留 / 折叠后聚焦异常）→
        // 纯 SwiftUI 三态组合——三态行为确定，无 divider 残留，聚焦链路简化
        // ⚠️ T3.1（S-034）：三态 Group 外层包 VStack + .safeAreaInset(edge: .bottom)
        // 条件显示状态栏（isFocusMode 时隐藏；showStatusBar 开关 FR-087）
        VStack(spacing: 0) {
            Group {
                switch paneMode {
                case .editorOnly:
                    left   // 仅渲染编辑（占满）
                case .previewOnly:
                    right  // 仅渲染预览（占满）
                case .split:
                    // ⚠️ 用户补充需求（第 1 轮）：分栏宽度动态最小化 + 手势拖拽调整——
                    // HSplitView 原生支持分隔条拖拽（放大/缩小手势 ✓）；
                    // minWidth 不再固定 220，改为动态：跟随窗口宽度比例 + 绝对下限，
                    // 保证 Mermaid 图展示空间（太窄导致图换行/变形）
                    GeometryReader { geo in
                        let dynamicMin = Self.dynamicMinWidth(windowWidth: geo.size.width)
                        HSplitView {
                            left.frame(minWidth: dynamicMin)
                            right.frame(minWidth: dynamicMin)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // ⚠️ T3.1（S-034）：状态栏——可见性判定走 statusBarVisible 纯函数
            //（聚焦模式隐藏 / 开关关闭隐藏；Text 仅展示注入的 statusText，不自行组装）
            if Self.statusBarVisible(isFocusMode: isFocusMode, showStatusBar: showStatusBar) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        // ⚠️ 修复（窗口跳变）：移除 WindowPersistence——setFrameUsingName 在窗口显示后
        // 瞬移导致可见跳变；位置持久化由 SwiftUI 场景帧记忆承担（无跳变）
    }

    /// 动态最小分栏宽度（用户补充需求）：窗口宽度比例 + 绝对下限
    /// 窗口大 → 最小宽度大（Mermaid 图空间充足）；窗口小 → 最小宽度收缩（不溢出）
    /// 纯函数（无 View 依赖）→ 可直接单元测试
    static func dynamicMinWidth(windowWidth: CGFloat, ratio: CGFloat = 0.2, absoluteMin: CGFloat = 160) -> CGFloat {
        max(windowWidth * ratio, absoluteMin)
    }

    /// 状态栏可见性判定（T3.1，S-034/FR-087）：聚焦模式隐藏（即使开关开启）；
    /// showStatusBar 开关关闭隐藏。body 的 safeAreaInset 条件即此函数 → 纯函数可测
    static func statusBarVisible(isFocusMode: Bool, showStatusBar: Bool) -> Bool {
        !isFocusMode && showStatusBar
    }

    /// 字数统计（T3.1，S-034）：**Character 语义**——按空白分割计数，
    /// 中文/emoji 不按字节切碎（UTF-16 安全）；空串/纯空白 → 0
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// 行列定位（T3.1，S-034）：前缀换行计数（0-based 行号）+ 行内 UTF-16 偏移（列号）
    /// 与 selectionLineRatio/cursorLine 同构（NSString.substring(to:) UTF-16 安全，
    /// emoji/中文前缀不漂移）；NSRange.location 为 UTF-16 位置；
    /// 越界（location < 0 或 > length）→ (0, 0)（cursorLine 越界 nil 同构语义）
    static func lineColumn(text: String, selection: NSRange) -> (line: Int, column: Int) {
        let ns = text as NSString
        guard selection.location >= 0, selection.location <= ns.length else { return (0, 0) }
        let prefix = ns.substring(to: selection.location)
        let line = prefix.components(separatedBy: "\n").count - 1   // 0-based 行号
        // 行首 = 最后一个换行之后（无换行 → 0）；列号 = 光标位置 − 行首（行内 UTF-16 偏移）
        let lastNewline = (prefix as NSString).range(of: "\n", options: .backwards)
        let lineStart = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
        return (line, selection.location - lineStart)
    }

    /// 状态栏文本组装（T3.2，S-034/FR-087）：字数（Character 语义）+ 字符数 + 行列。
    /// 显示约定 1-based（lineColumn 0-based 行号/列号 → 显示 +1）；纯函数可测，
    /// MainContentAssembly 以 latestEditorText + latestSelection 组装后注入。
    /// Status bar text assembly: word count (Character semantics) + char count +
    /// line:column (0-based → 1-based display).
    static func statusText(text: String, selection: NSRange) -> String {
        let (line, column) = lineColumn(text: text, selection: selection)
        return "\(wordCount(text)) 词 · \(text.count) 字符 · 行 \(line + 1), 列 \(column + 1)"
    }
}
