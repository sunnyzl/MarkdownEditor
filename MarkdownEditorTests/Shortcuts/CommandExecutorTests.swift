import XCTest
import AppKit
@testable import MarkdownEditor

// CommandExecutor（S-020）：文本命令 → textView.performFormatting；布局命令 → 闭包；
// weak 持有（textView 释放不崩溃）
@MainActor
final class CommandExecutorTests: XCTestCase {
    func testTextCommandDispatchesToTextView() {
        let executor = CommandExecutor()
        let tv = MarkdownTextView()
        tv.string = "hello world"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        executor.textView = tv
        executor.execute(.bold)
        XCTAssertEqual(tv.string, "**hello** world")
    }

    func testTogglePaneRoutesToClosure() {
        let executor = CommandExecutor()
        var calls = 0
        executor.onTogglePane = { calls += 1 }
        executor.execute(.togglePane)
        XCTAssertEqual(calls, 1)
    }

    func testTogglePaneDoesNotTouchTextView() {
        let executor = CommandExecutor()
        let tv = MarkdownTextView()
        tv.string = "hello"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        executor.textView = tv
        executor.execute(.togglePane)
        XCTAssertEqual(tv.string, "hello", "布局命令不得修改文本")
    }

    func testTextViewWeaklyHeld() {
        let executor = CommandExecutor()
        var tv: MarkdownTextView? = MarkdownTextView()
        tv?.string = "hello"
        executor.textView = tv
        tv = nil
        executor.execute(.bold)   // weak 已释放 → 静默 no-op，不崩溃
    }

    func testExecuteWithoutTextViewNoCrash() {
        let executor = CommandExecutor()
        executor.execute(.italic)   // textView nil → 静默
        executor.execute(.togglePane)   // 无闭包 → 静默
    }
}
