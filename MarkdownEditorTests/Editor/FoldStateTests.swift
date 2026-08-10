import XCTest
@testable import MarkdownEditor

// FoldStateTests.swift — Editor 测试：会话级折叠区间管理 + 标题级别纯函数（Epic-6 批次 2，T2.1）
// 实例状态方法（toggle/isFolded）为 @MainActor 隔离；静态纯函数 nonisolated，可直接单测（NFR-032）。
final class FoldStateTests: XCTestCase {

    // T2.1-1 toggle 幂等：toggle 两次恢复原状
    @MainActor
    func testToggleIsIdempotent() {
        let state = FoldState()
        XCTAssertFalse(state.isFolded(at: 3))
        state.toggle(line: 3)
        XCTAssertTrue(state.isFolded(at: 3))
        state.toggle(line: 3)
        XCTAssertFalse(state.isFolded(at: 3))
        XCTAssertTrue(state.folded.isEmpty, "toggle 两次后区间列表应恢复为空")
    }

    // T2.1-2 标题级别解析：H1~H6 返回级别，非标题返回 nil
    // 语义对齐 TextFormatting.setHeading：行首空白后 #{1,6}，且后随空格或行尾
    func testHeadingLevelParsesH1ThroughH6() {
        XCTAssertEqual(FoldState.headingLevel(of: "# Title"), 1)
        XCTAssertEqual(FoldState.headingLevel(of: "## Title"), 2)
        XCTAssertEqual(FoldState.headingLevel(of: "### Title"), 3)
        XCTAssertEqual(FoldState.headingLevel(of: "#### Title"), 4)
        XCTAssertEqual(FoldState.headingLevel(of: "##### Title"), 5)
        XCTAssertEqual(FoldState.headingLevel(of: "###### Title"), 6)
        XCTAssertEqual(FoldState.headingLevel(of: "##"), 2, "行尾无空格也视为标题（setHeading 语义）")
        XCTAssertEqual(FoldState.headingLevel(of: "  ### Indented"), 3, "保留行首缩进（setHeading 语义）")
    }

    func testHeadingLevelReturnsNilForNonHeading() {
        XCTAssertNil(FoldState.headingLevel(of: "Plain text"))
        XCTAssertNil(FoldState.headingLevel(of: "###NoSpace"), "无空格分隔不是标题")
        XCTAssertNil(FoldState.headingLevel(of: "####### Too Deep"), "7 个 # 超出 H6")
        XCTAssertNil(FoldState.headingLevel(of: ""))
        XCTAssertNil(FoldState.headingLevel(of: "#x"))
    }

    // T2.1-3 H2 折叠区间计算：嵌套 H3 区间正确终止于下一个同级或更高级标题
    func testFoldingRangeForH2WithNestedH3() {
        let lines = [
            "# Doc",           // line 0：H1 不参与章节折叠
            "## Section A",    // line 1：H2
            "intro text",      // line 2
            "### Sub A",       // line 3：H3（嵌套）
            "sub content",     // line 4
            "## Section B",    // line 5：下一个 H2 → H2 折叠终止
            "more text",       // line 6
        ]
        XCTAssertEqual(FoldState.foldingRange(for: 1, in: lines),
                       FoldRange(startLine: 1, endLine: 4), "H2 折叠到下一个同级/更高级标题前")
        XCTAssertEqual(FoldState.foldingRange(for: 3, in: lines),
                       FoldRange(startLine: 3, endLine: 4), "嵌套 H3 折叠到下一个同级/更高级标题前")
        XCTAssertNil(FoldState.foldingRange(for: 0, in: lines), "H1 不参与章节折叠（仅 H2/H3）")
    }

    func testFoldingRangeForHeadingAtEndOfDocument() {
        let lines = [
            "## Solo Heading", // line 0：无后续内容 → 单行无可折叠
        ]
        XCTAssertNil(FoldState.foldingRange(for: 0, in: lines), "标题为末行且无内容 → nil")
    }

