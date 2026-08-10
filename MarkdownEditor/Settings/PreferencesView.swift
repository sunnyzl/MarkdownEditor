import SwiftUI
import AppKit

// PreferencesView.swift — 设置面板（S-028，FR-101~108；Settings scene Cmd+, 承载）
// 5 区：字体（编辑器 NSFontPanel + 预览 CSS 只读展示）/ 渲染（Mermaid 主题 + 单$ + debounce
// Slider FR-104）/ 编辑器（高亮 + 行号 + 自动缩进 + 括号配对，行号标注 Epic-5 生效）/
// 窗口（默认分栏模式 + 状态栏 FR-087）/ 快捷键（绑定展示 + 恢复默认 FR-065）
// 变更链路（设计 §S-028 广播链路）：SettingsApplier 写 defaults → 广播
// .editorSettingsDidChange(userInfo: [changedKeys]) → 各模块按变更键应用
// Settings panel (S-028): 5 groups; changes write defaults (via SettingsApplier)
// then broadcast .editorSettingsDidChange with the changed-key set.

/// 设置变更应用器（S-028）：写 defaults + 广播（可独立 XCTest——post 闭包注入 Mock 观察者）
/// Settings change applier (S-028): writes defaults + broadcasts (independently testable —
/// the post closure is injected with a Mock observer in tests).
@MainActor
final class SettingsApplier {
    let font: FontSettings
    let preview: PreviewSettings
    let pane: PaneSettings
    let defaults: UserDefaults
    /// 广播出口（生产 = NotificationCenter.post；测试 = Mock 观察者记录）
    /// Post outlet (production = NotificationCenter.post; tests = Mock observer recording).
    private let post: ([String]) -> Void

    init(font: FontSettings = FontSettings(),
         preview: PreviewSettings = PreviewSettings(),
         pane: PaneSettings = PaneSettings(),
         defaults: UserDefaults = .standard,
         post: (([String]) -> Void)? = nil) {
        self.font = font
        self.preview = preview
        self.pane = pane
        self.defaults = defaults
        // 生产默认出口：NotificationCenter 广播（object: nil + changedKeys userInfo，与 editorThemeDidChange 同构）
        // Production default outlet: NotificationCenter broadcast (object: nil + changedKeys userInfo,
        // isomorphic with editorThemeDidChange).
        self.post = post ?? { keys in
            NotificationCenter.default.post(
                name: .editorSettingsDidChange, object: nil,
                userInfo: [SettingsNotificationUserInfoKey.changedKeys: keys])
        }
    }

    /// 编辑器字体（NSFontPanel 变更入口）：FontSettings 更新（didSet 落盘）+ 广播 font 键
    /// Editor font (NSFontPanel change entry): FontSettings updates (didSet persists) + broadcasts font key.
    func setEditorFont(_ newFont: NSFont) {
        font.setFont(newFont)
        post([SettingsChangeKey.font])
    }

    /// Mermaid 主题（FR-102）：PreviewSettings 更新（onChange 触发容器 setConfig 重发）+ 广播
    /// Mermaid theme (FR-102): PreviewSettings updates (onChange triggers container setConfig re-send) + broadcast.
    func setMermaidTheme(_ theme: String) {
        preview.setMermaidTheme(theme)
        post([SettingsChangeKey.mermaidTheme])
    }

    /// 单 $ 开关（FR-103）
    /// Single-$ toggle (FR-103).
    func setKatexSingleDollar(_ enabled: Bool) {
        preview.setKatexSingleDollar(enabled)
        post([SettingsChangeKey.katexSingleDollar])
    }

