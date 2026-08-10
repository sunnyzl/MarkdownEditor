import XCTest
@testable import MarkdownEditor

// TextFormatting 纯函数（S-021/S-022）：AC-FR-051~057 逐一断言 + P1 扩展（FR-058~064）
final class TextFormattingTests: XCTestCase {
    func assertText(_ r: TextFormatting.Result?, equals expected: String, sel: NSRange,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r?.text, expected, file: file, line: line)
        XCTAssertEqual(r?.selection, sel, file: file, line: line)
    }

    // FR-051 粗体
    func testBoldWrapsSelection() {
        // "**hello**" UTF-16 长度 = 2+5+2 = 9（wrap 语义：选中整个包裹结果含标记）
        assertText(TextFormatting.format("hello world", range: NSRange(location: 0, length: 5), command: .bold),
                   equals: "**hello** world", sel: NSRange(location: 0, length: 9))
    }
    func testBoldAtCaretInsertsPlaceholder() {
        assertText(TextFormatting.format("abc", range: NSRange(location: 1, length: 0), command: .bold),
                   equals: "a**粗体文本**bc", sel: NSRange(location: 7, length: 0))
    }
    func testBoldUnwrapsExistingMarkers() {
        assertText(TextFormatting.format("**hello**", range: NSRange(location: 0, length: 9), command: .bold),
                   equals: "hello", sel: NSRange(location: 0, length: 5))
    }
    // FR-052 斜体
    func testItalicWrapsSelection() {
        assertText(TextFormatting.format("hello", range: NSRange(location: 0, length: 5), command: .italic),
                   equals: "*hello*", sel: NSRange(location: 0, length: 7))
    }
    // FR-053 行内代码
    func testInlineCodeWrapsSelection() {
        assertText(TextFormatting.format("let x", range: NSRange(location: 0, length: 5), command: .inlineCode),
                   equals: "`let x`", sel: NSRange(location: 0, length: 7))
    }
    // FR-054 代码块
    func testCodeBlockWrapsSelection() {
        assertText(TextFormatting.format("code", range: NSRange(location: 0, length: 4), command: .codeBlock),
                   equals: "```\ncode\n```", sel: NSRange(location: 0, length: 12))
    }
    // FR-055 链接（"[hello](url)" utf16 长度 = 12，包裹后选区长度 = 12）
    func testLinkWrapsSelection() {
        assertText(TextFormatting.format("hello", range: NSRange(location: 0, length: 5), command: .link),
                   equals: "[hello](url)", sel: NSRange(location: 0, length: 12))
    }
    // FR-056 图片
    func testImageWrapsSelection() {
        assertText(TextFormatting.format("pic", range: NSRange(location: 0, length: 3), command: .image),
                   equals: "![pic](url)", sel: NSRange(location: 0, length: 11))
    }
    // FR-057 标题 H1~H6
    func testHeadingInsertAtCaretLine() {
        assertText(TextFormatting.format("title", range: NSRange(location: 2, length: 0), command: .heading1),
                   equals: "# title", sel: NSRange(location: 2, length: 0))
    }
    func testHeadingToggleRemovesSameLevel() {
        assertText(TextFormatting.format("# title", range: NSRange(location: 3, length: 0), command: .heading1),
                   equals: "title", sel: NSRange(location: 0, length: 0))
    }
    func testHeadingAdjustsDifferentLevel() {
        assertText(TextFormatting.format("## title", range: NSRange(location: 3, length: 0), command: .heading1),
                   equals: "# title", sel: NSRange(location: 2, length: 0))
    }
    // 光标 offset = contentStart(2) + headingPrefix("### " 4 字符) = 6
    func testHeadingKeepsLeadingIndent() {
        assertText(TextFormatting.format("  title", range: NSRange(location: 3, length: 0), command: .heading3),
                   equals: "  ### title", sel: NSRange(location: 6, length: 0))
    }
    func testHeadingSixLevels() {
        assertText(TextFormatting.format("t", range: NSRange(location: 0, length: 0), command: .heading6),
                   equals: "###### t", sel: NSRange(location: 7, length: 0))
    }
    // FR-058 表格
    func testTableInsertAtCaret() {
        let expected = "a| 列 1 | 列 2 | 列 3 |\n| --- | --- | --- |\n|  |  |  |b"
        assertText(TextFormatting.format("ab", range: NSRange(location: 1, length: 0), command: .table),
                   equals: expected, sel: NSRange(location: 3, length: 0))
    }
    // FR-059 任务列表
    func testTaskListInsertAtCaretLine() {
        assertText(TextFormatting.format("buy milk", range: NSRange(location: 0, length: 0), command: .taskList),
                   equals: "- [ ] buy milk", sel: NSRange(location: 6, length: 0))
    }
    func testTaskListToggleRemoves() {
        assertText(TextFormatting.format("- [ ] buy milk", range: NSRange(location: 0, length: 0), command: .taskList),
                   equals: "buy milk", sel: NSRange(location: 0, length: 0))
    }
    // FR-060 公式
    func testMathInlineWrap() {
        assertText(TextFormatting.format("e=mc^2", range: NSRange(location: 0, length: 6), command: .mathInline),
                   equals: "$e=mc^2$", sel: NSRange(location: 0, length: 8))
    }
    func testMathBlockWrap() {
        assertText(TextFormatting.format("E=mc^2", range: NSRange(location: 0, length: 6), command: .mathBlock),
                   equals: "$$\nE=mc^2\n$$", sel: NSRange(location: 0, length: 12))
    }
    // FR-063 引用
    func testBlockquoteInsertAtCaretLine() {
        assertText(TextFormatting.format("quote", range: NSRange(location: 2, length: 0), command: .blockquote),
                   equals: "> quote", sel: NSRange(location: 4, length: 0))
    }
    func testBlockquoteToggleRemoves() {
        assertText(TextFormatting.format("> quote", range: NSRange(location: 2, length: 0), command: .blockquote),
                   equals: "quote", sel: NSRange(location: 0, length: 0))
    }
    func testBlockquoteMultiLine() {
        assertText(TextFormatting.format("a\nb", range: NSRange(location: 0, length: 3), command: .blockquote),
                   equals: "> a\n> b", sel: NSRange(location: 0, length: 7))
    }
    // FR-064 删除线（Cmd+Opt+S，设计决策 #1）
    func testStrikethroughWrapsSelection() {
        assertText(TextFormatting.format("text", range: NSRange(location: 0, length: 4), command: .strikethrough),
                   equals: "~~text~~", sel: NSRange(location: 0, length: 8))
    }
    // 命令映射完整性
    func testFormatTogglePaneReturnsNil() {
        XCTAssertNil(TextFormatting.format("x", range: NSRange(location: 0, length: 0), command: .togglePane))
    }
    func testFormatMapsAllTextCommands() {
        for command in EditorCommand.allCases where command != .togglePane {
            XCTAssertNotNil(TextFormatting.format("sample text",
                                                  range: NSRange(location: 0, length: 5), command: command),
                            "\(command.rawValue) 必须产生文本变换结果")
        }
    }
    // 边界：越界 range 钳制——location 钳到 2（文末）、length 钳到 0 → 空选区分支：
    // 在文末插入 "**粗体文本**"，光标 = 2 + 2 + 4 = 8
    func testRangeClampedToTextBounds() {
        assertText(TextFormatting.format("ab", range: NSRange(location: 99, length: 99), command: .bold),
                   equals: "ab**粗体文本**", sel: NSRange(location: 8, length: 0))
    }
    // FR-056（收尾批次）追加：imageMarkdown 纯函数——alt 文件名去扩展名 + 路径转义
    func testImageMarkdownBuildsSyntax() {
        XCTAssertEqual(TextFormatting.imageMarkdown(path: "/Users/x/photo.png"),
                       "![photo](/Users/x/photo.png)", "基础路径：alt=文件名去扩展名，路径原样")
    }
    func testImageMarkdownEscapesPath() {
        XCTAssertEqual(TextFormatting.imageMarkdown(path: "/Users/x/my photo (1).png"),
                       "![my photo (1)](/Users/x/my%20photo%20%281%29.png)",
                       "空格/括号百分号编码（URL 安全，Down 渲染解码还原）")
    }
    func testImageMarkdownAltDropsDirectoryAndExtension() {
        XCTAssertEqual(TextFormatting.imageMarkdown(path: "/a/b/c.tar.gz"),
                       "![c.tar](/a/b/c.tar.gz)", "目录剥离 + 仅去末扩展名")
    }
    // blind review #1：% 转义顺序（% 先行）是函数最易错不变量，须显式锁定
    func testImageMarkdownEscapesPercent() {
        XCTAssertEqual(TextFormatting.imageMarkdown(path: "/x/100%.png"),
                       "![100%](/x/100%25.png)", "% 先行转义（防 %20 等二次编码为 %2520）")
    }
}
