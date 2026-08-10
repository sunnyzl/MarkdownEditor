import XCTest
@testable import MarkdownEditor

// ThemeCycle：主题循环跳过无效状态（第八轮修复；PaneMode 风格纯函数测试）
// 核心：system 在 dark 系统下 = dark → 从 dark 切 system 无视觉变化 → 跳过；
// 每次点击必有视觉变化（light/dark effective 恒异 → 循环必然终止）
// Pure-function tests like PaneModeTests; @MainActor required because
// MainContentState.nextThemeIndex is actor-isolated (same precedent as ThemeServiceTests)
@MainActor
final class ThemeCycleTests: XCTestCase {
    // 模拟一次点击：nextThemeIndex 前进 + select 后 effective 重算
    // Simulate one click: advance via nextThemeIndex, then recompute effective after selection
    private func click(_ index: Int, _ effective: ThemeMode, systemIs: ThemeMode) -> (index: Int, effective: ThemeMode) {
        let modes: [ThemeMode] = [.light, .dark, .system]
        let next = MainContentState.nextThemeIndex(currentIndex: index,
                                                   currentEffective: effective,
                                                   resolveSystem: { _ in systemIs })
        let selected = modes[next]
        return (next, selected == .system ? systemIs : selected)
    }

    func testCycleSkipsSameEffectiveEveryClickChanges() {
        // ── 场景 1：dark 系统（system 解析为 dark）——连点 6 次，每次 effective 必变 ──
        var index = 1                       // 初始 dark（与 MainContentState.init 对齐：themeIndex 取 mode 索引）
        var effective: ThemeMode = .dark
        var actual: [ThemeMode] = []
        for _ in 0..<6 {
            (index, effective) = click(index, effective, systemIs: .dark)
            actual.append(effective)
        }
        // dark 系统：system(=dark) 恒被跳过 → light ↔ dark 交替 → 每次点击都有视觉变化
        XCTAssertEqual(actual, [.light, .dark, .light, .dark, .light, .dark],
                       "dark 系统下 system 被跳过，序列 dark→light→dark→… 每次点击视觉必变")

        // ── 场景 2：light 系统（system 解析为 light）——system 可选到 ──
        // 从 dark 出发：candidate=system 的 effective=light ≠ dark → 直接命中 system
        let r1 = click(1, .dark, systemIs: .light)
        XCTAssertEqual(r1.index, 2, "light 系统下从 dark 可切到 system（解析后 light ≠ dark）")
        XCTAssertEqual(r1.effective, .light)
        // 从 system(=light) 出发：candidate=light 的 effective=light == light → 跳过 → dark
        let r2 = click(2, .light, systemIs: .light)
        XCTAssertEqual(r2.index, 1, "light 系统下 system 再切：light 与当前相同被跳过 → dark")
        XCTAssertEqual(r2.effective, .dark)

        // ── 场景 3：终止性保护（死循环边界）——三态中 light/dark 恒异 → 必返回有效索引 ──
        for start in 0..<3 {
            for current in [ThemeMode.light, .dark] {
                let result = click(start, current, systemIs: .dark)
                XCTAssertTrue((0..<3).contains(result.index),
                              "start=\(start) current=\(current) 必在 ≤3 步内返回（无死循环）")
            }
        }
    }
}