    /// 高亮开关（FR-108）：写 defaults（SyntaxHighlighter.enabledKey）+ 广播——
    /// 订阅端 MarkdownTextView.applyHighlightSwitch（关闭清除/开启重放，T2.3）
    /// Highlight toggle (FR-108): writes defaults (SyntaxHighlighter.enabledKey) + broadcasts —
    /// subscriber MarkdownTextView.applyHighlightSwitch clears on off / replays on on (T2.3).
    func setHighlightEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SyntaxHighlighter.enabledKey)
        post([SettingsChangeKey.highlightEnabled])
    }

    /// 行号开关（FR-107）：仅存储（S-029 消费；"实时生效" AC 时序矛盾显式记录——UI 可用、
    /// 功能归 Epic-5 验证，EPIC_FILES.md S-029 定义）
    /// Line-number toggle (FR-107): store-only (consumed by S-029; the "live effect" AC
    /// ordering contradiction is explicitly recorded — UI enabled, functionality verified in Epic-5).
    func setLineNumbersEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: LineNumberPreference.enabledKey)
        post([SettingsChangeKey.lineNumbersEnabled])
    }

    /// 默认分栏模式（FR-106）：PaneSettings 更新（新窗口/启动生效）+ 广播
    /// Default pane mode (FR-106): PaneSettings updates (takes effect on new window / launch) + broadcast.
    func setPaneMode(_ mode: PaneMode) {
        pane.setPaneMode(mode)
        post([SettingsChangeKey.paneMode])
    }

    /// debounce 时长（FR-104，T3.3）：写 defaults（clamp 100-1000ms 后存储）+ 广播——
    /// 订阅端 MainContentState.settingsObserver 重读 clamp 更新 coordinator.debounceInterval；
    /// 面板 Slider 控件归 T3.5（本 setter 为写入端，T3.3 先就绪）
    /// Debounce interval (FR-104, T3.3): writes defaults (clamped to 100-1000ms before storing)
    /// + broadcasts — subscriber MainContentState.settingsObserver re-reads, clamps, and updates
    /// coordinator.debounceInterval; the panel Slider control belongs to T3.5 (this setter is
    /// the write end, ready in T3.3).
    func setRenderDebounce(_ ms: Int) {
        defaults.set(RenderCoordinator.clampDebounce(ms), forKey: SettingsChangeKey.renderDebounce)
        post([SettingsChangeKey.renderDebounce])
    }

    /// 状态栏开关（FR-087，T3.5）：写 defaults（SettingsChangeKey.statusBarEnabled）+ 广播——
    /// 订阅端 MainApp.settingsObserver 重读 → showStatusBar 实时生效（T3.2 已就绪读取端）
    /// Status-bar toggle (FR-087, T3.5): writes defaults + broadcasts —
    /// subscriber MainApp.settingsObserver re-reads → showStatusBar live (read end ready in T3.2).
    func setStatusBarEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsChangeKey.statusBarEnabled)
        post([SettingsChangeKey.statusBarEnabled])
    }

    /// 自动缩进开关（FR-007，T3.5）：写 defaults（AutoIndent.enabledKey "autoIndentEnabled"）+
    /// 广播——批次 2 的 MarkdownTextView 插入时读 AutoIndent.isEnabled（同键消费）
    /// Auto-indent toggle (FR-007, T3.5): writes defaults (AutoIndent.enabledKey) + broadcasts —
    /// batch-2 MarkdownTextView reads AutoIndent.isEnabled on insert (same key consumed).
    func setAutoIndentEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AutoIndent.enabledKey)
        post([SettingsChangeKey.autoIndentEnabled])
    }

    /// 括号配对开关（FR-007，T3.5）：写 defaults（AutoPair.enabledKey "autoPairEnabled"）+
    /// 广播——批次 2 的 MarkdownTextView 插入时读 AutoPair.isEnabled（同键消费）
    /// Bracket-pair toggle (FR-007, T3.5): writes defaults (AutoPair.enabledKey) + broadcasts —
    /// batch-2 MarkdownTextView reads AutoPair.isEnabled on insert (same key consumed).
    func setAutoPairEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AutoPair.enabledKey)
        post([SettingsChangeKey.autoPairEnabled])
    }
}

// 行号偏好（S-028 存储；功能实现归 S-029 Epic-5）：
// SyntaxHighlighter.isEnabled 先例——静态 isEnabled 接口 + 存储键
// Line-number preference (S-028 storage; feature implementation belongs to S-029 / Epic-5):
// SyntaxHighlighter.isEnabled precedent — static isEnabled interface + storage key.
enum LineNumberPreference {
    static let enabledKey = "lineNumbersEnabled"
    /// 默认关（功能未实现期保守默认；S-029 实现后用户显式开启；object(forKey:) 区分未设置）
    /// Default off (conservative default while unimplemented; user enables explicitly after S-029;
    /// object(forKey:) distinguishes "unset" from explicit false).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return false }
        return defaults.bool(forKey: enabledKey)
    }
}

