import AppKit

// IMEHandling.swift — IME compose 暂停信号（S-008，FR-006/NFR-014，R-A5 缓解）
// 纯逻辑状态机：compose 开始 → pause 渲染；上屏 → resume 立即渲染一次
// 事件源：MarkdownTextView.onComposeStateChange（T2.1 已内置 hasMarkedText 检测）
@MainActor
final class IMEHandling {
    private(set) var isComposing = false

    /// 状态变化回调（挂接方设置：true → RenderCoordinator.pause()；false → resume()）
    var onComposeStateChange: ((Bool) -> Void)?

    /// 由 MarkdownTextView.onComposeStateChange 转发（幂等：仅状态翻转时触发）
    func setComposing(_ composing: Bool) {
        guard composing != isComposing else { return }
        isComposing = composing
        onComposeStateChange?(composing)
    }

    /// 便捷绑定：挂接到 MarkdownTextView 的事件
    func attach(to textView: MarkdownTextView) {
        textView.onComposeStateChange = { [weak self] composing in
            self?.setComposing(composing)
        }
    }
}
