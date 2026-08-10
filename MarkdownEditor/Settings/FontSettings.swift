import AppKit

// FontSettings.swift — 编辑器字体存储（S-027，FR-086/101；AD-10 存储模式照抄 ThemeService/PreviewSettings）
// UserDefaults 存储 fontName + pointSize 二元组（NSFont 不直接 Codable）；
// 默认 monospacedSystemFont(14)（保持现状行为 MarkdownTextView.swift:61）；
// didSet 落盘 + defaults 注入；非法值忽略（PreviewSettings 容错先例）；
// 预览 CSS 字体族派生（S-027 ⑤：--font-family 跟随编辑器字体；--code-font-family 恒等宽）
// Editor font storage (S-027; UserDefaults fontName + pointSize tuple; NSFont is not Codable)
@MainActor
final class FontSettings {
    enum Key {
        /// 字体名存储键（空字符串 = 未设置 → font 回落默认等宽字体）
        static let fontName = "editorFontName"
        /// 字号存储键（点值，Double 落盘）
        static let pointSize = "editorFontPointSize"
    }
    /// 默认字号（保持现状 monospacedSystemFont(14)）
    static let defaultPointSize: CGFloat = 14
    /// 默认正文字体族栈（预览 CSS --font-family；与 preview.html :root 现状一致）
    static let defaultBodyFontFamily = "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"
    /// 默认代码字体族栈（预览 CSS --code-font-family；与 preview.html code 规则现状一致）
    static let defaultCodeFontFamily = "ui-monospace, Menlo, monospace"

    private let defaults: UserDefaults

    /// 字体名（空 = 未设置 → font 回落 monospacedSystemFont；PreviewSettings 非法值容错先例）
    private(set) var fontName: String {
        didSet { defaults.set(fontName, forKey: Key.fontName) }
    }
    /// 字号（> 0 且 ≤ 288 才写入；非法值忽略——保持当前值）
    private(set) var pointSize: CGFloat {
        didSet { defaults.set(Double(pointSize), forKey: Key.pointSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 未设置 → 空串（font() 回落默认等宽字体，行为不变）
        self.fontName = defaults.string(forKey: Key.fontName) ?? ""
        // 非法存储值（≤0 / >288）回落默认字号（手改 defaults 不崩溃）
        let stored = (defaults.object(forKey: Key.pointSize) as? NSNumber)?.doubleValue
            ?? Double(Self.defaultPointSize)
        self.pointSize = (stored > 0 && stored <= 288) ? CGFloat(stored) : Self.defaultPointSize
    }

    /// 当前字体（fontName 为空或不可解析 → monospacedSystemFont(pointSize)，保持现状行为）
    var font: NSFont {
        if !fontName.isEmpty, let named = NSFont(name: fontName, size: pointSize) { return named }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    /// 设置字体（NSFontPanel changeFont 入口；非法字号忽略——保持当前值，错误处理 §6）
    func setFont(_ newFont: NSFont) {
        guard newFont.pointSize > 0, newFont.pointSize <= 288 else { return }
        guard newFont.fontName != fontName || newFont.pointSize != pointSize else { return }
        fontName = newFont.fontName
        pointSize = newFont.pointSize
    }

    /// 预览正文 CSS 字体族（S-027 ⑤）：跟随编辑器字体（fontName 为空 → 系统默认栈保持现状）
    /// PostScript 名无空格 → CSS font-family 安全（无需引号包裹）
    /// ⚠️ 收尾批次（标签刷新）：推导提为 static 纯函数（单一事实源）——实例属性与
    /// PreferencesView 标签 @AppStorage 复用同一推导（fontName 为空 → 默认栈；否则 fontName + 回退栈）
    static func previewBodyFontFamily(for fontName: String) -> String {
        guard !fontName.isEmpty else { return Self.defaultBodyFontFamily }
        return "\(fontName), -apple-system, BlinkMacSystemFont, sans-serif"
    }

    var previewBodyFontFamily: String { Self.previewBodyFontFamily(for: fontName) }

    /// 预览代码 CSS 字体族（S-027 ⑤）：恒等宽栈——代码块对齐可读性优先；
    /// 预览/编辑器独立配置（设计 Open Question）推迟 Epic-5（见 plan-index 执行要点 5）
    var previewCodeFontFamily: String { Self.defaultCodeFontFamily }
}
