import XCTest
@testable import MarkdownEditor

// MermaidPreprocessor：正则转换正确性（$1 反向引用 / 实体 unescape / 残留检测）（S-010 阶段 3）
final class MermaidPreprocessorTests: XCTestCase {
    private let pre = MermaidPreprocessor()

    func testBasicTransformation() {
        let input = #"<p>text</p><pre><code class="language-mermaid">graph TD; A-->B</code></pre><p>end</p>"#
        let result = pre.transform(html: input)
        XCTAssertEqual(result.html,
                       #"<p>text</p><pre class="mermaid">graph TD; A-->B</pre><p>end</p>"#)
        XCTAssertFalse(result.needsJsFallback)
    }

    func testMultipleBlocks() {
        let input = """
        <pre><code class="language-mermaid">graph TD; A-->B</code></pre>\
        <pre><code class="language-swift">let x = 1</code></pre>\
        <pre><code class="language-mermaid">sequenceDiagram; A->>B: hi</code></pre>
        """
        let result = pre.transform(html: input)
        XCTAssertEqual(result.html.components(separatedBy: #"<pre class="mermaid">"#).count - 1, 2,
                       "两个 mermaid 块全部转换")
        XCTAssertTrue(result.html.contains(#"<pre><code class="language-swift">"#),
                      "非 mermaid 代码块不受影响（无副作用，AD-4 Rule）")
    }

    func testUnescapeEntities() {
        let input = #"<pre><code class="language-mermaid">graph LR; A--&gt;B &amp; C</code></pre>"#
        let result = pre.transform(html: input)
        XCTAssertTrue(result.html.contains("A--&gt;".replacingOccurrences(of: "&gt;", with: ">")),
                      "&gt; 还原为 >")
        XCTAssertTrue(result.html.contains("&amp;".replacingOccurrences(of: "&amp;", with: "&")),
                      "&amp; 还原为 &")
    }

    func testResidualDetection() {
        // 格式变体（如属性顺序变化）正则未命中 → needsJsFallback = true
        let weird = #"<pre><code class="language-mermaid" data-x="1">graph</code></pre>"#
        let result = pre.transform(html: weird)
        XCTAssertTrue(result.needsJsFallback, "残留必须标记，驱动 JS DOM 兜底（设计 §7 双保险）")
    }

    func testNoMermaidNoChange() {
        let input = "<p>plain</p>"
        let result = pre.transform(html: input)
        XCTAssertEqual(result.html, input)
        XCTAssertFalse(result.needsJsFallback)
    }

    // ⚠️ 新增（Epic-6 批次 1 T1.2）：sourcePos 启用后 pre 带 data-sourcepos 属性 →
    // 宽容化（<pre[^>]*><code[^>]* class=...）后转换正常
    func testMermaidWithSourcePos() {
        let input = #"<pre data-sourcepos="1:1-1:1"><code data-sourcepos="1:2-1:2" class="language-mermaid">graph TD; A-->B</code></pre>"#
        let result = pre.transform(html: input)
        XCTAssertTrue(result.html.contains(#"<pre class="mermaid">graph TD; A-->B</pre>"#),
                      "带属性 pre 的 mermaid 块正常转换")
        XCTAssertFalse(result.needsJsFallback, "转换成功 → 无需 JS 兜底")
    }
}
