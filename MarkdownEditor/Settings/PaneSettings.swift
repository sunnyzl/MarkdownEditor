import AppKit

// PaneSettings.swift — 默认分栏模式持久化（S-028，FR-106）
// PaneMode String rawValue 存储（T1.4 补 rawValue）；MainContentState.init 读默认
//（FR-106：仅影响启动/新窗口——运行中切换由 MainContentState.@Published 驱动，保持现状）；
// 非法存储值回落 .split（ThemeService/PreviewSettings 容错先例）
// Default pane-mode persistence (S-028; read at container init; runtime @Published stays)
@MainActor
final class PaneSettings {
    enum Key {
        /// 默认分栏模式存储键（PaneMode rawValue：editorOnly / previewOnly / split）
        static let paneMode = "defaultPaneMode"
    }

    private let defaults: UserDefaults

    /// 默认分栏模式（仅影响启动/新窗口；运行中切换由 MainContentState.@Published 驱动）
    private(set) var paneMode: PaneMode {
        didSet { defaults.set(paneMode.rawValue, forKey: Key.paneMode) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 非法存储值回落 .split（手改 defaults 不崩溃）
        let stored = defaults.string(forKey: Key.paneMode).flatMap(PaneMode.init(rawValue:)) ?? .split
        self.paneMode = stored
    }

    /// 设置默认分栏模式（同值忽略）
    func setPaneMode(_ mode: PaneMode) {
        guard mode != paneMode else { return }
        paneMode = mode
    }
}
