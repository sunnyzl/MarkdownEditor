import XCTest
@testable import MarkdownEditor

// MainWindowView：dynamicMinWidth 动态最小分栏宽度纯函数（round4 T1.2，用户补充需求）
// 窗口宽度比例（0.2）+ 绝对下限（160）：窗口大 → 比例主导（Mermaid 图空间充足）；
// 窗口小 → 下限兜底（不溢出）。纯函数无 View 依赖 → 无需 @MainActor
final class MainWindowViewTests: XCTestCase {
    // 窗口大：1600×0.2 = 320 > 160 → 比例主导
    func testDynamicMinWidthLargeWindowScalesWithRatio() {
        XCTAssertEqual(MainWindowView.dynamicMinWidth(windowWidth: 1600), 320,
                       "大窗口按 20% 比例缩放（Mermaid 图空间充足）")
    }

    // 窗口小：600×0.2 = 120 < 160 → 绝对下限兜底；800×0.2 = 160 边界持平
    func testDynamicMinWidthSmallWindowFallsBackToAbsoluteMin() {
        XCTAssertEqual(MainWindowView.dynamicMinWidth(windowWidth: 600), 160,
                       "小窗口收缩到绝对下限 160（不溢出）")
        XCTAssertEqual(MainWindowView.dynamicMinWidth(windowWidth: 800), 160,
                       "800×0.2=160 边界持平下限")
    }

    // ⚠️ T3.1（S-034）：wordCount 字数统计——Character 语义（split(whereSeparator:)）
    // 中文/emoji/英文混合按空白分割；emoji/中文不按字节切碎（UTF-16 安全）
    func testWordCountChineseEmojiEnglish() {
        XCTAssertEqual(MainWindowView.wordCount(""), 0, "空串 0 词")
        XCTAssertEqual(MainWindowView.wordCount("   \n\t "), 0, "纯空白 0 词")
        XCTAssertEqual(MainWindowView.wordCount("Hello"), 1, "单英文词")
        XCTAssertEqual(MainWindowView.wordCount("你好 world 👋 emoji 测试"), 5,
                       "中文/emoji/英文混合按空白分割为 5 词（Character 语义）")
    }

    // ⚠️ T3.1（S-034）：lineColumn 行列定位——前缀换行计数（0-based 行号）+ 行内 UTF-16 偏移
    // 与 selectionLineRatio/cursorLine 同构（NSString.substring(to:) UTF-16 安全，emoji/中文不漂移）
    func testLineColumnMultiLineAndLineEnd() {
        // 多行：光标在第三行行首（location 8 = "abc\ndef\n" 之后）→ (2, 0)
        let third = MainWindowView.lineColumn(text: "abc\ndef\nghi", selection: NSRange(location: 8, length: 0))
        XCTAssertEqual(third.line, 2, "前缀换行计数 → 0-based 行号 2")
        XCTAssertEqual(third.column, 0, "行首列号 0")
        // 光标行尾：第二行末尾（"abc\ndef" 全长 7）→ (1, 3)
        let lineEnd = MainWindowView.lineColumn(text: "abc\ndef", selection: NSRange(location: 7, length: 0))
        XCTAssertEqual(lineEnd.line, 1, "第二行（0-based 1）")
        XCTAssertEqual(lineEnd.column, 3, "行内 UTF-16 偏移 3")
        // 单行：恒为行 0，列 = 位置本身
        let single = MainWindowView.lineColumn(text: "one line", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(single.line, 0, "单行恒为 0")
        XCTAssertEqual(single.column, 3, "行内偏移 3")
        // UTF-16 安全（selectionLineRatio 同构回归）：emoji 前缀不漂移
        let emoji = MainWindowView.lineColumn(text: "😀a\nb", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(emoji.line, 1, "emoji 前缀 UTF-16 安全：第二行")
        XCTAssertEqual(emoji.column, 0, "emoji 前缀后第二行行首")
        // 越界（location > length）回落 (0, 0)——cursorLine 越界 nil 同构语义
        let outOfRange = MainWindowView.lineColumn(text: "a\nb", selection: NSRange(location: 99, length: 0))
        XCTAssertEqual(outOfRange.line, 0, "越界回落 0")
        XCTAssertEqual(outOfRange.column, 0, "越界回落 0")
    }

    // ⚠️ T3.1（S-034）：isFocusMode 聚焦模式隐藏状态栏——聚焦与分栏正交（不新增 paneMode 枚举）
    func testStatusBarHiddenInFocusMode() {
        XCTAssertFalse(MainWindowView.statusBarVisible(isFocusMode: true, showStatusBar: true),
                       "聚焦模式隐藏状态栏（即使开关开启）")
        XCTAssertTrue(MainWindowView.statusBarVisible(isFocusMode: false, showStatusBar: true),
                       "非聚焦模式显示状态栏")
    }

    // ⚠️ T3.1（FR-087）：showStatusBar 开关——关闭隐藏状态栏
    func testShowStatusBarToggle() {
        XCTAssertTrue(MainWindowView.statusBarVisible(isFocusMode: false, showStatusBar: true),
                      "开关开启 → 显示状态栏")
        XCTAssertFalse(MainWindowView.statusBarVisible(isFocusMode: false, showStatusBar: false),
                       "开关关闭 → 隐藏状态栏")
    }

    // ⚠️ T3.2（S-034/FR-087）：statusText 状态栏文本组装——字数（Character 语义）+
    // 字符数 + 行列（0-based 行号/列号 → 1-based 显示）
    func testStatusTextAssemblesMetrics() {
        // 多行：光标在第二行行首（location 4 = "abc\n" 之后）→ 2 词 / 7 字符 / 行 2 列 1
        let multi = MainWindowView.statusText(text: "abc\ndef", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(multi, "2 词 · 7 字符 · 行 2, 列 1", "字数/字符/行列组装（1-based 行列）")
        // 空文本：0 词 / 0 字符 / 行 1 列 1（越界回落 (0,0) → 1-based 起点）
        let empty = MainWindowView.statusText(text: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(empty, "0 词 · 0 字符 · 行 1, 列 1", "空文本回落起点")
    }
}
