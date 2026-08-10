import XCTest
@testable import MarkdownEditor

// GfmPostProcessor：三项 GFM 后处理（S-011 AC；FR-021~024 渲染断言）
final class GfmPostProcessorTests: XCTestCase {
    func testTaskListConversion() {
        let p = GfmPostProcessor()
        let out = p.processTaskLists("<li>[ ] todo</li><li>[x] done</li>")
        XCTAssertTrue(out.contains("task-list-item"))
        XCTAssertTrue(out.contains("type=\"checkbox\""))
    }

    func testStrikethroughConversion() {
        let p = GfmPostProcessor()
        let out = p.processStrikethrough("~~deleted~~ stays")
        XCTAssertTrue(out.contains("<del>deleted</del>"))
    }

    func testTableConversion() {
        let p = GfmPostProcessor()
        // ⚠️ 第 11 轮：改真实 CommonMark 输出格式（无空行连续行 → 单段含软换行 \n）
        let out = p.processTables("<p>| A | B |\n| --- | --- |\n| 1 | 2 |</p>")
        XCTAssertTrue(out.contains("<table"), "常见表格形态应转 table（脆弱项，验收以常见用例为准）")
        XCTAssertTrue(out.contains("<th>"), "表头 th")
    }

    func testTableMultiParagraph() {
        let p = GfmPostProcessor()
        // 多段落表格（表格间有空行的形态）
        let out = p.processTables("<p>| A | B |</p><p>|---|---|</p><p>| 1 | 2 |</p>")
        XCTAssertTrue(out.contains("<table"))
    }

    func testPlainHtmlUnchanged() {
        let p = GfmPostProcessor()
        XCTAssertEqual(p.process("<p>plain</p>"), "<p>plain</p>")
    }

    func testTableMultipleTables() {
        let p = GfmPostProcessor()
        let out = p.processTables("<p>| A | B |</p><p>|---|---|</p><p>| 1 | 2 |</p><p>plain</p><p>| C |</p><p>|---|</p><p>| 3 |</p>")
        XCTAssertEqual(out.components(separatedBy: "<table>").count - 1, 2, "两个表格都应转 table")
    }

    func testTaskListCheckedState() {
        let p = GfmPostProcessor()
        let out = p.processTaskLists("<li>[ ] todo</li><li>[x] done</li>")
        XCTAssertTrue(out.contains("checked"), "FR-023 [x] 应渲染为已勾选")
        XCTAssertTrue(out.contains("<li class=\"task-list-item\"><input type=\"checkbox\" disabled> "), "[ ] 保持未勾选")
    }

    func testNoSeparatorRowUnchanged() {
        let p = GfmPostProcessor()
        let html = "<p>| a | b |\n| c | d |</p>"
        XCTAssertEqual(p.processTables(html), html)
    }

    // ⚠️ 遗留 #6（批次 1）追加（5 用例）：表格边界收紧

    func testCodeBlockPipesUntouched() {
        let p = GfmPostProcessor()
        // 代码块 HTML 为 <pre><code>（不含 <p>），pattern (<p>\|...\|</p>) 天然避开
        let html = "<pre><code>| a | b |\n| --- | --- |</code></pre>"
        XCTAssertEqual(p.processTables(html), html, "代码块内管道行不得转表")
    }

    func testAlignmentMarkerSeparatorConverts() {
        let p = GfmPostProcessor()
        // 对齐标记（:---: / ---: / :---）分隔行 → 判定正则兼容 → 正常转表；
        // 对齐冒号不泄漏到输出（分隔行不参与输出，MVP 不输出 align 属性）
        let out = p.processTables("<p>| A | B |\n| :---: | ---: |\n| 1 | 2 |</p>")
        XCTAssertTrue(out.contains("<table>"), "对齐标记分隔行应转 table")
        XCTAssertTrue(out.contains("<th>A</th>"))
        XCTAssertFalse(out.contains(":---"), "对齐标记已剥离（不输出）")
    }

