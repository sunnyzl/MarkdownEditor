import XCTest
@testable import MarkdownEditor

// SourceMapParser：data-sourcepos 解析纯函数（T1.3，Epic-6 批次 1）
// 无 AppKit 依赖，可独立 XCTest；语义：命中块 / 块间空白定位下一块 / 文档尾部 nil / 空数组 nil
final class SourceMapParserTests: XCTestCase {
    // 1. 解析合法 attribute（如 "1:1-3:5"）→ 正确 SourcePos（1-based，与 Down 语义一致）
    func testParseValidAttribute() {
        XCTAssertEqual(SourceMapParser.parse("1:1-3:5"),
                       SourcePos(startLine: 1, startCol: 1, endLine: 3, endCol: 5))
        XCTAssertEqual(SourceMapParser.parse("10:2-12:8"),
                       SourcePos(startLine: 10, startCol: 2, endLine: 12, endCol: 8),
                       "多位数字 / 多行列也应解析")
    }

    // 2. 解析非法 attribute（空串/垃圾/残缺值）→ nil
    func testParseInvalidAttribute() {
        XCTAssertNil(SourceMapParser.parse(""))
        XCTAssertNil(SourceMapParser.parse("garbage"))
        XCTAssertNil(SourceMapParser.parse("1:1"), "缺失 end 部分")
        XCTAssertNil(SourceMapParser.parse("1:1-3"), "缺失 endCol")
        XCTAssertNil(SourceMapParser.parse("1:1-3:5:7"), "多余段")
        XCTAssertNil(SourceMapParser.parse(" 1:1-3:5"), "完整值才合法（锚定匹配）")
    }

    // 3. 多块解析 parseAll（HTML 含多个 data-sourcepos）→ 数组顺序正确（文档顺序）
    func testParseAllMultipleBlocks() {
        let html = #"<h1 data-sourcepos="1:1-1:10">Title</h1>"# +
                   #"<p data-sourcepos="3:1-5:9">para</p>"# +
                   #"<ul><li data-sourcepos="7:1-7:3">item</li></ul>"#
        XCTAssertEqual(SourceMapParser.parseAll(in: html), [
            SourcePos(startLine: 1, startCol: 1, endLine: 1, endCol: 10),
            SourcePos(startLine: 3, startCol: 1, endLine: 5, endCol: 9),
            SourcePos(startLine: 7, startCol: 1, endLine: 7, endCol: 3),
        ], "按文档出现顺序返回")
    }

    func testParseAllNoSourcepos() {
        XCTAssertEqual(SourceMapParser.parseAll(in: "<p>plain</p>"), [], "无 data-sourcepos → 空数组")
    }

    // 4. findBlock：命中（行在块内，含 startLine/endLine 边界）
    func testFindBlockHit() {
        let blocks = [
            SourcePos(startLine: 1, startCol: 1, endLine: 3, endCol: 10),
            SourcePos(startLine: 5, startCol: 1, endLine: 7, endCol: 5),
            SourcePos(startLine: 10, startCol: 1, endLine: 12, endCol: 3),
        ]
        XCTAssertEqual(SourceMapParser.findBlock(containing: 1, in: blocks), blocks[0], "startLine 边界命中")
        XCTAssertEqual(SourceMapParser.findBlock(containing: 2, in: blocks), blocks[0], "块内命中")
        XCTAssertEqual(SourceMapParser.findBlock(containing: 3, in: blocks), blocks[0], "endLine 边界命中")
        XCTAssertEqual(SourceMapParser.findBlock(containing: 6, in: blocks), blocks[1])
    }

    // 4. findBlock：空白区（行在块间 → 定位下一个块）
    func testFindBlockGap() {
        let blocks = [
            SourcePos(startLine: 1, startCol: 1, endLine: 3, endCol: 10),
            SourcePos(startLine: 5, startCol: 1, endLine: 7, endCol: 5),
            SourcePos(startLine: 10, startCol: 1, endLine: 12, endCol: 3),
        ]
        XCTAssertEqual(SourceMapParser.findBlock(containing: 4, in: blocks), blocks[1], "块间空白（4）→ 下一块（5）")
        XCTAssertEqual(SourceMapParser.findBlock(containing: 8, in: blocks), blocks[2], "块间空白（8-9）→ 下一块（10）")
        XCTAssertEqual(SourceMapParser.findBlock(containing: 0, in: blocks), blocks[0], "首个块前空白 → 第一块")
    }

    // 4. findBlock：文档尾部（行大于所有块 endLine，无下一个块 → nil）
    func testFindBlockBeyondEnd() {
        let blocks = [
            SourcePos(startLine: 1, startCol: 1, endLine: 3, endCol: 10),
            SourcePos(startLine: 5, startCol: 1, endLine: 7, endCol: 5),
        ]
        XCTAssertNil(SourceMapParser.findBlock(containing: 13, in: blocks), "超出所有块 → nil")
        XCTAssertNil(SourceMapParser.findBlock(containing: 8, in: blocks), "尾部空白 → nil")
    }

    // 4. findBlock：blocks 为空 → nil
    func testFindBlockEmptyBlocks() {
        XCTAssertNil(SourceMapParser.findBlock(containing: 3, in: []))
    }
}
