import XCTest
import AppKit
@testable import MarkdownEditor

// WindowCloseGuard：delegate 转发链（遗留 #8，批次 1）——原 delegate 拦截意图必须被尊重
//（AND 合并语义：原 false 优先；无原 delegate 时直接走 onShouldClose）
// ⚠️ 批次 3（#7）适配：Coordinator 改 state 版（无参 init + onShouldClose 属性赋值 +
// install(on:state:) 安装路径）——用例语义与断言不变，onShouldClose 为测试注入 fallback
@MainActor
final class WindowCloseGuardTests: XCTestCase {
    final class BlockingDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }
    final class PassingDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { true }
    }

    func testForwardingChainOriginalDelegatePriority() {
        // ① 原 delegate false → 拦截（即使 handler 返回 true）
        let blocking = BlockingDelegate()
        let c1 = WindowCloseGuard.Coordinator()
        c1.originalDelegate = blocking
        c1.onShouldClose = { true }
        XCTAssertFalse(c1.windowShouldClose(NSWindow()), "原 delegate false 优先拦截（#8 AND 合并）")

        // ② 原 delegate true → 继续 handler
        var handlerCalls = 0
        let passing = PassingDelegate()
        let c2 = WindowCloseGuard.Coordinator()
        c2.originalDelegate = passing
        c2.onShouldClose = { handlerCalls += 1; return true }
        XCTAssertTrue(c2.windowShouldClose(NSWindow()))
        XCTAssertEqual(handlerCalls, 1, "原 delegate true 时走 onShouldClose")

        // ③ 无原 delegate（新窗口首次安装）→ 直接 handler
        let c3 = WindowCloseGuard.Coordinator()
        c3.onShouldClose = { false }
        XCTAssertFalse(c3.windowShouldClose(NSWindow()))
    }

    // ⚠️ 修复（review，T1.5-fix 保留）：走 install(on:state:) 生产路径——幂等守卫断言
    //（重复 install 不覆盖 originalDelegate）
    func testInstallIdempotentKeepsOriginalDelegate() {
        let blocking = BlockingDelegate()
        let window = NSWindow()
        window.delegate = blocking                      // 模拟已有原 delegate
        let state = MainContentState()
        let c = WindowCloseGuard.Coordinator()
        c.onShouldClose = { true }
        c.install(on: window, state: state)             // state 版安装（#7 注册 windowRegistry）
        c.install(on: window, state: state)             // 重复 install（竞态场景）
        XCTAssertTrue(window.delegate === c, "install 后 self 为窗口 delegate")
        XCTAssertTrue(c.originalDelegate === blocking, "重复 install 不得覆盖 originalDelegate（幂等守卫）")
    }

    // 第 1 轮修复回归测试：同 state 注册到两窗口 → 旧 key 清理，allStates 去重（防 Cmd-Q 双重确认）
    // Round-1 fix regression test: same state registered to two windows → stale key cleared,
    // allStates deduplicated (prevents Cmd-Q double confirmation)
    func testRegisterDedupsSameStateAcrossWindows() {
        let windowA = NSWindow()
        let windowB = NSWindow()
        let state = MainContentState()
        MainContentState.register(state, for: windowA)
        MainContentState.register(state, for: windowB)   // 迁移：state 从 A 迁到 B / migration: state moves from A to B
        let states = MainContentState.allStates
        XCTAssertEqual(states.filter { $0 === state }.count, 1, "同 state 仅保留最新窗口映射")
        XCTAssertNil(MainContentState.state(for: windowA), "旧窗口映射已清理")
        XCTAssertTrue(MainContentState.state(for: windowB) === state, "新窗口映射保留")
    }
}
