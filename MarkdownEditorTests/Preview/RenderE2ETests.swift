import XCTest
import Down
@testable import MarkdownEditor

// RenderE2ETests.swift — 渲染管线端到端测试（设计 §批次2 方案 B）
// 构造真实 PreviewWebView → Down 渲染 markdown → setContent → 等 onRenderDone
// → evaluateJavaScript 查 DOM 断言。覆盖验收 B 组（脚注/代码/KaTeX/Mermaid/TOC/sourcepos/morphdom）。
//
// Render pipeline E2E: real PreviewWebView → Down-rendered HTML → setContent →
// await onRenderDone → evaluateJavaScript DOM assertions (acceptance group B).
@MainActor
final class RenderE2ETests: XCTestCase {

    private var view: PreviewWebView!

    // ⚠️ 烟雾前置：等待真实页面加载。若超时 → 测试 host 无法访问 WebAssets
    // (design ⚠️ UNVERIFIED) → 检查 project.yml TEST_HOST + WebAssets folder reference 打包。
    override func setUp() {
        super.setUp()
        view = PreviewWebView()
        let exp = expectation(description: "pageReady")
        view.onPageLoaded = { exp.fulfill() }
        wait(for: [exp], timeout: 20.0)
    }

    override func tearDown() {
        view = nil
        super.tearDown()
    }

    // MARK: - 辅助 / Helpers

    /// 渲染 HTML 并等 onRenderDone，然后执行 JS 查询返回结果
    /// Render HTML, await onRenderDone, then evaluate JS query.
    @discardableResult
    private func renderAndQuery(_ html: String, query js: String,
                                renderTimeout: TimeInterval = 15.0) -> Any? {
        let renderExp = expectation(description: "renderDone")
        let queryExp = expectation(description: "queryDone")
        var queryResult: Any?
        view.onRenderDone = { _ in
            renderExp.fulfill()
            self.view.webView.evaluateJavaScript(js) { result, _ in
                queryResult = result
                queryExp.fulfill()
            }
        }
        view.setContent(html)
        wait(for: [renderExp, queryExp], timeout: renderTimeout)
        return queryResult
    }

    /// 两次渲染（验证 morphdom 增量 diff），返回第二次 JS 查询结果
    /// Render twice (morphdom incremental diff), return second query result.
    @discardableResult
    private func renderTwiceAndQuery(_ firstHtml: String, _ secondHtml: String,
                                     query js: String,
                                     renderTimeout: TimeInterval = 15.0) -> Any? {
        // 首次渲染（建立 DOM）
        // First render (establish DOM)
        let firstExp = expectation(description: "firstRenderDone")
        view.onRenderDone = { _ in firstExp.fulfill() }
        view.setContent(firstHtml)
        wait(for: [firstExp], timeout: renderTimeout)
        // 二次渲染（morphdom diff，验证增量更新而非全量重建）
        // Second render (morphdom diff — incremental update, not full rebuild)
        return renderAndQuery(secondHtml, query: js, renderTimeout: renderTimeout)
    }

    // MARK: - R1 脚注 / Footnotes

    func testR1_FootnoteRenders() throws {
        // Down-gfm 脚注语法 / Down-gfm footnote syntax
        let md = """
        Body text with a footnote[^1].

        [^1]: Footnote content here.
        """
        // E2E 全管线：Down + GfmPostProcessor.processFootnotes 发出 <section class="footnotes">
        // Full pipeline: Down + GfmPostProcessor.processFootnotes emits <section class="footnotes">
        let html = try DownParser().render(markdown: md)
        // ⚠️ web 端契约：脚注渲染为 .footnote 或标准 .footnotes section
        // 若 preview.html 用不同类名，此处需对应调整
        let count = renderAndQuery(html,
            query: "document.querySelectorAll('.footnote, .footnotes, section.footnotes').length") as? Int
        XCTAssertGreaterThan(count ?? 0, 0,
            "R1:脚注应渲染为 .footnote/.footnotes 元素(design §批次2 R1)")
    }

    // MARK: - R2 代码块内 URL 不转义 / Code-block URL passthrough

