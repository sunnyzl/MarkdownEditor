import XCTest
import AppKit
@testable import MarkdownEditor

// ShortcutManager 实装（S-020）：绑定表完整性（NFR-022）、菜单生成（AC"自动生成菜单项"）、分发
// ShortcutManager tests: binding table completeness (NFR-022), menu generation (AC "auto-generated menu items"), dispatch
@MainActor
final class ShortcutManagerTests: XCTestCase {
    /// Mock 分发目标（conform CommandDispatcher 记录命令）
    /// Mock dispatcher conforming to CommandDispatcher that records commands
    final class MockCommandDispatcher: CommandDispatcher {
        var received: [EditorCommand] = []
        func execute(_ command: EditorCommand) { received.append(command) }
    }

    // NFR-022：FR-051~060 高频操作 100% 可绑定（实际断言：全部 19 命令均有绑定）
    // NFR-022: all 19 commands must have a key binding
    func testAllCommandsHaveBindings() {
        let manager = ShortcutManager()
        for command in EditorCommand.allCases {
            XCTAssertNotNil(manager.binding(for: command), "\(command.rawValue) 必须绑定快捷键（NFR-022）")
        }
    }

    // 静态绑定表与实例绑定一致（格式菜单 keyboardShortcut 数据源 = 实例数据源，单一事实源）
    // Static table must match the instance table (single source of truth)
    func testDefaultBindingsMatchInstanceBindings() {
        let manager = ShortcutManager()
        for command in EditorCommand.allCases {
            XCTAssertEqual(manager.binding(for: command)?.key, ShortcutManager.defaultBindings[command]?.key,
                           "静态表与实例表必须一致（单一事实源）")
        }
    }

    // 设计决策 #1：删除线 = Cmd+Opt+S（避开 Cmd+Shift+S 另存为占用）
    // Design decision #1: strikethrough = Cmd+Opt+S (avoids Cmd+Shift+S conflict with Save As)
    func testStrikethroughUsesCommandOptionS() {
        let binding = ShortcutManager().binding(for: .strikethrough)
        XCTAssertEqual(binding?.key, "s")
        XCTAssertTrue(binding?.modifiers.contains(.command) == true)
        XCTAssertTrue(binding?.modifiers.contains(.option) == true)
        XCTAssertFalse(binding?.modifiers.contains(.shift) == true, "Cmd+Shift+S 已被另存为占用")
    }

    // S-020 AC"自动生成菜单项"：数量 + 关键字段（title/keyEquivalent/modifiers）
    // S-020 AC "auto-generated menu items": count + key fields (title/keyEquivalent/modifiers)
    func testMakeMenuItemsCoversAllCommands() {
        let items = ShortcutManager().makeMenuItems()
        XCTAssertEqual(items.count, EditorCommand.allCases.count)
        let bold = items.first { ($0.representedObject as? String) == EditorCommand.bold.rawValue }
        XCTAssertEqual(bold?.title, "粗体")
        XCTAssertEqual(bold?.keyEquivalent, "b")
        XCTAssertEqual(bold?.keyEquivalentModifierMask, [.command])
        let code = items.first { ($0.representedObject as? String) == EditorCommand.inlineCode.rawValue }
        XCTAssertEqual(code?.keyEquivalent, "`")
        XCTAssertEqual(code?.keyEquivalentModifierMask, [.command, .shift])
        let h6 = items.first { ($0.representedObject as? String) == EditorCommand.heading6.rawValue }
        XCTAssertEqual(h6?.title, "标题 6")
        XCTAssertEqual(h6?.keyEquivalent, "6")
    }

    // 分发：execute → 注册 dispatcher
    // Dispatch: execute → registered dispatcher
    func testExecuteDispatchesToRegisteredDispatcher() {
        let manager = ShortcutManager()
        let mock = MockCommandDispatcher()
        manager.registerDispatcher(mock)
        manager.execute(.bold)
        manager.execute(.table)
        XCTAssertEqual(mock.received, [.bold, .table])
    }

    // 菜单项 action 触发分发（S-020 完整链路：菜单 → dispatchCommand → execute）
    // Menu item action triggers dispatch (full chain: menu → dispatchCommand → execute)
    func testMenuItemActionDispatchesCommand() {
        let manager = ShortcutManager()
        let mock = MockCommandDispatcher()
        manager.registerDispatcher(mock)
        let bold = manager.makeMenuItems().first { ($0.representedObject as? String) == EditorCommand.bold.rawValue }
        _ = bold?.target?.perform(bold?.action, with: bold)
        XCTAssertEqual(mock.received, [.bold])
    }

