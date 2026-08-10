import XCTest
@testable import MarkdownEditor

// IMEHandling：compose 状态机（S-008 AC：compose 暂停 / 上屏恢复 / 幂等）
@MainActor
final class IMEHandlingTests: XCTestCase {
    func testStateTransitionsFireCallbacks() {
        let ime = IMEHandling()
        var events: [Bool] = []
        ime.onComposeStateChange = { events.append($0) }

        ime.setComposing(true)     // 开始拼音 compose → 暂停
        ime.setComposing(true)     // 重复 → 幂等，不触发
        ime.setComposing(false)    // 上屏 → 恢复
        XCTAssertEqual(events, [true, false])
        XCTAssertFalse(ime.isComposing)
    }

    func testAttachToTextView() {
        let tv = MarkdownTextView()
        let ime = IMEHandling()
        var paused = false
        ime.onComposeStateChange = { paused = $0 }
        ime.attach(to: tv)

        // 模拟：文本变化且 markedText 存在（compose 中）
        tv.onComposeStateChange?(true)
        XCTAssertTrue(ime.isComposing)
        XCTAssertTrue(paused)
    }
}

// ⚠️ 修复 D：MarkdownTextView IME 检测接线级用例（批次 4 头部声明交付，此前缺失）
// ⚠️ 修复 #5（第 4 轮）+ F6（第 8 轮）+ 第 9 轮：原 testComposeCallbackIsWired 为自证型断言
// （调用闭包后断言被调用，未验证接线）→ 删除；真实接线由 testAttachToTextView（上方）覆盖
//（IMEHandling.attach(to:) → tv.onComposeStateChange 转发链）。此块保留为空注释说明。