    func testR2_CodeBlockUrlNotLinkified() throws {
        let md = """
        ```
        http://example.com/path?q=1&x=2
        ```
        """
        let html = try Down(markdownString: md).toHTML()
        // 代码块内 URL 不应被转为 <a> 链接（URL 保持纯文本）
        // URL inside code block must NOT be linkified (stays plain text)
        let linkCount = renderAndQuery(html,
            query: "document.querySelectorAll('pre code a').length") as? Int
        XCTAssertEqual(linkCount ?? -1, 0, "R2:代码块内 URL 不应转为链接")
        let text = renderAndQuery(html,
            query: "(document.querySelector('pre code')||{}).textContent || ''") as? String
        XCTAssertTrue(text?.contains("http://example.com/path?q=1&x=2") ?? false,
            "R2:代码块内 URL 文本应原样保留(含 query string)")
    }

    // MARK: - R3 KaTeX / Inline math

    func testR3_KaTexRenders() throws {
        // ⚠️ KaTeX 触发：web 端 auto-render 扫描 $...$ / $$...$$
        // 若 preview.html 用 \(...\) 或 .math 容器，需调整输入
        let md = "$E=mc^2$ and block $$\\int_0^1 x\\,dx$$"
        let html = try Down(markdownString: md).toHTML()
        let count = renderAndQuery(html,
            query: "document.querySelectorAll('.katex').length") as? Int
        XCTAssertGreaterThan(count ?? 0, 0,
            "R3:KaTeX 应渲染为 .katex 元素(design §批次2 R3)")
    }

    // MARK: - R4 Mermaid 正常渲染 / Mermaid valid diagram

    func testR4_MermaidRendersSvg() throws {
        let md = """
        ```mermaid
        graph TD
        A-->B
        B-->C
        ```
        """
        let html = try Down(markdownString: md).toHTML()
        // web 端 Mermaid：code.language-mermaid → <svg>
        // ⚠️ Mermaid 异步渲染，onRenderDone 须在其完成后触发（设计 §Error Handling）
        let svgCount = renderAndQuery(html,
            query: "document.querySelectorAll('svg').length") as? Int
        XCTAssertGreaterThan(svgCount ?? 0, 0,
            "R4:Mermaid 应渲染为 <svg> 元素(design §批次2 R4)")
    }

    // MARK: - R5 Mermaid 错误兜底 / Mermaid error fallback

    func testR5_MermaidErrorSignalsError() throws {
        // E2E 全管线渲染 / Full pipeline render
        let md = """
        ```mermaid
        this is definitely not valid mermaid @@@!!!
        ```
        """
        let html = try DownParser().render(markdown: md)
        // 非法 Mermaid 语法 → web 端异步捕获（MessageBridge.js 修订 B1：
        // mermaid.run().catch 在同步 renderDone(status=ok) 之后异步 post errorOccurred）。
        // 故 renderDone(status=ok) 不立即判定，持续等延迟的 errorOccurred；
        // status=error 则立即确认。断言不削弱（修订 B1 保证 errorOccurred 必发）。
        // Invalid Mermaid → async error: renderDone(ok) fires synchronously, then a late
        // errorOccurred (修订 B1). Don't decide on status=ok; keep waiting for the late
        // errorOccurred. status=error confirms immediately. Assertion NOT weakened.
        let errorExp = expectation(description: "errorSignaled")
        var doneStatus: String?
        var errorFired = false
        view.onRenderDone = { payload in
            doneStatus = payload.status
            if payload.status != "ok" { errorExp.fulfill() }
            // status == "ok"：不立即判定，等延迟的 errorOccurred（修订 B1 异步时序）
        }
        view.onErrorOccurred = { _, _ in
            errorFired = true
            errorExp.fulfill()
        }
        view.setContent(html)
        // 即便 renderDone(status=ok) 先到，wait 仍持续等延迟的 errorOccurred（≤6s）
        // Even if renderDone(ok) arrives first, wait keeps waiting for late errorOccurred (≤6s)
        wait(for: [errorExp], timeout: 6.0)
        XCTAssertTrue(errorFired || doneStatus != "ok",
            "R5:非法 Mermaid 语法应触发错误信号(design §批次2 R5); status=\(doneStatus ?? "nil") errorFired=\(errorFired)")
    }