    // 中文显示名
    // Chinese display names
    func testTitlesAreChineseDisplayNames() {
        let items = ShortcutManager().makeMenuItems()
        XCTAssertFalse(items.contains { $0.title.isEmpty })
        XCTAssertEqual(EditorCommand.bold.title, "粗体")
        XCTAssertEqual(EditorCommand.togglePane.title, "切换分栏")
    }

    // ── T3.4（FR-065）快捷键可配置：defaults 覆盖 + 合并绑定表 ──
    // suiteName 隔离 defaults（防本机 .standard 存储干扰断言——MainContentStateTests 先例）

    // 无 defaults 覆盖 → mergedBindings 与 defaultBindings 全量一致（纯函数回退路径）
    // Without overrides, mergedBindings must equal defaultBindings (fallback path)
    func testMergedBindingsMatchDefaultBindingsWithoutOverrides() {
        let name = "test.epic6.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let merged = ShortcutManager.mergedBindings(defaults: d)
        XCTAssertEqual(merged.count, ShortcutManager.defaultBindings.count)
        for command in EditorCommand.allCases {
            XCTAssertEqual(merged[command]?.key, ShortcutManager.defaultBindings[command]?.key,
                           "\(command.rawValue) 无覆盖时必须回退默认键位")
            XCTAssertEqual(merged[command]?.modifiers, ShortcutManager.defaultBindings[command]?.modifiers,
                           "\(command.rawValue) 无覆盖时必须回退默认修饰键")
        }
    }

    // defaults 覆盖合并：某命令 key/modifiers 覆盖生效，其余命令保持默认
    // Overrides apply: one command's key/modifiers overridden, others keep defaults
    func testMergedBindingsApplyDefaultsOverrides() {
        let name = "test.epic6.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        d.set("x", forKey: "shortcut.bold.key")
        d.set(NSEvent.ModifierFlags([.command, .shift]).rawValue, forKey: "shortcut.bold.modifiers")
        let merged = ShortcutManager.mergedBindings(defaults: d)
        XCTAssertEqual(merged[.bold]?.key, "x")
        XCTAssertEqual(merged[.bold]?.modifiers, [.command, .shift])
        // 未覆盖命令保持默认
        XCTAssertEqual(merged[.italic]?.key, ShortcutManager.defaultBindings[.italic]?.key)
        XCTAssertEqual(merged[.italic]?.modifiers, ShortcutManager.defaultBindings[.italic]?.modifiers)
        XCTAssertEqual(merged[.togglePane]?.key, ShortcutManager.defaultBindings[.togglePane]?.key)
    }

    // 存储键 round-trip：storedKey/storedModifiers 写读一致；未存储返回 nil
    // Storage key round-trip: written values read back identically; nil when absent
    func testStoredKeyRoundTrip() {
        let name = "test.epic6.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        d.set("x", forKey: "shortcut.bold.key")
        d.set(NSEvent.ModifierFlags([.command, .shift]).rawValue, forKey: "shortcut.bold.modifiers")
        XCTAssertEqual(ShortcutManager.storedKey(for: .bold, defaults: d), "x")
        XCTAssertEqual(ShortcutManager.storedModifiers(for: .bold, defaults: d), [.command, .shift])
        // 未存储 → nil（区别于合法的空修饰键）
        XCTAssertNil(ShortcutManager.storedKey(for: .italic, defaults: d))
        XCTAssertNil(ShortcutManager.storedModifiers(for: .italic, defaults: d))
    }

    // ── 评审修复（T3.4-fix1，IMPORTANT×4）追加回归锁 ──
    // 空修饰键（rawValue 0）与未存储必须可区分：存 0 → storedModifiers 非 nil 且 == []；
    // 未存储 → nil；mergedBindings 中 [] 是合法覆盖（不回退默认），key 未存则回退默认
    // Empty modifiers (rawValue 0) must be distinguishable from absent: stored 0 → non-nil [] ;
    // absent → nil; mergedBindings honors [] as a real override (no fallback to default), key falls back
    func testEmptyModifiersStoredDistinctFromAbsent() {
        let name = "test.epic6.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        // 存 rawValue 0（空修饰键）→ storedModifiers 非 nil 且 == []
        d.set(NSEvent.ModifierFlags().rawValue, forKey: "shortcut.bold.modifiers")
        let stored = ShortcutManager.storedModifiers(for: .bold, defaults: d)
        XCTAssertNotNil(stored, "存 rawValue 0 必须非 nil（区别于未存储）")
        XCTAssertEqual(stored, [])
        // 未存储 → nil（区别于空修饰键）
        XCTAssertNil(ShortcutManager.storedModifiers(for: .italic, defaults: d))
        // mergedBindings：modifiers 覆盖为 []（不回退默认），key 未存 → 回退默认
        let merged = ShortcutManager.mergedBindings(defaults: d)
        XCTAssertEqual(merged[.bold]?.modifiers, [])
        XCTAssertEqual(merged[.bold]?.key, ShortcutManager.defaultBindings[.bold]?.key)
    }

