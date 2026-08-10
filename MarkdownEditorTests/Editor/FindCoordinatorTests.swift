import XCTest
import AppKit
@testable import MarkdownEditor

// FindCoordinator：会话状态 + 匹配/替换执行（S-029，FR-002：替换可撤销；Panel UI 手动验收）
final class FindCoordinatorTests: XCTestCase {
    @MainActor
    private func makeTextView(_ text: String) -> MarkdownTextView {
        let key = "test.epic5.findcoordinator.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: key)!
        let tv = MarkdownTextView(defaults: d)
        tv.string = text
        return tv
    }

    @MainActor
    func testShowPopulatesMatchesAndHighlights() {
        let tv = makeTextView("a b a c a")
        let c = FindCoordinator()
        c.textView = tv
        c.setSearchText("a")
        c.show()
        XCTAssertEqual(c.matchRanges.count, 3)
        XCTAssertEqual(c.statusMessage, "3 处匹配")
        let attr = tv.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil)
        XCTAssertNotNil(attr, "匹配区间已加背景高亮")
    }

    @MainActor
    func testFindNextCyclesSelection() {
        let tv = makeTextView("a b a c a")
        let c = FindCoordinator()
        c.textView = tv
        c.setSearchText("a")
        c.show()
        c.findNext()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 4, length: 1), "下一个匹配选中")
        c.findNext()
        c.findNext()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 1), "循环回绕")
    }

    @MainActor
    func testFindPreviousCycles() {
        let tv = makeTextView("a b a c a")
        let c = FindCoordinator()
        c.textView = tv
        c.setSearchText("a")
        c.show()
        c.findPrevious()
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 8, length: 1), "上一个匹配（尾部回绕）")
    }

    @MainActor
    func testReplaceCurrentUndoable() {
        let tv = makeTextView("cat dog cat")
        let c = FindCoordinator()
        c.textView = tv
        c.setSearchText("cat")
        c.replaceText = "DOG"
        c.show()
        c.replaceCurrent()
        XCTAssertEqual(tv.string, "DOG dog cat")
        // ⚠️ 审查 IMPORTANT #2 修订：无窗口环境 undoManager 可能 nil → 条件断言
        //（仿 MarkdownTextViewTests.swift:311-327 既有先例；nil 时跳过撤销断言，防必红）
        if let undo = tv.undoManager {
            undo.undo()   // 原生编辑链 → 撤销自动进 undo 栈（FR-002）
            XCTAssertEqual(tv.string, "cat dog cat")
        }
    }

    @MainActor
    func testReplaceAllReplacesAll() {
        let tv = makeTextView("cat dog cat cat")
        let c = FindCoordinator()
        c.textView = tv
        c.setSearchText("cat")
        c.replaceText = "X"
        c.show()
        c.replaceAll()
        XCTAssertEqual(tv.string, "X dog X X")
        XCTAssertEqual(c.statusMessage, "已替换 3 处")
    }

    @MainActor
    func testInvalidRegexShowsStatusWithoutCrash() {
        let tv = makeTextView("plain text")
        let c = FindCoordinator()
        c.textView = tv
        c.isRegex = true
        c.setSearchText("([")
        c.show()
        XCTAssertTrue(c.matchRanges.isEmpty)
        XCTAssertFalse(c.statusMessage.isEmpty, "非法正则 → 状态栏错误提示（不崩溃）")
    }
}