// NSFontPanel 适配（S-027，FR-101）：changeFont target-action。
// ⚠️ UNVERIFIED 假设 #1（用户指定）：SwiftUI Settings scene 下 responder 链投递不可依赖 →
// 显式经 NSFontManager.shared.target 挂接（WindowCloseGuard.Coordinator 先例）；
// changeFont 是 ObjC action（NSFontManager 经 objc_msgSend 调用）→ 必须 @objc 暴露。
// 手动验收 batch-04 M2；若 changeFont 不触发 → 检查 target 残留（onDisappear 已清理）
// NSFontPanel adapter (S-027, FR-101): changeFont target-action.
// ⚠️ UNVERIFIED assumption #1 (user-specified): the responder chain cannot be relied on in a
// SwiftUI Settings scene → explicitly wire NSFontManager.shared.target (WindowCloseGuard.Coordinator
// precedent); changeFont is an ObjC action → must be @objc-exposed.
// Manual acceptance in batch-04 M2; if changeFont does not fire → check for a stale target
// (cleaned up in onDisappear).
@MainActor
private final class FontPanelTarget: NSObject {
    /// 面板确认变更回调（convert 后字体）
    /// Panel-confirmed change callback (converted font).
    var onChangeFont: ((NSFont) -> Void)?

    /// NSFontManager changeFont 动作：以面板当前设置转换基准字体（标准 AppKit 模式）
    /// NSFontManager changeFont action: converts the base font with the panel's current
    /// settings (standard AppKit pattern).
    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        onChangeFont?(manager.convert(.systemFont(ofSize: FontSettings.defaultPointSize)))
    }
}

// PreferencesView — Settings scene 内容（SwiftUI Form 5 区）
// PreferencesView — Settings scene content (SwiftUI Form, 5 sections).
struct PreferencesView: View {
    private let settings: SettingsApplier
    /// NSFontPanel 目标（@State 持有 class 实例——SwiftUI struct 生命周期内稳定；
    /// macOS 14 SDK View 协议 @MainActor，@State 默认值初始化安全）
    /// NSFontPanel target (@State holds the class instance — stable across the SwiftUI struct
    /// lifecycle; macOS 14 SDK View protocol is @MainActor, so @State default init is safe).
    @State private var fontPanelTarget = FontPanelTarget()
    @State private var fontRefreshTick: Int = 0
    /// 常用等宽字体列表 / Common monospace font families
    private var monospaceFontNames: [String] {
        let common = ["Menlo", "Monaco", "SF Mono", "Courier New", "Andale Mono"]
        let available = NSFontManager.shared.availableFontFamilies.filter { common.contains($0) }
        return available.isEmpty ? common : available
    }
    /// PostScript 名 → family 名（Picker 匹配用）
    private func fontFamilyForPicker(_ postScriptName: String) -> String {
        guard !postScriptName.isEmpty,
              let font = NSFont(name: postScriptName, size: 14) else { return "Menlo" }
        return font.familyName ?? "Menlo"
    }
    /// 字体显示名 / Font display name
    private func fontDisplayName(_ name: String) -> String {
        NSFont(name: name, size: 14)?.displayName ?? name
    }

    // ⚠️ 收尾批次（清理⑤）：@AppStorage 订阅预览字体键——UserDefaults 无 SwiftUI 可观察性
    //（评审 IMPORTANT-1 先例），NSFontPanel 变更经 SettingsApplier 写 defaults → @AppStorage
    // 自动重算 body → 标签实时刷新（静态推导复用 FontSettings 单一事实源）；
    // 注：@AppStorage 绑定 UserDefaults.standard（生产下与 settings.defaults 一致；
    // 自定义 suite 需自定义 init，超出当前范围）
    @AppStorage(FontSettings.Key.fontName) private var fontName = ""
    /// 快捷键展示刷新版本号（评审 IMPORTANT-1）：UserDefaults 无 SwiftUI 可观察性——
    /// "恢复默认"清除覆盖键后 ForEach 不会自动重渲染；版本号 + .id() 强制重建该区。
    /// Shortcut display refresh version (review IMPORTANT-1): UserDefaults has no SwiftUI
    /// observability — after "Restore defaults" clears override keys, the ForEach won't
    /// re-render on its own; version bump + .id() force a rebuild of the section.
    @State private var shortcutVersion = 0
    // ⚠️ P1 后置（FR-065 录制）：录制状态 + 事件监听 + 冲突提示
    // ⚠️ Post-P1 (FR-065 recording): recording state + event monitor + conflict note
    @State private var recordingCommand: EditorCommand?
    @State private var recordingMonitor: Any?
    @State private var conflictNote: String?