    // 仅存 key 覆盖：mergedBindings key 生效、modifiers 保持默认（字段级独立合并）
    // Key-only override: merged key applies, modifiers keep defaults (field-level independent merge)
    func testMergedBindingsKeyOnlyOverride() {
        let name = "test.epic6.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        d.set("x", forKey: "shortcut.bold.key")
        let merged = ShortcutManager.mergedBindings(defaults: d)
        XCTAssertEqual(merged[.bold]?.key, "x")
        XCTAssertEqual(merged[.bold]?.modifiers, ShortcutManager.defaultBindings[.bold]?.modifiers)
    }

    // ── P1 后置（FR-065 面板补齐）：冲突检测纯函数 + 录制 round-trip ──

    // 测试 1：Cmd+S → 应用级"保存"占用
    func testConflictMessageDetectsSystemReservedSave() {
        let name = "test.p1.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        ShortcutManager.record("s", modifiers: [.command], for: .bold, defaults: d)
        XCTAssertEqual(ShortcutManager.conflictMessage(for: .bold, defaults: d),
                       "⌘S 已被「保存」占用，无法绑定", "Cmd+S 与保存冲突（已知冲突集）")
    }

    // 测试 2：defaults 覆盖与另一命令默认绑定冲突（bold → Cmd+I 撞 italic）
    func testConflictMessageDetectsOtherCommandOverride() {
        let name = "test.p1.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        ShortcutManager.record("i", modifiers: [.command], for: .bold, defaults: d)
        XCTAssertEqual(ShortcutManager.conflictMessage(for: .bold, defaults: d),
                       "⌘I 已被「斜体」占用，无法绑定", "跨命令冲突（mergedBindings 含覆盖）")
    }

    // 测试 3：无冲突键位 → nil
    func testConflictMessageNilWhenBindingFree() {
        let name = "test.p1.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        ShortcutManager.record("x", modifiers: [.command, .option], for: .bold, defaults: d)
        XCTAssertNil(ShortcutManager.conflictMessage(for: .bold, defaults: d), "⌥⌘X 空闲 → 无冲突")
    }

    // 测试 4：命令自身默认绑定（Cmd+B）→ nil（不与他人比较自身）
    func testConflictMessageNilForOwnDefaultBinding() {
        let name = "test.p1.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertNil(ShortcutManager.conflictMessage(for: .bold, defaults: d), "自身默认绑定不报冲突")
    }

    // 测试 5：Cmd+Shift+F → P1-2 折叠菜单占用（新菜单进系统保留表）
    func testConflictMessageDetectsReservedFoldShortcut() {
        let name = "test.p1.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        ShortcutManager.record("f", modifiers: [.command, .shift], for: .italic, defaults: d)
        XCTAssertEqual(ShortcutManager.conflictMessage(for: .italic, defaults: d),
                       "⇧⌘F 已被「折叠/展开当前标题」占用，无法绑定", "Cmd+Shift+F 与折叠菜单冲突")
    }

    // 测试 6：录制 round-trip——record 写入 → storedKey/storedModifiers/mergedBindings 读回
    func testRecordWritesDefaultsRoundTrip() {
        let name = "test.p1.shortcuts.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        ShortcutManager.record("x", modifiers: [.command, .shift], for: .table, defaults: d)
        XCTAssertEqual(ShortcutManager.storedKey(for: .table, defaults: d), "x", "key 读回")
        XCTAssertEqual(ShortcutManager.storedModifiers(for: .table, defaults: d), [.command, .shift],
                       "modifiers 读回（rawValue round-trip）")
        XCTAssertEqual(ShortcutManager.mergedBindings(defaults: d)[.table]?.key, "x",
                       "mergedBindings 反映录制（菜单刷新数据源）")
    }

    // 测试 7：按键归一化——有效单字符小写化；无效输入拒绝
    func testNormalizeRecordedKeySingleCharLowercased() {
        XCTAssertEqual(ShortcutManager.normalizeRecordedKey("B"), "b", "大写 → 小写")
        XCTAssertEqual(ShortcutManager.normalizeRecordedKey("1"), "1", "数字键原样")
    }

    // 测试 8：按键归一化——空/多字符/空格拒绝
    func testNormalizeRecordedKeyRejectsInvalid() {
        XCTAssertNil(ShortcutManager.normalizeRecordedKey(nil), "nil 拒绝")
        XCTAssertNil(ShortcutManager.normalizeRecordedKey(""), "空串拒绝")
        XCTAssertNil(ShortcutManager.normalizeRecordedKey("ab"), "多字符组合拒绝")
        XCTAssertNil(ShortcutManager.normalizeRecordedKey(" "), "空格拒绝（= 无快捷键）")
    }
}
