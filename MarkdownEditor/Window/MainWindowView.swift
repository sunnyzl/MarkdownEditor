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
        .background(WindowPersistence())   // FR-085：窗口大小/位置持久化（保留，结构不动）
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

// 窗口大小/位置持久化（FR-085）：setFrameUsingName 恢复，willClose 保存
// Window size/position persistence (FR-085): restore via setFrameUsingName, save on willClose
struct WindowPersistence: NSViewRepresentable {
    static let frameName = "MainWindow"

    /// 恢复窗口 frame（FR-085）。抽为 static 供 didBecomeKey 观察者复用。
    /// ⚠️ 修复（T2.1，根因 = 窗口恢复布局循环，T1.3 已确认）：恢复时机从 makeNSView 的
    /// Task 内（窗口显示前）延迟到窗口首次显示后——启动时立即 setFrameUsingName 参与
    /// NSHostingView/NSSplitView 初始布局往返 → AttributeGraph cycle（145360/144248/…）。
    /// 窗口显示后再设帧不参与初始布局，cycle 消除且 FR-085 持久化能力保留。
    /// ⚠️ 计划 API 缺陷适配：计划用 NSWindow.didBecomeVisibleNotification，但该通知在
    /// AppKit 中不存在（SDK NSWindow.h 已核实）——改用 didBecomeKeyNotification：
    /// 单窗口 app 显示路径（makeKeyAndOrderFront）必然触发，语义等价「窗口首次显示后」。
    /// Restore window frame (FR-085), extracted as static for reuse by the
    /// didBecomeKey observer (T2.1 fix: delayed restore after first display).
    /// Plan API defect adapted: NSWindow.didBecomeVisibleNotification does not exist
    /// in AppKit (verified in SDK NSWindow.h) — switched to didBecomeKeyNotification,
    /// which always fires on the makeKeyAndOrderFront show path of a single-window app.
    static func restoreFrame(for window: NSWindow) {
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1100, height: 720))
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // ⚠️ 修复 #4（第 7 轮）：DispatchQueue.main.async 闭包访问 @MainActor 属性（window）是警告源；
        // 改用 Task { @MainActor in } 显式隔离
        // Fix #4 (round 7): use Task { @MainActor in } for explicit isolation
        Task { @MainActor in
            guard let window = view.window else { return }
            // 批次1 内存优化（design §批次1 根因③）：关闭 macOS 窗口恢复（App 重启不恢复窗口状态），
            // 换取 @StateObject 释放稳定性（个人工具权衡）。frame 持久化（FR-085）经由
            // setFrameUsingName/saveFrame 独立工作，不受影响。
            // Disable session restoration for memory stability (personal-tool tradeoff).
            // Frame persistence (FR-085) is independent and still works.
            window.isRestorable = false
            // 批次1 内存修复（design §批次1 根因②）：willClose observer 一次性自移除——
            // 触发保存 frame 后立即 remove，防常驻观察者泄漏（CWE-772）。
            // 与下方 didBecomeKey 的 token 自移除同模式。
            // Self-removing observer (batch 1): remove after fire, same pattern as didBecomeKey.
            var willCloseToken: NSObjectProtocol?
            willCloseToken = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { note in
                guard let w = note.object as? NSWindow else { return }
                w.saveFrame(usingName: Self.frameName)
                if let t = willCloseToken { NotificationCenter.default.removeObserver(t) }
            }
            // ⚠️ T2.1：竞态分支——Task 执行时窗口可能已显示（窗口恢复/快速启动场景），
            // isVisible 直接恢复，避免 didBecomeKey 永不触发导致 frame 永不恢复；
            // 未显示 → 等首次显示（become key）后恢复（不参与初始布局往返 → cycle 消除）
            // ⚠️ 评审补充（IMPORTANT）：观察者一次性自移除——触发后 removeObserver，
            // 防常驻观察者泄漏（CWE-772）
            if window.isVisible {
                Self.restoreFrame(for: window)
            } else {
                var token: NSObjectProtocol?
                token = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { note in
                    guard let w = note.object as? NSWindow else { return }
                    Self.restoreFrame(for: w)
                    if let t = token { NotificationCenter.default.removeObserver(t) }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