    // ⚠️ 改写（round4 T1.3，根因 4）：列数不齐行为变更——跳过 → 补齐空 cell 至表头列数。
    // 修复前：body 行 cell 数（1）!= 表头（2）→ 整行丢弃；修复后：补空 cell 输出对齐行
    func testColumnMismatchPadsRow() {
        let p = GfmPostProcessor()
        let out = p.processTables("<p>| A | B |\n| --- | --- |\n| 1 |\n| 2 | 3 |</p>")
        XCTAssertTrue(out.contains("<td>2</td><td>3</td>"), "列数一致行保留")
        XCTAssertTrue(out.contains("<td>1</td><td></td>"), "列数不足行补齐空 cell（不再丢弃）")
        XCTAssertFalse(out.contains("<td>1</td><td>2</td>"), "错位拼接不得发生（补齐而非串列）")
    }

    func testSingleDashSeparatorNotTable() {
        let p = GfmPostProcessor()
        // 单连字符分隔行（| - |）→ 判定 -{3,} 不匹配 → 整体不转
        //（原实现误转场景：旧判定仅检查 contains("-")；Down 探针确认该输入原样输出 <p> 形态）
        let html = "<p>| a | b |\n| - | - |\n| 1 | 2 |</p>"
        XCTAssertEqual(p.processTables(html), html, "单连字符分隔行不构成表格")
    }

    func testEscapedPipeBecomesPlainRow() {
        let p = GfmPostProcessor()
        // 转义管道 \| 在 Down（cmark-gfm）HTML 阶段已消费反斜杠（探针实测：| a \| b | → <p>| a | b |），
        // 语义不可区分 → 按普通行处理（设计 Open Question #2 结论：已知限制，标注）
        let out = p.processTables("<p>| a | b |\n| --- | --- |\n| 1 | 2 |</p>")
        XCTAssertTrue(out.contains("<table>"), "转义管道行按普通行处理（HTML 阶段已还原）")
        XCTAssertFalse(out.contains("\\|"), "反斜杠不得残留输出")
    }

    // ⚠️ 新增（round4 T1.3，根因 4）：空单元格保留——修复前 split 默认省略空子序列 →
    // 表头空单元格列数错位 → body 全被 filter → tbody 空
    func testTableEmptyCellPreserved() {
        let p = GfmPostProcessor()
        let out = p.processTables("<p>| A |  | B |\n| --- | --- | --- |\n| 1 |  | 3 |</p>")
        XCTAssertTrue(out.contains("<th>A</th><th></th><th>B</th>"), "表头空单元格保留（3 列对齐）")
        XCTAssertTrue(out.contains("<td>1</td><td></td><td>3</td>"), "body 空单元格保留（3 列对齐）")
        XCTAssertTrue(out.contains("<tbody>"), "tbody 非空（修复前空单元格错位 → tbody 全空）")
    }

    // ⚠️ 新增（round4 T1.3，根因 4）：行内含标签——修复前 [^<]* 遇 < 立即中断 → 整块匹配失败
    func testTableInlineTagInRow() {
        let p = GfmPostProcessor()
        let out = p.processTables("<p>| A | B |\n| --- | --- |\n| <code>x</code> | <a href=\"#\">y</a> |</p>")
        XCTAssertTrue(out.contains("<table>"), "行内标签不中断表格匹配")
        XCTAssertTrue(out.contains("<code>x</code>"), "code 内容保留")
        XCTAssertTrue(out.contains("<a href=\"#\">y</a>"), "链接内容保留")
    }

    // ⚠️ 新增（round4 T1.3，根因 4）：多段落 + 行内标签组合——表头/分隔/body 分散多个 <p>
    func testTableMultiParagraphWithInlineTag() {
        let p = GfmPostProcessor()
        let out = p.processTables("<p>| A | B |</p><p>|---|---|</p><p>| <code>1</code> | 2 |</p>")
        XCTAssertTrue(out.contains("<table>"), "多段落表格转 table")
        XCTAssertTrue(out.contains("<td><code>1</code></td>"), "多段落 + 行内标签组合渲染")
    }

    // ⚠️ 新增（round4 final-verification）：表头尾部空单元格列数误判回归——
    // 修复前 removeLast 误剥真实尾部空列 → columnCount 少 1 → body 行静默截断丢列
    func testTableTrailingEmptyCellPreserved() {
        let p = GfmPostProcessor()
        let out = p.processTables("<p>| A | B |  |\n| --- | --- | --- |\n| 1 | 2 | 3 |</p>")
        XCTAssertTrue(out.contains("<th>A</th><th>B</th><th></th>"), "表头 3 列（尾部空列保留，columnCount=3）")
        XCTAssertTrue(out.contains("<td>1</td><td>2</td><td>3</td>"), "body 3 列完整（不再被截断为 2 列）")
    }

