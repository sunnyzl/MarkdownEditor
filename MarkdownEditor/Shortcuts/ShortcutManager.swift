import AppKit

// ShortcutManager.swift — 快捷键基础设施（S-020 实装，NFR-022 承载）
// 静态绑定表 = 单一事实源：defaultBindings 预填 19 命令全键位（FR-051~064 + 分栏），
// 格式菜单 keyboardShortcut 直读（菜单构建不依赖 keyWindowState——启动时 keyWindow nil
// 会回退错误绑定且 .commands 不重求值，审查 IMPORTANT #3）；
// makeMenuItems 从绑定表生成 NSMenuItem（测试面，不注入 mainMenu——SwiftUI .commands 接管
// 菜单生命周期，防场景重建时菜单丢失/重复，设计 §4 方案 1 vs 方案 2）；
// execute 分发到注册的 CommandDispatcher（每窗口 CommandExecutor）
// Static binding table as single source of truth; makeMenuItems is a test surface only;
// execute dispatches to the registered per-window executor.
enum EditorCommand: String, CaseIterable {
    // P0 格式化（S-021，FR-051~057）/ P0 formatting
    case bold, italic, inlineCode, codeBlock, link, image
    case heading1, heading2, heading3, heading4, heading5, heading6
    // P1 扩展（S-022，FR-058~064）/ P1 extensions
    case table, taskList, mathInline, mathBlock, blockquote, strikethrough
    // 布局 / Layout
    case togglePane

    /// 中文显示名（S-020 实装；格式菜单/菜单项 title）
    var title: String {
        switch self {
        case .bold: return "粗体"
        case .italic: return "斜体"
        case .inlineCode: return "行内代码"
        case .codeBlock: return "代码块"
        case .link: return "链接"
        case .image: return "图片"
        case .heading1: return "标题 1"
        case .heading2: return "标题 2"
        case .heading3: return "标题 3"
        case .heading4: return "标题 4"
        case .heading5: return "标题 5"
        case .heading6: return "标题 6"
        case .table: return "表格"
        case .taskList: return "任务列表"
        case .mathInline: return "行内公式"
        case .mathBlock: return "块级公式"
        case .blockquote: return "引用"
        case .strikethrough: return "删除线"
        case .togglePane: return "切换分栏"
        }
    }
}

// 命令分发目标（AD-2 跨模块通信：Shortcuts → Editor）
// ⚠️ @MainActor 保留（ModuleProtocols.swift 先例一致；CommandExecutor 实现方同隔离）
@MainActor
protocol CommandDispatcher: AnyObject {
    func execute(_ command: EditorCommand)
}

@MainActor
final class ShortcutManager {
    /// 静态绑定表（单一事实源）：init 复制为实例 bindings；格式菜单 keyboardShortcut 直读。
    /// ⚠️ 设计决策 #1：删除线用 PRD 备选 Cmd+Opt+S（FR-064）——Cmd+Shift+S 已被"另存为"占用
    ///（MainApp.swift:41-43），主键位冲突，备选键位定稿。
    /// NFR-022：FR-051~060 100% 可绑定（实际 19 命令全绑定）。
    static let defaultBindings: [EditorCommand: (key: String, modifiers: NSEvent.ModifierFlags)] = [
        .bold: ("b", [.command]),
        .italic: ("i", [.command]),
        .inlineCode: ("`", [.command, .shift]),
        .codeBlock: ("k", [.command, .shift]),
        .link: ("k", [.command]),
        .image: ("i", [.command, .shift]),
        .heading1: ("1", [.command]),
        .heading2: ("2", [.command]),
        .heading3: ("3", [.command]),
        .heading4: ("4", [.command]),
        .heading5: ("5", [.command]),
        .heading6: ("6", [.command]),
        .table: ("t", [.command, .option]),
        .taskList: ("l", [.command, .shift]),
        .mathInline: ("m", [.command, .option]),
        .mathBlock: ("m", [.command, .shift]),
        .blockquote: (".", [.command, .shift]),
        .strikethrough: ("s", [.command, .option]),   // Cmd+Opt+S（设计决策 #1）
        .togglePane: ("\\", [.command]),
    ]

    // ── T3.4（FR-065）快捷键可配置：defaults 覆盖 + 合并绑定表 ──
    // 存储键约定：shortcut.{command.rawValue}.key / .modifiers（modifiers 存 rawValue UInt）；
    // 纯函数（无 key window / 无实例状态依赖）→ 格式菜单与单测共用数据源，
    // 菜单构建"不依赖 keyWindowState"约束保持（审查 IMPORTANT #3）
    /// defaults 存储键前缀 / Storage key prefix
    static let storageKeyPrefix = "shortcut"

    /// 读取 defaults 中覆盖的按键（nil = 未覆盖，回退 defaultBindings）
    static func storedKey(for command: EditorCommand, defaults: UserDefaults) -> String? {
        defaults.string(forKey: "\(storageKeyPrefix).\(command.rawValue).key")
    }

    /// 读取 defaults 中覆盖的修饰键（nil = 未覆盖；object 判存区分"未存储"与空修饰键）
    static func storedModifiers(for command: EditorCommand, defaults: UserDefaults) -> NSEvent.ModifierFlags? {
        guard let raw = defaults.object(forKey: "\(storageKeyPrefix).\(command.rawValue).modifiers") as? NSNumber else {
            return nil
        }
        return NSEvent.ModifierFlags(rawValue: raw.uintValue)
    }

