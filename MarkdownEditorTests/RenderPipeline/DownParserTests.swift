import XCTest
@testable import MarkdownEditor

// DownParser：基础语法输出结构断言（S-010 AC-2；GFM 用例在批次 4 S-011 追加）
final class DownParserTests: XCTestCase {
    private let parser = DownParser()

    func testHeadingAndParagraph() throws {
        // ⚠️ T1.1（sourcePos）：块级标签带 data-sourcepos 属性，断言同步适配（strong 为 inline 无属性）
        let html = try parser.render(markdown: "# Title\n\nHello **world**")
        XCTAssertTrue(html.contains(#"<h1 data-sourcepos="#), "h1 块级标签带 data-sourcepos")
        XCTAssertTrue(html.contains(">Title</h1>"))
        XCTAssertTrue(html.contains("<strong>world</strong>"))
    }

    func testCodeBlockOutputFormat() throws {
        // POC S-004 确认的隐式契约：<pre><code class="language-X">（MermaidPreprocessor 依赖）
        // ⚠️ T1.1（sourcePos）：pre 块级标签带 data-sourcepos 属性（code 为 pre 内 inline，无属性）
        let html = try parser.render(markdown: "```mermaid\ngraph TD; A-->B\n```")
        XCTAssertTrue(html.contains(#"<pre data-sourcepos="#),
                      "pre 块级标签带 data-sourcepos（阶段 3 正则宽容化后匹配）")
        XCTAssertTrue(html.contains(#"<code class="language-mermaid">"#),
                      "code class 保持——阶段 3 正则依赖的输出格式必须保持")
    }

    func testUnsafeRawHTMLIsStrippedByDefault() throws {
        let html = try parser.render(markdown: "<script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>"), "默认 safe 模式移除 raw HTML")
    }

    func testListAndQuote() throws {
        // ⚠️ T1.1（sourcePos）：li/blockquote 块级标签带 data-sourcepos 属性，断言同步适配
        let html = try parser.render(markdown: "- a\n- b\n\n> quote")
        XCTAssertTrue(html.contains(#"<li data-sourcepos="#), "li 块级标签带 data-sourcepos")
        XCTAssertTrue(html.contains(#"<blockquote data-sourcepos="#), "blockquote 块级标签带 data-sourcepos")
    }

    // ── S-011 GFM 用例（FR-021~024；以后处理输出为准——fork 无 GFM 扩展，第 9 轮源码验证）──

    func testGfmTable() throws {
        // ⚠️ 遗留 #6（批次 1）对齐：原输入 `| :- | -: |`（2 连字符分隔 cell）落入收紧规则
        // （≥3 连字符，-{3,}）之外 → 改用规范 3 连字符对齐标记形态，保留原对齐意图
        let md = "| a | b |\n| :--- | ---: |\n| 1 | 2 |"
        let html = try parser.render(markdown: md)
        XCTAssertTrue(html.contains("<table>"), "FR-022 表格必须渲染（GfmPostProcessor 后处理）")
    }

    func testGfmTaskList() throws {
        let md = "- [ ] todo\n- [x] done"
        let html = try parser.render(markdown: md)
        XCTAssertTrue(html.contains("checkbox"), "FR-023 任务列表复选框（input[type=checkbox]）")
    }

    func testGfmStrikethrough() throws {
        let md = "~~gone~~"
        let html = try parser.render(markdown: md)
        XCTAssertTrue(html.contains("<del>"), "FR-024 删除线（GFM strikethrough 扩展）")
    }

    func testGfmBasicsStillRender() throws {
        // FR-021 基础语法回归（批次 3 用例已覆盖 heading/strong/list；此处补引用/图片/分隔线）
        let md = "[link](https://x.com)\n\n---\n\n![alt](img.png)"
        let html = try parser.render(markdown: md)
        XCTAssertTrue(html.contains("<a href=\"https://x.com\">"))
        XCTAssertTrue(html.contains("<hr"))
        XCTAssertTrue(html.contains("<img src=\"img.png\""))
    }

    // ── T1.1 sourcePos 启用（Epic-6 批次 1；POC S-004 §1：sourcepos 使块级标签带 data-sourcepos 属性）──

    func testHTMLIncludesSourcePos() throws {
        // POC S-004 证据：sourcepos 选项使块级标签带 data-sourcepos 属性，格式 "1:1-1:1"
        let html = try parser.render(markdown: "# H1\n\ntext")
        XCTAssertTrue(html.contains("data-sourcepos=\"1:1-"), "h1 块级标签应带 data-sourcepos 属性")
    }

    func testSourcePosFormat() throws {
        // POC S-004 证据：data-sourcepos 值必须匹配 行:列-行:列 格式（如 "1:1-1:1"）
        let html = try parser.render(markdown: "# H1\n\ntext")
        let pattern = #"data-sourcepos="(\d+):(\d+)-(\d+):(\d+)""#
        XCTAssertNotNil(html.range(of: pattern, options: .regularExpression),
                        "data-sourcepos 值必须匹配 行:列-行:列 格式")
    }
}