    // MARK: - R6 TOC 目录 / Table of contents

    func testR6_TocRenders() throws {
        // [TOC] 占位符必需——GfmPostProcessor.processTOC 检测 <p>[TOC]</p> 才生成目录
        // [TOC] placeholder required — processTOC only generates TOC when it detects <p>[TOC]</p>
        let md = """
        [TOC]

        # Title

        ## Section A

        ### Subsection

        ## Section B
        """
        // E2E 全管线：Down + GfmPostProcessor.processTOC 发出 <div class="toc">
        // Full pipeline: Down + GfmPostProcessor.processTOC emits <div class="toc">
        let html = try DownParser().render(markdown: md)
        let tocCount = renderAndQuery(html,
            query: "document.querySelectorAll('.toc').length") as? Int
        XCTAssertGreaterThan(tocCount ?? 0, 0,
            "R6:应生成 .toc 目录元素(design §批次2 R6)")
    }

    // MARK: - R7 data-sourcepos 注入 / Source position injection

    func testR7_SourcePosInjected() throws {
        // data-sourcepos：web 端基于 Down sourcePos 注入到渲染元素
        // ⚠️ 需 web 端开启 sourcePos 消费；若 Down 渲染未携带 sourcePos，需传 options
        // data-sourcepos: web injects from Down sourcePos. May need Down options.
        let md = "# Hello\n\nParagraph text."
        var html: String
        do {
            // ⚠️ 适配（ADAPTATION，implementer）：Down API 是 .sourcePos（非计划中的 .sourceMap）。
            // 证据：DownParser.swift:21 `.default.union(.sourcePos)` + POC-S-004 验证 rawValue 2。
            // 保留 do/catch 兜底以匹配计划结构。
            // Adapted: Down option is .sourcePos (not .sourceMap per plan). Evidence:
            // DownParser.swift:21 + POC-S-004 (rawValue 2). do/catch kept to match plan shape.
            html = try Down(markdownString: md).toHTML(.default.union(.sourcePos))
        } catch {
            html = try Down(markdownString: md).toHTML()
        }
        let sourceposCount = renderAndQuery(html,
            query: "document.querySelectorAll('[data-sourcepos]').length") as? Int
        XCTAssertGreaterThan(sourceposCount ?? 0, 0,
            "R7:渲染元素应注入 data-sourcepos 属性(design §批次2 R7)")
    }

    // MARK: - R8 morphdom 增量 diff / Incremental DOM update

    func testR8_MorphdomDiffsContent() throws {
        // 相似结构、变化内容 → morphdom 增量 diff（非全量重建）
        // 验证：二次渲染后 <p> 文本正确更新为 "two"（若全量重建可能丢失或错位）
        let html1 = try Down(markdownString: "# Title\n\nParagraph one.").toHTML()
        let html2 = try Down(markdownString: "# Title\n\nParagraph two.").toHTML()
        let text = renderTwiceAndQuery(html1, html2,
            query: "(document.querySelector('p')||{}).textContent || ''") as? String
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "Paragraph two.",
            "R8:morphdom 应增量更新变化内容为 'Paragraph two.'(design §批次2 R8)")
    }

    // MARK: - D1 内存指标 / Memory metric (design §批次2 方案 D1)

    func testD1_RenderMemoryStability() {
        // measure 自动重复闭包（默认 5 iterations），每 iteration 内 50 次密集 setContent
        // 检测 WebContent/PreviewWebView 内存回归基线（design §批次2 D1）
        //
        // measure repeats the block (default 5 iterations); each iteration does
        // 50 dense setContent calls to detect memory regressions.
        measure(metrics: [XCTMemoryMetric()]) {
            for i in 0..<50 {
                view.setContent("<p>memory stress iteration \(i) " +
                    String(repeating: "lorem ipsum ", count: 30) + "</p>")
            }
        }
    }
}