    /// FR-065：defaults 覆盖 defaultBindings 的合并绑定表（纯函数可测）
    /// 覆盖规则：storedKey/storedModifiers 非 nil 时替换对应字段，否则保持默认
    static func mergedBindings(defaults: UserDefaults) -> [EditorCommand: (key: String, modifiers: NSEvent.ModifierFlags)] {
        var merged: [EditorCommand: (key: String, modifiers: NSEvent.ModifierFlags)] = [:]
        for (command, binding) in defaultBindings {
            let key = storedKey(for: command, defaults: defaults) ?? binding.key
            let modifiers = storedModifiers(for: command, defaults: defaults) ?? binding.modifiers
            merged[command] = (key, modifiers)
        }
        return merged
    }

    private weak var dispatcher: CommandDispatcher?
    private var bindings: [EditorCommand: (key: String, modifiers: NSEvent.ModifierFlags)] = [:]

    init() {
        bindings = Self.defaultBindings
    }

    func registerDispatcher(_ dispatcher: CommandDispatcher) {
        self.dispatcher = dispatcher
    }

    /// 查询绑定（makeMenuItems 数据源 / tests）
    func binding(for command: EditorCommand) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        bindings[command]
    }

    /// S-020 实装：绑定表 → NSMenuItem（keyEquivalent/modifiers/title 全量生成）
    /// 测试面（S-020 AC"自动生成菜单项"）；不注入 mainMenu（SwiftUI .commands 接管）
    func makeMenuItems() -> [NSMenuItem] {
        EditorCommand.allCases.compactMap { command in
            guard let binding = bindings[command] else { return nil }
            let item = NSMenuItem(title: command.title, action: #selector(dispatchCommand(_:)), keyEquivalent: binding.key)
            item.keyEquivalentModifierMask = binding.modifiers
            item.target = self
            item.representedObject = command.rawValue
            return item
        }
    }

    func execute(_ command: EditorCommand) {
        dispatcher?.execute(command)
    }

    /// 菜单项 action：representedObject 回解命令 → 分发（经注册 dispatcher → 当前窗口 executor）
    @objc private func dispatchCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = EditorCommand(rawValue: raw) else { return }
        execute(command)
    }

    // ── P1 后置（FR-065 面板补齐）：冲突检测 + 录制存储（数据层；UI 在 PreferencesView）──

    /// 应用菜单级占用键位（已知冲突集——非全量枚举；用户录制不得覆盖）。
    /// 仅含非 EditorCommand 的菜单命令；EditorCommand 重叠由 conflictMessage 的
    /// "其他命令"检查覆盖（strikethrough Cmd+Opt+S / togglePane Cmd+\ 等默认绑定不重复列入）
    /// App-menu-level occupied combos (known set — not exhaustive; recordings must not steal them)
    static let systemReservedBindings: [(key: String, modifiers: NSEvent.ModifierFlags, name: String)] = [
        ("s", [.command], "保存"),
        ("s", [.command, .shift], "另存为"),
        ("o", [.command], "打开"),
        ("n", [.command], "新建窗口"),
        ("f", [.command], "查找"),
        ("g", [.command], "查找下一个"),
        ("g", [.command, .shift], "查找上一个"),
        ("+", [.command], "放大预览"),
        ("-", [.command], "缩小预览"),
        ("0", [.command], "实际大小"),
        ("f", [.command, .option], "聚焦模式"),
        ("f", [.command, .shift], "折叠/展开当前标题"),   // ⚠️ P1-2 新菜单（非 EditorCommand）
    ]

    /// 冲突检测纯函数（可单测）：应用级占用（systemReservedBindings）+ 其他命令当前绑定
    /// （mergedBindings——含 defaults 覆盖）；命中 → 中文提示；无冲突 → nil。
    /// 命令自身的默认绑定不参与"其他命令"比较（other != command）。
    /// Conflict detection pure function: system-reserved combos + other commands' current
    /// merged bindings; returns a Chinese hint on conflict, nil when free.
    static func conflictMessage(for command: EditorCommand, defaults: UserDefaults) -> String? {
        guard let binding = mergedBindings(defaults: defaults)[command] else { return nil }
        let label = symbolLabel(binding.key, binding.modifiers)
        for reserved in systemReservedBindings
        where reserved.key == binding.key && reserved.modifiers == binding.modifiers {
            return "\(label) 已被「\(reserved.name)」占用，无法绑定"
        }
        for other in EditorCommand.allCases where other != command {
            guard let otherBinding = mergedBindings(defaults: defaults)[other] else { continue }
            if otherBinding.key == binding.key, otherBinding.modifiers == binding.modifiers {
                return "\(label) 已被「\(other.title)」占用，无法绑定"
            }
        }
        return nil
    }

    /// 录制写入（UI 按键捕获 → defaults 存储；键格式 shortcut.{cmd}.key/.modifiers 与 T3.4 同）
    /// Recording write: persists key/modifiers with the T3.4 storage key format.
    static func record(_ key: String, modifiers: NSEvent.ModifierFlags,
                       for command: EditorCommand, defaults: UserDefaults) {
        defaults.set(key, forKey: "\(storageKeyPrefix).\(command.rawValue).key")
        defaults.set(modifiers.rawValue, forKey: "\(storageKeyPrefix).\(command.rawValue).modifiers")
    }

    /// 按键归一化（录制用）：charactersIgnoringModifiers → 小写单字符；
    /// 空串/多字符（组合键字符）/空格（KeyEquivalent(" ") = 无快捷键）→ nil
    /// Recorded-key normalization: lowercase single char; invalid inputs → nil.
    static func normalizeRecordedKey(_ chars: String?) -> String? {
        guard let chars else { return nil }
        let lower = chars.lowercased()
        guard lower.count == 1, lower != " " else { return nil }
        return lower
    }

    /// 组合键符号串（⌃⌥⇧⌘ 标准顺序，⌘B 风格——冲突提示/面板展示共用）
    /// Modifier-key symbol string (⌃⌥⇧⌘ canonical order, ⌘B style)
    static func symbolLabel(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}