    // T2.1-4 代码块围栏区间：开围栏 → 闭合围栏（闭区间）
    func testFoldingRangeForCodeFence() {
        let lines = [
            "## Code",       // line 0
            "```swift",      // line 1：开围栏
            "let x = 1",     // line 2
            "```",           // line 3：闭合围栏
            "text after",    // line 4
        ]
        XCTAssertEqual(FoldState.foldingRange(for: 1, in: lines),
                       FoldRange(startLine: 1, endLine: 3), "围栏闭区间覆盖整个代码块")
    }

    func testFoldingRangeForUnclosedFence() {
        let lines = [
            "```",           // line 0：开围栏
            "unclosed",      // line 1
        ]
        XCTAssertNil(FoldState.foldingRange(for: 0, in: lines), "未闭合围栏不可折叠")
    }

    // T2.1-5 区间排序合并：按 startLine 升序，重叠区间合并
    func testFoldedRangesSortedAndMerged() {
        let input = [
            FoldRange(startLine: 5, endLine: 8),
            FoldRange(startLine: 1, endLine: 3),
            FoldRange(startLine: 3, endLine: 4),   // 与 {1,3} 在 line 3 重叠
        ]
        XCTAssertEqual(FoldState.foldedRanges(in: input), [
            FoldRange(startLine: 1, endLine: 4),
            FoldRange(startLine: 5, endLine: 8),
        ])
    }

    func testFoldedRangesKeepsDisjointRangesSeparate() {
        let disjoint = [
            FoldRange(startLine: 10, endLine: 12),
            FoldRange(startLine: 1, endLine: 2),
        ]
        XCTAssertEqual(FoldState.foldedRanges(in: disjoint), [
            FoldRange(startLine: 1, endLine: 2),
            FoldRange(startLine: 10, endLine: 12),
        ], "不相交区间保持独立，仅按 startLine 排序")
    }

    // T2.1-6 围栏内 ```swift 行不提前闭合：闭合扫描校验闭标记合法性（后随 info string 不是闭合围栏）
    func testFoldingRangeIgnoresInfoFenceLikeLineInsideFence() {
        let lines = [
            "## Code",         // line 0
            "```swift",        // line 1：开围栏（带 info string）
            "let x = 1",       // line 2
            "```swift",        // line 3：代码块内容中以 ``` 开头的行（带 info string，非法闭合）
            "let y = 2",       // line 4
            "```",             // line 5：真正的闭合围栏
            "text after",      // line 6
        ]
        XCTAssertEqual(FoldState.foldingRange(for: 1, in: lines),
                       FoldRange(startLine: 1, endLine: 5), "```swift 行不是合法闭合围栏，围栏应延续到真正的 ```")
    }

    // T2.1-7 围栏内嵌标题样式行不终止章节折叠：前向扫描维护围栏状态，跳过围栏内的假标题
    func testFoldingRangeIgnoresHeadingInsideFence() {
        let lines = [
            "## Section",       // line 0：H2
            "intro",            // line 1
            "```swift",         // line 2：开围栏
            "## fake heading",  // line 3：围栏内标题样式行（不应终止折叠）
            "let x = 1",        // line 4
            "```",              // line 5：闭合围栏
            "## Next Section",  // line 6：真实 H2 → 折叠终止
        ]
        XCTAssertEqual(FoldState.foldingRange(for: 0, in: lines),
                       FoldRange(startLine: 0, endLine: 5), "围栏内的 ## 行不是真实标题，H2 折叠应延伸到真实 H2 前")
    }

    // T2.1-8 4 反引号开围栏不被 3 反引号行闭合：闭合围栏反引号数必须 ≥ 开围栏反引号数
    func testFoldingRangeRequiresClosingFenceAtLeastAsLong() {
        let lines = [
            "````",            // line 0：4 反引号开围栏
            "code line",       // line 1
            "```",             // line 2：3 反引号行（不应闭合 4 反引号围栏）
            "more code",       // line 3
            "````",            // line 4：4 反引号闭合围栏
            "## Next",         // line 5
        ]
        XCTAssertEqual(FoldState.foldingRange(for: 0, in: lines),
                       FoldRange(startLine: 0, endLine: 4), "3 反引号行不能闭合 4 反引号围栏")
    }
}
