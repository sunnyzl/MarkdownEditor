import AppKit

// ThemeService.swift — 主题单一事实源（S-015，AD-10，FR-083/105）
// 三态（light/dark/system）；双轨下发：① 编辑器外观 ② 预览 CSS 变量（<100ms，AD-10 Rule）
// ⚠️ 修复 #7（第 5 轮）：删除 @Published——ThemeService 不 conform ObservableObject，
// @Published 无发布行为（无订阅者），属语义冗余/误导。用普通属性即可。
@MainActor
final class ThemeService {
    enum Key { static let mode = "themeMode" }

    private(set) var mode: ThemeMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    /// effective：system 解析后的实际模式（编辑器/预览共用）
    private(set) var effectiveMode: ThemeMode

    private let preview: PreviewProtocol?
    private let editorSink: ((ThemeMode) -> Void)?
    private let defaults: UserDefaults
    private var appearanceObserver: NSKeyValueObservation?

    init(preview: PreviewProtocol? = nil,
         editorSink: ((ThemeMode) -> Void)? = nil,
         defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: Key.mode).flatMap(ThemeMode.init(rawValue:)) ?? .system
        self.mode = stored
        self.effectiveMode = stored   // 占位：apply() 立即重算为真实解析值（删除与 apply() 重复的解析）
        self.preview = preview
        self.editorSink = editorSink
        self.defaults = defaults
        observeSystemAppearance()
        // ⚠️ 初始下发：创建即双轨生效（FR-105 持久化/默认 system 启动即下发，AD-10）。
        // webview 未就绪时 setTheme 仅产生被捕获的 evaluateJavaScript 错误（NFR-012），不崩溃
        apply()
    }

    /// 切换主题（FR-083 三选项）
    func select(_ newMode: ThemeMode) {
        guard newMode != mode else { return }
        mode = newMode
        apply()
    }

    /// 双轨下发（AD-10 Rule：原子同步 < 100ms）
    func apply() {
        effectiveMode = mode == .system ? Self.systemMode() : mode
        let target = effectiveMode
        editorSink?(target)              // ① 编辑器外观（NSTextView 颜色；Highlightr 预留 S-023）
        preview?.setTheme(target)        // ② 预览 CSS 变量（body.dark + hljs/mermaid 主题联动）
    }

    /// system 解析：NSApp.effectiveAppearance（macOS 14）
    static func systemMode() -> ThemeMode {
        guard let app = NSApp else { return .light }
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private func observeSystemAppearance() {
        // 跟随系统：系统外观变化 → 重新下发（FR-083）
        guard let app = NSApp else { return }   // 无 NSApp（hostless 测试）跳过观察
        appearanceObserver = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.apply() }
        }
    }
}