    /// - Parameters:
    ///   - settings: 变更应用器（测试注入 Mock 观察者；生产默认 = 真实 defaults + 广播）
    ///   - settings: Change applier (tests inject a Mock observer; production default = real defaults + broadcast).
    init(settings: SettingsApplier? = nil) {
        self.settings = settings ?? SettingsApplier()
    }

    var body: some View {
        Form {
            Section("字体") {
                // 修复：字体选择改为 Picker 列表（用户反馈）+ 默认选中当前字体
                Picker("编辑器字体", selection: Binding(
                    get: { fontFamilyForPicker(settings.font.fontName) },
                    set: { newName in
                        let size = settings.font.pointSize
                        if let nsFont = NSFont(name: newName, size: size) {
                            settings.setEditorFont(nsFont)
                            fontRefreshTick += 1   // 触发 Picker 刷新
                        }
                    })) {
                    ForEach(monospaceFontNames, id: \.self) { name in
                        Text(fontDisplayName(name)).tag(name)
                    }
                }
                Picker("字号", selection: Binding(
                    get: { Double(settings.font.pointSize) },
                    set: { newSize in
                        let name = settings.font.fontName.isEmpty ? "Menlo" : settings.font.fontName
                        let nsFont = NSFont(name: name, size: CGFloat(newSize))
                            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(newSize), weight: .regular)
                        settings.setEditorFont(nsFont)
                        fontRefreshTick += 1
                    })) {
                    ForEach([11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 18.0, 20.0, 24.0], id: \.self) { size in
                        Text(String(Int(size))).tag(size)
                    }
                }
                LabeledContent("当前", value: "\(FontSettings(defaults: .standard).fontName.isEmpty ? "Menlo" : FontSettings(defaults: .standard).fontName) \(Int(FontSettings(defaults: .standard).pointSize))pt")
                LabeledContent("预览字体", value: FontSettings.previewBodyFontFamily(for: fontName))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("渲染") {
                Picker("Mermaid 主题", selection: themeBinding) {
                    ForEach(PreviewSettings.mermaidThemes, id: \.self) { theme in
                        Text(themeLabel(theme)).tag(theme)
                    }
                }
                Toggle("单 $ 分隔符", isOn: singleDollarBinding)
                // debounce 时长（FR-104，T3.5 UI 控件）：Slider 100-1000ms，写入端
                // setRenderDebounce（T3.3 就绪）→ 订阅端 clamp 更新 coordinator.debounceInterval
                // Debounce interval (FR-104, T3.5 UI): Slider 100-1000ms; write end
                // setRenderDebounce (ready in T3.3) → subscriber clamps coordinator.debounceInterval.
                LabeledContent("渲染防抖") {
                    Text("\(Int(debounceBinding.wrappedValue)) ms")
                        .monospacedDigit()
                }
                Slider(value: debounceBinding, in: 100...1000, step: 50)
            }
            Section("编辑器") {
                Toggle("语法高亮", isOn: highlightBinding)
                Toggle("行号", isOn: lineNumbersBinding)
                // ⚠️ 行号功能归 S-029（Epic-5）：开关仅保存偏好——AC 时序矛盾显式记录
                // ⚠️ Line-number functionality belongs to S-029 (Epic-5): this toggle only saves the
                // preference — the AC ordering contradiction is explicitly recorded.
                Text("行号功能将在 Epic-5（S-029）生效——本开关仅保存偏好。")
                    .font(.caption).foregroundStyle(.secondary)
                // 自动缩进/括号配对（FR-007，批次 2 功能已就绪——本面板仅接线同键开关；
                // 批次 2 的 AutoIndent/AutoPair.isEnabled 插入时实时读取）
                // Auto-indent / bracket-pair (FR-007, batch-2 features already shipped — this panel
                // only wires the same-key toggles; batch-2 AutoIndent/AutoPair.isEnabled read live on insert).
                Toggle("自动缩进", isOn: autoIndentBinding)
                Toggle("括号配对", isOn: autoPairBinding)
            }
            Section("窗口") {
                Picker("默认分栏模式", selection: paneModeBinding) {
                    Text("分栏").tag(PaneMode.split)
                    Text("仅编辑").tag(PaneMode.editorOnly)
                    Text("仅预览").tag(PaneMode.previewOnly)
                }
                // 状态栏开关（FR-087，T3.5）：写入端 setStatusBarEnabled → 订阅端
                // MainApp.settingsObserver 重读 → showStatusBar 实时生效（T3.2 读取端就绪）
                // Status-bar toggle (FR-087, T3.5): write end setStatusBarEnabled → subscriber
                // MainApp.settingsObserver re-reads → showStatusBar live (T3.2 read end ready).
                Toggle("状态栏", isOn: statusBarBinding)
            }
            Section("快捷键") {
                // 当前绑定展示（FR-065）+ 点击录制（P1 后置：按键捕获 → defaults 存储）
                // Current bindings (FR-065) + click-to-record (post-P1: key capture → defaults storage)
                Group {
                    ForEach(EditorCommand.allCases, id: \.self) { command in
                        HStack {
                            LabeledContent(command.title, value: shortcutLabel(for: command))
                            Spacer()
                            Button(recordingCommand == command ? "按任意键…" : "录制") {
                                if recordingCommand == command {
                                    cancelRecording()   // 再次点击 → 取消
                                } else {
                                    startRecording(command)
                                }
                            }
                            .buttonStyle(.borderless)
                            .help("点击后按任意组合键录制（Esc 取消）")
                        }
                    }
                    if let note = conflictNote {
                        Text(note).font(.caption).foregroundStyle(.red)
                    }
                }
                .id(shortcutVersion)
                Button("恢复默认") { restoreDefaultShortcuts() }
                    .help("清除全部快捷键自定义，恢复出厂绑定（FR-065）")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear { wireFontPanel() }
        .onDisappear {
            cancelRecording()   // 清理录制监听残留（CWE-772，NSFontManager target 清理同源）
            // 防 target 残留（面板关闭后不再收到 changeFont——CWE-772 同源）
            // Prevent a stale target (no changeFont after the panel closes — same source as CWE-772).
            if NSFontManager.shared.target === fontPanelTarget {
                NSFontManager.shared.target = nil
            }
        }
    }

    // MARK: - 绑定（UI → SettingsApplier → defaults + 广播）
    // MARK: - Bindings (UI → SettingsApplier → defaults + broadcast)

    private var themeBinding: Binding<String> {
        Binding(get: { settings.preview.mermaidTheme },
                set: { settings.setMermaidTheme($0) })
    }
    private var singleDollarBinding: Binding<Bool> {
        Binding(get: { settings.preview.katexSingleDollar },
                set: { settings.setKatexSingleDollar($0) })
    }
    private var highlightBinding: Binding<Bool> {
        Binding(get: { SyntaxHighlighter.isEnabled(defaults: settings.defaults) },
                set: { settings.setHighlightEnabled($0) })
    }
    private var lineNumbersBinding: Binding<Bool> {
        Binding(get: { LineNumberPreference.isEnabled(defaults: settings.defaults) },
                set: { settings.setLineNumbersEnabled($0) })
    }
    private var paneModeBinding: Binding<PaneMode> {
        Binding(get: { settings.pane.paneMode },
                set: { settings.setPaneMode($0) })
    }
    /// 状态栏开关（FR-087）：读 defaults（未设置 → true，与 MainApp 初始值一致）
    /// Status-bar toggle (FR-087): reads defaults (unset → true, matching MainApp's initial value).
    private var statusBarBinding: Binding<Bool> {
        Binding(get: {
            let d = settings.defaults
            return d.object(forKey: SettingsChangeKey.statusBarEnabled) == nil
                ? true : d.bool(forKey: SettingsChangeKey.statusBarEnabled)
        }, set: { settings.setStatusBarEnabled($0) })
    }
    /// debounce Slider（FR-104）：读 defaults（未设置 → 300ms 默认，与 RenderCoordinator 一致）
    /// Debounce slider (FR-104): reads defaults (unset → 300ms default, matching RenderCoordinator).
    private var debounceBinding: Binding<Double> {
        Binding(get: {
            let stored = settings.defaults.object(forKey: SettingsChangeKey.renderDebounce) as? Int
            return Double(RenderCoordinator.clampDebounce(stored ?? 300))
        }, set: { settings.setRenderDebounce(Int($0)) })
    }
    /// 自动缩进开关（FR-007）：批次 2 AutoIndent.isEnabled（同键实时读取）
    /// Auto-indent toggle (FR-007): batch-2 AutoIndent.isEnabled (same key, read live).
    private var autoIndentBinding: Binding<Bool> {
        Binding(get: { AutoIndent.isEnabled(defaults: settings.defaults) },
                set: { settings.setAutoIndentEnabled($0) })
    }
    /// 括号配对开关（FR-007）：批次 2 AutoPair.isEnabled（同键实时读取）
    /// Bracket-pair toggle (FR-007): batch-2 AutoPair.isEnabled (same key, read live).
    private var autoPairBinding: Binding<Bool> {
        Binding(get: { AutoPair.isEnabled(defaults: settings.defaults) },
                set: { settings.setAutoPairEnabled($0) })
    }

    // MARK: - 快捷键展示与恢复（FR-065：defaults 覆盖键 + 默认合并表）

    /// 当前绑定展示文本（⌘B 风格）：mergedBindings 实时读取（defaults 覆盖生效）
    /// Current binding label (⌘B style): reads mergedBindings live (defaults override applies).
    private func shortcutLabel(for command: EditorCommand) -> String {
        guard let binding = ShortcutManager.mergedBindings(defaults: settings.defaults)[command] else {
            return "—"
        }
        return modifierSymbols(binding.modifiers) + binding.key.uppercased()
    }

    /// 修饰键符号串（⌃⌥⇧⌘，标准顺序）
    /// Modifier-key symbol string (⌃⌥⇧⌘, canonical order).
    private func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// 恢复默认快捷键：清除全部命令的 defaults 覆盖键（shortcut.{cmd}.key/.modifiers）——
    /// ShortcutMenuModel 监听 defaults 通知自动刷新格式菜单（无需显式广播）
    /// Restore default shortcuts: clears every command's defaults override keys
    /// (shortcut.{cmd}.key/.modifiers) — ShortcutMenuModel observes the defaults
    /// notification and refreshes the Format menu (no explicit broadcast needed).
    private func restoreDefaultShortcuts() {
        cancelRecording()   // 盲审 #4：录制中点击恢复默认 → 先取消（防监听残留/按钮态错乱）
        for command in EditorCommand.allCases {
            let base = "\(ShortcutManager.storageKeyPrefix).\(command.rawValue)"
            settings.defaults.removeObject(forKey: "\(base).key")
            settings.defaults.removeObject(forKey: "\(base).modifiers")
        }
        conflictNote = nil   // 恢复默认后无覆盖键冲突——顺带清冲突提示（T2.3）
        // 菜单侧经 ShortcutMenuModel 监听 defaults 通知自动刷新；面板自身依赖此版本号
        // 触发 ForEach .id() 重渲染（UserDefaults 无 SwiftUI 可观察性——评审 IMPORTANT-1）
        // The menu side refreshes automatically via ShortcutMenuModel observing the
        // defaults notification; the panel itself relies on this version bump to force
        // the ForEach .id() re-render (UserDefaults has no SwiftUI observability — review IMPORTANT-1).
        shortcutVersion += 1
    }

    // MARK: - 快捷键录制（FR-065 P1 后置：点击录制 → 按键捕获 → defaults 存储 + 冲突提示）

    /// 开始录制：安装 keyDown 本地监听（Settings scene 无 responder 链——FontPanelTarget 同源模式）；
    /// 按键捕获 → normalizeRecordedKey（特殊键忽略）→ record 存储 → conflictMessage 提示 → 刷新展示；
    /// 消费按键（return nil）防录制期间误触其他命令；Esc（keyCode 53）取消。
    /// ⚠️ 适配说明：结构体不可 weak 捕获 → 强捕获 self（FontPanelTarget 的 onChangeFont 闭包同源先例）；
    /// 监听经 @State recordingMonitor 持有，cancelRecording/onDisappear 必移除——无泄漏风险。
    /// Start recording: installs a keyDown local monitor (the Settings scene has no reliable
    /// responder chain — same-source pattern as FontPanelTarget). Key capture →
    /// normalizeRecordedKey (ignores special keys) → record storage → conflictMessage note → refresh.
    /// Consumes the key (return nil) so other commands aren't triggered mid-recording;
    /// Esc (keyCode 53) cancels.
    /// ⚠️ Adaptation: a struct cannot be weak-captured → strong capture of self (same-source
    /// precedent as FontPanelTarget's onChangeFont closure); the monitor is held via the
    /// @State recordingMonitor and always removed in cancelRecording/onDisappear — no leak risk.
    private func startRecording(_ command: EditorCommand) {
        cancelRecording()   // 幂等清理旧监听（防重复安装累积）
        recordingCommand = command
        conflictNote = nil
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Swift 6：assumeIsolated 的 T 约束 Sendable（NSEvent @_nonSendable）——
            // 按键数据解包提到外层、内层只回传 Bool 消费标志（MainApp.swift "显式 Void 化防
            // assumeIsolated 泛型 T 推断冲突" 注释同源先例；SyntaxHighlighter 解包先例同源）
            // Swift 6: assumeIsolated requires T: Sendable (NSEvent is @_nonSendable) —
            // key data is unwrapped in the outer closure; the inner closure returns only a
            // Bool consume flag (same-source precedent as MainApp.swift's "explicit Void-ify
            // to prevent assumeIsolated generic T inference conflicts" note).
            guard self.recordingCommand == command else { return event }   // 非录制态 → 原样放行
            let keyCode = event.keyCode
            let chars = event.charactersIgnoringModifiers
            let flags = event.modifierFlags
            let consume = MainActor.assumeIsolated { () -> Bool in
                if keyCode == 53 {   // Esc：取消录制
                    self.cancelRecording()
                    return true
                }
                guard let key = ShortcutManager.normalizeRecordedKey(chars) else {
                    return false   // 特殊键/组合字符：忽略不消费语义（不存储）
                }
                let modifiers = flags.intersection([.command, .shift, .option, .control])
                // 盲审 #2（IMPORTANT）：拒绝裸键/仅 ⇧ 录制——keyboardShortcut 空修饰键会劫持
                // 编辑器输入（按 'a' 触发命令不键入；Tab 劫持破坏自动缩进）；要求 ⌘/⌥/⌃ 至少其一
                guard !flags.intersection([.command, .option, .control]).isEmpty else {
                    return false   // 不存储、不消费（按键放行，录制态保持）
                }
                ShortcutManager.record(key, modifiers: modifiers, for: command, defaults: self.settings.defaults)
                self.conflictNote = ShortcutManager.conflictMessage(for: command, defaults: self.settings.defaults)
                self.recordingCommand = nil
                self.removeMonitor()
                self.shortcutVersion += 1   // 面板 ForEach .id() 重渲染（菜单侧 ShortcutMenuModel 自动刷新）
                return true
            }
            return consume ? nil : event   // 消费按键（nil）或放行
        }
    }

    /// 取消录制：清状态 + 移除监听（再次点击按钮 / Esc / onDisappear 共用）
    /// Cancel recording: clears state + removes the monitor (shared by re-click / Esc / onDisappear).
    private func cancelRecording() {
        recordingCommand = nil
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
    }

    // MARK: - NSFontPanel（FR-101，S-027）

    private func openFontPanel() {
        wireFontPanel()
        // 同步面板当前选中（打开即显示当前字体——FR-101 交互验收）
        // Sync the panel's current selection (shows the current font on open — FR-101 interaction acceptance).
        NSFontManager.shared.setSelectedFont(settings.font.font, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    private func wireFontPanel() {
        // ⚠️ UNVERIFIED 假设 #1：显式 target 挂接（不依赖 responder 链）；每次点击重设幂等
        // ⚠️ UNVERIFIED assumption #1: explicit target wiring (no responder-chain reliance);
        // idempotent re-set on every click.
        fontPanelTarget.onChangeFont = { [settings] font in
            settings.setEditorFont(font)
        }
        NSFontManager.shared.target = fontPanelTarget
    }

    private func themeLabel(_ theme: String) -> String {
        theme == PreviewSettings.followThemeMarker ? "跟随系统" : theme
    }
}
