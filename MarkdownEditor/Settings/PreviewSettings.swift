import AppKit

// PreviewSettings.swift — 预览配置存储（S-026，FR-035/046/047；AD-10 正交维度）
// UserDefaults 持久化；S-028 设置面板 UI 后续接线（与 S-023 高亮开关同模式）
// 正交原则（AD-10）：Mermaid 主题不并入 ThemeService 三态——ThemeService 切换
// light/dark 不再覆盖用户选择的 mermaid 主题；"跟随"由本类解析为具体值下发
// Preview settings storage (S-026; UserDefaults persistence; settings-panel UI wired later in S-028)
@MainActor
final class PreviewSettings {
    enum Key {
        /// Mermaid 主题存储键（"system" = 跟随；default/dark/forest/neutral 四选项，FR-046）
        static let mermaidTheme = "previewMermaidTheme"
        /// 单 $ 分隔符开关（FR-035，R-M1 缓解）
        static let katexSingleDollar = "previewKatexSingleDollar"
    }
    /// Mermaid 主题候选（FR-046 四选项 + 跟随标记）
    static let mermaidThemes = ["system", "default", "dark", "forest", "neutral"]
    /// 跟随标记：dark 系统 → dark，否则 default（仿 ThemeService.systemMode 先例）
    static let followThemeMarker = "system"

    private let defaults: UserDefaults

    /// Mermaid 主题存储值（"system" = 跟随；用户可改四选项）
    private(set) var mermaidTheme: String {
        didSet { defaults.set(mermaidTheme, forKey: Key.mermaidTheme) }
    }
    /// 单 $ 分隔符开关（默认 true，行为不变；用户可关，R-M1 缓解）
    private(set) var katexSingleDollar: Bool {
        didSet { defaults.set(katexSingleDollar, forKey: Key.katexSingleDollar) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.mermaidTheme) ?? Self.followThemeMarker
        // 非法存储值回退跟随（容错：手改 defaults 场景不崩溃）
        self.mermaidTheme = Self.mermaidThemes.contains(stored) ? stored : Self.followThemeMarker
        // object(forKey:) 区分"未设置"与"显式 false"（bool(forKey:) 未设置时返回 false 会误伤）
        self.katexSingleDollar = defaults.object(forKey: Key.katexSingleDollar) as? Bool ?? true
    }

    /// 设置 Mermaid 主题（非法值忽略——四选项 + 跟随）
    func setMermaidTheme(_ theme: String) {
        guard Self.mermaidThemes.contains(theme), theme != mermaidTheme else { return }
        mermaidTheme = theme
        onChange?(self)   // ⚠️ S-028：值实际变更 → 通知容器重发 setConfig
    }

    /// 设置单 $ 开关
    func setKatexSingleDollar(_ enabled: Bool) {
        guard enabled != katexSingleDollar else { return }
        katexSingleDollar = enabled
        onChange?(self)   // ⚠️ S-028：值实际变更 → 通知容器重发 setConfig
    }

    /// 生效主题：跟随 → 系统解析（dark 系统 → dark，否则 default）；其余原值
    func effectiveMermaidTheme() -> String {
        if mermaidTheme == Self.followThemeMarker {
            return ThemeService.systemMode() == .dark ? "dark" : "default"
        }
        return mermaidTheme
    }

    /// 变更回调（S-028）：设置面板写值后通知容器重发 setConfig——
    /// 补 S-026"仅 init 一次性下发"缺口（设计 §S-028 数据流；MainContentState.init 订阅）
    /// Change callback (S-028): fired after a value actually changes (guard-short-circuited),
    /// enabling the container to re-send setConfig (closes the S-026 one-shot gap).
    var onChange: ((PreviewSettings) -> Void)?
}
