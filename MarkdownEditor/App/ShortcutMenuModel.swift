import SwiftUI

// ShortcutMenuModel.swift — 快捷键菜单动态刷新数据源（T3.4，FR-065）
// 监听 UserDefaults.didChangeNotification → version += 1 → @StateObject objectWillChange
// → App.body（含 .commands 格式菜单）重算 → shortcutKey/shortcutModifiers 重读
// ShortcutManager.mergedBindings（RecentFilesMenuModel 先例，审查 MINOR #4 修正）；
// "不依赖 keyWindowState"约束保持——刷新触发源是 defaults 通知，查询是纯静态函数，均无 key window 依赖。
// Shortcut menu dynamic refresh data source: observes defaults changes and bumps a
// version counter so the App body (including .commands) re-evaluates and re-reads
// ShortcutManager.mergedBindings (RecentFilesMenuModel precedent, review MINOR #4 fix).
@MainActor
final class ShortcutMenuModel: ObservableObject {
    /// 版本号：defaults 变化 +1（App.body 重算触发信号，本身无业务含义）
    @Published var version = 0
    private var token: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.version += 1 }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
