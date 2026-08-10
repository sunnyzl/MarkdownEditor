import Foundation

// NotificationNames.swift — 通知名称集中定义（P1 后置：MainApp 拆分纯重构）
// 原 MainApp.swift 迁移（评审豁免待办落地；零行为变化）
// 编辑器主题通知（AD-10 ① 侧：MarkdownTextView 订阅后更新 appearance/颜色）
extension Notification.Name {
    static let editorThemeDidChange = Notification.Name("editorThemeDidChange")
}
