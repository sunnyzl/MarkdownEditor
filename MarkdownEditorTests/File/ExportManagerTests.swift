import XCTest
import AppKit
@testable import MarkdownEditor

// ExportManager：HTML 组装/资源内联/打印配置/等待判定（S-031，FR-091/092；WKWebView 手动验收）
// ⚠️ 与 PreviewWebViewTests 同模式（第 5 轮修复 #1）：waitSeconds/readResources 等是 @MainActor static，测试需同隔离域
@MainActor
final class ExportManagerTests: XCTestCase {
    func testWaitSecondsRecentReturnsRemaining() {
        let now = Date()
        // 0.2s 前完成 → 还需等 0.3s
        XCTAssertEqual(ExportManager.waitSeconds(lastRenderDoneAt: now.addingTimeInterval(-0.2), now: now, timeout: 2), 0.3, accuracy: 0.001)
    }

    func testWaitSecondsJustCompletedReturnsFullWindow() {
        let now = Date()
        XCTAssertEqual(ExportManager.waitSeconds(lastRenderDoneAt: now, now: now, timeout: 2), 0.5, accuracy: 0.001)
    }

    func testWaitSecondsStaleReturnsZero() {
        let now = Date()
        // 3s 前完成 → 渲染已稳定，立即导出
        XCTAssertEqual(ExportManager.waitSeconds(lastRenderDoneAt: now.addingTimeInterval(-3), now: now, timeout: 2), 0)
    }

    func testWaitSecondsNilReturnsTimeout() {
        XCTAssertEqual(ExportManager.waitSeconds(lastRenderDoneAt: nil, now: Date(), timeout: 2), 2)
    }

    func testReadResourcesReadsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("katex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("highlight"), withIntermediateDirectories: true)
        try "katex-css".write(to: dir.appendingPathComponent("katex/katex.min.css"), atomically: true, encoding: .utf8)
        try "hljs-css".write(to: dir.appendingPathComponent("highlight/github.min.css"), atomically: true, encoding: .utf8)
        let resources = ExportManager.readResources(from: dir)
        XCTAssertEqual(resources["katexCSS"], "katex-css")
        XCTAssertEqual(resources["hljsCSS"], "hljs-css")
        XCTAssertNil(resources["mermaidJS"], "缺失资源键跳过（降级）")
    }

    func testExportHTMLDocumentAssembles() {
        let doc = ExportManager.exportHTMLDocument(
            content: "<p>正文</p>",
            resources: ["katexCSS": "/*k*/", "katexJS": "/*kjs*/"],
            title: "测试导出")
        XCTAssertTrue(doc.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(doc.contains("<title>测试导出</title>"))
        XCTAssertTrue(doc.contains("<p>正文</p>"))
        XCTAssertTrue(doc.contains("/*k*/"), "katex CSS 已内联")
        XCTAssertTrue(doc.contains("<script>/*kjs*/</script>"), "katex JS 已内联")
    }

    func testExportHTMLDocumentDegradesOnMissingResources() {
        let doc = ExportManager.exportHTMLDocument(content: "<p>正文</p>", resources: [:], title: "t")
        XCTAssertTrue(doc.contains("<p>正文</p>"), "资源缺失时内容仍导出")
        XCTAssertTrue(doc.contains(ExportManager.baseCSS), "基础样式恒内联")
    }

    func testStripSourcePosRemovesAllAttributes() {
        let html = #"<p data-sourcepos="1:1-1:10">正文</p><div data-sourcepos="2:1-2:5">块</div>"#
        let cleaned = ExportManager.stripSourcePos(from: html)
        XCTAssertFalse(cleaned.contains("data-sourcepos"), "所有 data-sourcepos 属性被移除")
    }

    func testStripSourcePosReturnsInputUnchangedWhenNone() {
        let html = "<p>正文</p><div>块</div>"
        XCTAssertEqual(ExportManager.stripSourcePos(from: html), html, "无属性输入原样返回")
    }

    func testStripSourcePosKeepsNonNumericValue() {
        // 评审 IMPORTANT：仅限定真实 sourcepos 格式（行:列-行:列），非数字取值不得误删
        let html = #"<p data-sourcepos="custom-value">正文</p>"#
        let cleaned = ExportManager.stripSourcePos(from: html)
        XCTAssertTrue(cleaned.contains(#"data-sourcepos="custom-value""#), "非数字取值不被误删（与 SourceMapParser 契约一致）")
    }

    func testStripSourcePosKeepsEscapedExampleInCodeBlock() {
        // 代码块内字面示例：HTML 实体转义形式（&quot;）非真实属性，必须原样返回
        let html = "<pre><code>&lt;p data-sourcepos=&quot;5:1-5:3&quot;&gt;</code></pre>"
        XCTAssertEqual(ExportManager.stripSourcePos(from: html), html, "代码块内字面示例（&quot; 转义）原样返回")
    }

    func testPrintConfigurationIsA4() {
        let info = ExportManager.printConfiguration()
        // ⚠️ 平台适配：NSPrintInfo 将 paperSize 吸附到打印机标准 A4（595.2×841.8 → 595.0×842.0），
        // 按 A4 容差断言（与本文件 topMargin accuracy 惯例一致）
        XCTAssertEqual(info.paperSize.width, 595.2, accuracy: 0.5, "A4 宽")
        XCTAssertEqual(info.paperSize.height, 841.8, accuracy: 0.5, "A4 高")
        XCTAssertEqual(info.orientation, .portrait)
        XCTAssertEqual(info.topMargin, 56.7, accuracy: 0.01)
    }

    // ⚠️ T4.3（FR-093）：纯 Markdown 导出/复制——markdownDocument 原样（当前即原文，预留纯函数面）
    func testMarkdownDocumentReturnsInputUnchanged() {
        let text = "# 标题\n\n正文 **加粗** 与 `代码`\n\n- 列表项\n\n> 引用"
        XCTAssertEqual(ExportManager.markdownDocument(text), text, "纯 MD 导出当前即原文（预留纯函数面）")
    }

    // ⚠️ T4.3 fix1（评审 IMPORTANT）：copyMarkdown 注入局部命名剪贴板——不污染用户真实剪贴板
    // 注：AppKit 的 NSPasteboard(name:) 非 failable 且按需创建命名剪贴板（+pasteboardWithName: 导入），
    // 无 init(name:create:)；XCTSkip 分支仅保留以兼容未来 SDK 变化
    @MainActor
    func testCopyMarkdownWritesPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.markdowneditor.tests.copy"))
        let text = "# 标题\n\n正文"
        XCTAssertTrue(ExportManager.copyMarkdown(text, pasteboard: pasteboard), "写入成功返回 true")
        XCTAssertEqual(pasteboard.string(forType: .string), text, "局部剪贴板可读回")
    }
}