    // ⚠️ S-025（FR-025）追加：脚注两阶段（收集/删除/替换/区块；⚠️ UNVERIFIED 假设 #1 实测锁定）

    func testFootnoteBasicReference() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p>参考 [^1] 与 [^2] 两处</p><p>[^1]: 第一个定义</p><p>[^2]: 第二个定义</p>")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[1]</sup>"), "引用替换为 sup")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[2]</sup>"))
        XCTAssertFalse(out.contains("[^1]: 第一个定义"), "定义原文从正文移除")
        XCTAssertTrue(out.contains("<section class=\"footnotes\">"), "文末追加区块")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">第一个定义</li>"), "区块条目按出现顺序")
        XCTAssertTrue(out.contains("<li id=\"fn-2\">第二个定义</li>"))
    }

    func testFootnoteUnreferencedDefinitionCollected() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p>引用 [^a]</p><p>[^a]: 引用定义</p><p>[^b]: 未引用定义</p>")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">引用定义</li>"))
        XCTAssertTrue(out.contains("<li id=\"fn-2\">未引用定义</li>"), "未引用定义也收集（设计 §S-025）")
        XCTAssertTrue(out.contains("<section class=\"footnotes\">"))
    }

    func testFootnoteNumberingByDocumentOrder() {
        let p = GfmPostProcessor()
        // 编号按定义出现顺序（非引用顺序）：[^a] 定义先出现 → 1
        let out = p.processFootnotes("<p>先引 [^b] 再引 [^a]</p><p>[^a]: A 定义</p><p>[^b]: B 定义</p>")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[1]</sup>"), "[^a] → 编号 1（定义顺序）")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[2]</sup>"), "[^b] → 编号 2")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">A 定义</li>"))
        XCTAssertTrue(out.contains("<li id=\"fn-2\">B 定义</li>"))
    }

    func testFootnoteOrphanReferenceKept() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p>引用 [^ghost] 无定义</p>")
        XCTAssertFalse(out.contains("footnote-ref"), "孤儿引用不替换（无定义）")
        XCTAssertTrue(out.contains("[^ghost]"), "孤儿引用原样保留")
    }

    func testFootnoteRepeatedDefinitionFirstWins() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p>引用 [^x]</p><p>[^x]: 首个定义</p><p>[^x]: 重复定义</p>")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">首个定义</li>"), "重复定义首个生效（GFM 语义）")
        XCTAssertFalse(out.contains("重复定义"), "重复定义被丢弃")
    }

    func testFootnoteMalformedReturnsInput() {
        let p = GfmPostProcessor()
        XCTAssertEqual(p.processFootnotes("<p>no footnotes here</p>"), "<p>no footnotes here</p>", "无定义输入原样返回")
    }

    // ⚠️ S-025（FR-026）追加：autolink 负向排除（⚠️ UNVERIFIED 假设 #2 测试锁定）

    func testAutolinkBareUrl() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<p>visit https://example.com/path now</p>")
        XCTAssertTrue(out.contains("<a href=\"https://example.com/path\">https://example.com/path</a>"), "裸 URL 转链接")
    }

    func testAutolinkSkipsInlineCode() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<p><code>https://example.com</code> text</p>")
        XCTAssertFalse(out.contains("<a href="), "行内代码内 URL 不转")
        XCTAssertTrue(out.contains("<code>https://example.com</code>"))
    }

    func testAutolinkSkipsCodeBlock() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<pre><code>https://example.com</code></pre>")
        XCTAssertFalse(out.contains("<a href="), "代码块内 URL 不转")
    }

    func testAutolinkSkipsExistingAnchorText() {
        let p = GfmPostProcessor()
        let input = "<p><a href=\"https://example.com\">https://example.com</a></p>"
        XCTAssertEqual(p.processAutolinks(input), input, "已有链接文本不嵌套转义")
    }

    func testAutolinkSkipsHrefAttribute() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<p><a href=\"https://example.com\">link</a></p>")
        XCTAssertFalse(out.contains("<a href=\"https://example.com\">https:"), "href 属性值不误转")
    }

    func testAutolinkMultipleUrls() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<p>a https://a.com b https://b.com</p>")
        XCTAssertEqual(out.components(separatedBy: "<a href=").count - 1, 2, "多个裸 URL 全部转链接")
    }

    func testAutolinkStripsTrailingPunctuation() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<p>see https://example.com). next</p>")
        XCTAssertTrue(out.contains("<a href=\"https://example.com\">https://example.com</a>)."),
                      "尾随标点（) .）剥离不括入链接，原文保留")
        XCTAssertFalse(out.contains("https://example.com).\""), "标点不得出现在 href 内")
    }

    // ⚠️ S-025 追加：process() 全链顺序（脚注 → autolink，区块内 URL 也转）

    func testProcessChainFootnotesThenAutolinks() {
        let p = GfmPostProcessor()
        let out = p.process("<p>参考 [^1]</p><p>[^1]: 见 https://example.com</p>")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[1]</sup>"), "链中脚注替换")
        XCTAssertTrue(out.contains("<a href=\"https://example.com\">https://example.com</a>"), "链尾 autolink 处理脚注区块内 URL")
        XCTAssertTrue(out.contains("<section class=\"footnotes\">"), "脚注区块生成")
    }

    // ⚠️ S-025 追加（review cycle 1 修复锁定）：定义含已转换 HTML（(?s) 非贪婪匹配）
    func testFootnoteDefinitionWithConvertedMarkup() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p>参考 [^1]</p><p>[^1]: 见 <del>这里</del></p>")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[1]</sup>"), "引用替换为 sup")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">见 <del>这里</del></li>"), "定义体含已转换 HTML 完整保留")
        XCTAssertFalse(out.contains("[^1]: 见"), "定义原文从正文移除")
    }

    // ⚠️ S-025 追加（review cycle 1 修复锁定）：带语言属性代码块（Down 语言围栏真实输出形态）
    func testAutolinkSkipsCodeBlockWithLanguage() {
        let p = GfmPostProcessor()
        let input = "<pre><code class=\"language-swift\">https://example.com</code></pre>"
        XCTAssertEqual(p.processAutolinks(input), input, "带语言属性代码块内 URL 不转")
    }

    // ⚠️ S-025 追加（review cycle 1 修复锁定）：成对括号 URL 完整保留（失衡括号仍剥离）
    func testAutolinkBalancedParenUrlPreserved() {
        let p = GfmPostProcessor()
        let out = p.processAutolinks("<p>see https://en.wikipedia.org/wiki/Foo_(bar) now</p>")
        XCTAssertTrue(out.contains("<a href=\"https://en.wikipedia.org/wiki/Foo_(bar)\">https://en.wikipedia.org/wiki/Foo_(bar)</a>"),
                      "成对括号 URL 不剥离")
        // 回归：失衡括号仍剥离（testAutolinkStripsTrailingPunctuation 语义保持）
        let out2 = p.processAutolinks("<p>see https://example.com). next</p>")
        XCTAssertTrue(out2.contains("<a href=\"https://example.com\">https://example.com</a>)."), "失衡括号仍剥离")
    }

    // ⚠️ Epic-5 P2（backlog）追加：脚注引用 code/a 保护（autolink PUA token 对称）

    func testFootnoteReferenceInsideCodeProtected() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p><code>[^1]</code> 与 [^2]</p><p>[^1]: A 定义</p><p>[^2]: B 定义</p>")
        XCTAssertTrue(out.contains("<code>[^1]</code>"), "code 内脚注引用原样保留（不替换 sup）")
        XCTAssertFalse(out.contains("<code><sup"), "code 内不得出现 sup 替换")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[2]</sup>"), "code 外引用正常替换")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">A 定义</li>"))
    }

    func testFootnoteReferenceInsideAnchorProtected() {
        let p = GfmPostProcessor()
        let out = p.processFootnotes("<p><a href=\"#\">[^1]</a></p><p>[^1]: A 定义</p>")
        XCTAssertTrue(out.contains("<a href=\"#\">[^1]</a>"), "a 内脚注引用原样保留")
        XCTAssertFalse(out.contains("footnote-ref"), "唯一引用在 a 内 → 无 sup 替换")
        XCTAssertTrue(out.contains("<section class=\"footnotes\">"), "区块仍生成")
    }

    // ⚠️ 新增（Epic-6 批次 1 T1.2）：sourcePos 启用后块级标签带属性（data-sourcepos）→
    // 正则加 [^>]* 宽容化。宽容化不删除属性；带属性时既有转换/保护行为保持

    func testTaskListWithSourcePos() {
        let p = GfmPostProcessor()
        // [x] 与 [ ] 双变体 + data-sourcepos 属性 li：宽容化后两 pattern 均命中
        let out = p.processTaskLists("<li data-sourcepos=\"1:1-1:1\">[x] done</li><li data-sourcepos=\"2:1-2:1\">[ ] todo</li>")
        XCTAssertTrue(out.contains("checked"), "[x] 带属性 li 应转已勾选复选框")
        XCTAssertTrue(out.contains("type=\"checkbox\" disabled> "), "[ ] 带属性 li 应转未勾选复选框")
        XCTAssertEqual(out.components(separatedBy: "task-list-item").count - 1, 2, "双变体全部转换")
    }

    func testTableWithSourcePos() {
        let p = GfmPostProcessor()
        // 带 data-sourcepos 属性的 p 表格段落：宽容化后正常转 table
        let out = p.processTables("<p data-sourcepos=\"1:1-1:3\">| A | B |\n| --- | --- |\n| 1 | 2 |</p>")
        XCTAssertTrue(out.contains("<table>"), "带属性 p 的表格段落应转 table")
        XCTAssertTrue(out.contains("<th>A</th>"), "表头渲染")
        XCTAssertTrue(out.contains("<td>1</td>"), "body 渲染")
    }

    func testFootnoteDefWithSourcePos() {
        let p = GfmPostProcessor()
        // 带 data-sourcepos 属性的 p 脚注定义：宽容化后收集/替换/移除均正常
        let out = p.processFootnotes("<p data-sourcepos=\"1:1-1:1\">参考 [^1]</p><p data-sourcepos=\"2:1-2:1\">[^1]: A 定义</p>")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[1]</sup>"), "带属性 p 的脚注定义正常替换")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">A 定义</li>"), "定义收集")
        XCTAssertFalse(out.contains("[^1]: A 定义"), "带属性定义原文移除")
    }

    func testAutolinkSkipsCodeWithSourcePos() {
        let p = GfmPostProcessor()
        // 带 data-sourcepos 属性的 pre/code：宽容化后块内 URL 不链接化
        let input = "<pre data-sourcepos=\"1:1-1:1\"><code data-sourcepos=\"1:2-1:2\">https://example.com</code></pre>"
        XCTAssertEqual(p.processAutolinks(input), input, "带属性代码块内 URL 不转（保护段原样保留）")
    }

    func testFootnoteRefSkipsCodeWithSourcePos() {
        let p = GfmPostProcessor()
        // 带 data-sourcepos 属性的 pre/code 内 [^1]：宽容化后保护仍生效（不替换 sup）
        let out = p.processFootnotes("<pre data-sourcepos=\"1:1-1:1\"><code data-sourcepos=\"1:2-1:2\">[^1]</code></pre><p>参考 [^1]</p><p data-sourcepos=\"3:1-3:1\">[^1]: A 定义</p>")
        XCTAssertTrue(out.contains("<code data-sourcepos=\"1:2-1:2\">[^1]</code>"), "带属性 code 内脚注引用原样保留")
        XCTAssertFalse(out.contains("<code><sup"), "code 内不得出现 sup 替换")
        XCTAssertTrue(out.contains("<sup class=\"footnote-ref\">[1]</sup>"), "code 外引用正常替换")
        XCTAssertTrue(out.contains("<li id=\"fn-1\">A 定义</li>"))
    }

    func testSourcePosPreservedAfterProcess() {
        let p = GfmPostProcessor()
        // 宽容化只放宽匹配（加 [^>]*），不删除元素属性：p 属性在 autolink 转换后保留；
        // pre/code 保护段（token 恢复）属性原样保留
        let out = p.process("<p data-sourcepos=\"1:1-1:1\">plain https://example.com</p><pre data-sourcepos=\"2:1-2:1\"><code data-sourcepos=\"2:2-2:2\">https://example.com</code></pre>")
        XCTAssertTrue(out.contains("<p data-sourcepos=\"1:1-1:1\">plain <a href=\"https://example.com\">https://example.com</a></p>"),
                      "转换段落的 p 属性保留（宽容化不删除属性）")
        XCTAssertTrue(out.contains("<pre data-sourcepos=\"2:1-2:1\"><code data-sourcepos=\"2:2-2:2\">https://example.com</code></pre>"),
                      "保护段 pre/code 属性原样恢复")
    }

    // ⚠️ Epic-6 批次 4 T4.1（FR-028）追加：TOC 生成——[TOC] 占位替换为目录
    //（标题收集 + 自生成 id toc-N——cmark 无标题 id；折叠语义：TOC 文本 strip 行内标签）

    func testTocReplacesPlaceholderWithNestedList() {
        let p = GfmPostProcessor()
        let out = p.processTOC("<p>[TOC]</p><h1>Main <strong>Title</strong></h1><h2>Sub</h2>")
        XCTAssertEqual(out,
            "<div class=\"toc\"><ul><li><a href=\"#toc-1\">Main Title</a><ul><li><a href=\"#toc-2\">Sub</a></li></ul></li></ul></div>"
            + "<h1 id=\"toc-1\">Main <strong>Title</strong></h1><h2 id=\"toc-2\">Sub</h2>",
            "TOC 替换占位符：嵌套层级 + 行内标签剥为纯文本 + 标题按文档顺序补 id")
        XCTAssertFalse(out.contains("[TOC]"), "占位符段落被移除")
    }

    func testTocCollectsH1ToH6InDocumentOrder() {
        let p = GfmPostProcessor()
        let out = p.processTOC("<p>[TOC]</p><h3>Three</h3><h1>One</h1><h6>Six</h6><h2>Two</h2>")
        // 全部级别（H1-H6）收集；编号按文档出现顺序（首个标题 h3 → toc-1）
        XCTAssertTrue(out.contains("<a href=\"#toc-1\">Three</a>"))
        XCTAssertTrue(out.contains("<a href=\"#toc-2\">One</a>"))
        XCTAssertTrue(out.contains("<a href=\"#toc-3\">Six</a>"))
        XCTAssertTrue(out.contains("<a href=\"#toc-4\">Two</a>"))
        // 文档顺序断言：toc div 内 href 位置递增（toc-1 → toc-4）
        guard let divStart = out.range(of: "<div class=\"toc\">") else {
            XCTFail("缺少 toc div"); return
        }
        let div = out[divStart.lowerBound...]
        let positions = (1...4).map { div.range(of: "#toc-\($0)\"")?.lowerBound }
        XCTAssertEqual(positions.compactMap { $0 }.count, 4, "4 个标题全部收集进 TOC")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(),
                       "TOC 列表按文档顺序排列")
    }

    func testTocIdsStableInDocumentOrder() {
        let p = GfmPostProcessor()
        let out = p.processTOC("<p>[TOC]</p><h2>First</h2><h3>Second</h3><h2>Third</h2>")
        XCTAssertTrue(out.contains("<h2 id=\"toc-1\">First</h2>"), "文档首个标题 → toc-1")
        XCTAssertTrue(out.contains("<h3 id=\"toc-2\">Second</h3>"), "文档第二标题 → toc-2")
        XCTAssertTrue(out.contains("<h2 id=\"toc-3\">Third</h2>"), "文档第三标题 → toc-3")
        XCTAssertTrue(out.contains("<a href=\"#toc-1\">First</a>"), "TOC 链接与标题 id 一一对应")
        XCTAssertTrue(out.contains("<a href=\"#toc-2\">Second</a>"))
        XCTAssertTrue(out.contains("<a href=\"#toc-3\">Third</a>"))
    }

    func testTocAbsentLeavesHeadingsUntouched() {
        let p = GfmPostProcessor()
        let input = "<h2>No TOC here</h2><p>plain <strong>text</strong></p>"
        XCTAssertEqual(p.processTOC(input), input, "无 [TOC] 段落 → 原样返回，标题不加 id（零副作用）")
    }
}
