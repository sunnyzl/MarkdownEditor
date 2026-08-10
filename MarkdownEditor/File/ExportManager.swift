import AppKit
import WebKit
import UniformTypeIdentifiers

// ExportManager.swift — 导出 HTML/PDF/Markdown（S-031，FR-091/092/093）
// HTML：webview getContent()（含 KaTeX/Mermaid 渲染结果）→ 等 renderDone → 内联三件套 → 单文件离线
// PDF：printOperation（webview 当前状态打印，天然含 SVG/公式——PRD 指定，非 createPDF）
// Markdown：原始源码经 markdownDocument 纯函数面流转后写盘（无渲染，FR-093）；复制走 NSPasteboard（注入面，生产默认 .general）
// 纯逻辑（模板组装/资源内联/打印配置/等待判定/MD 纯函数）可单测；WKWebView 本体手动验收
@MainActor
final class ExportManager {

    // MARK: - 纯函数（可测）

    /// 导出前等待秒数：最近 renderDone 距今 ≥ 0.5s → 渲染已稳定（0 等待）；
    /// nil → 超时等待；< 0.5s → 等待剩余时长 0.5s 或超时（设计 §错误处理：等 renderDone 超时降级）
    static func waitSeconds(lastRenderDoneAt: Date?, now: Date, timeout: TimeInterval) -> TimeInterval {
        guard let last = lastRenderDoneAt else { return timeout }
        let age = now.timeIntervalSince(last)
        guard age < 0.5 else { return 0 }
        return min(timeout, 0.5 - age)
    }

    /// 导出前净化：移除 markdown-it 注入的 data-sourcepos 内部属性（内部属性不进入导出文档）；
    /// 仅匹配真实 sourcepos 格式（行:列-行:列 数字，与 SourceMapParser 契约一致），
    /// 非数字取值或 HTML 转义形式（&quot;）不被误删
    static func stripSourcePos(from html: String) -> String {
        html.replacingOccurrences(
            of: #"\s*data-sourcepos="\d+:\d+-\d+:\d+""#,
            with: "",
            options: .regularExpression
        )
    }

    /// 读 WebAssets 内联资源（缺失键跳过——设计 §错误处理：资源缺失降级纯 HTML）
    static func readResources(from baseURL: URL) -> [String: String] {
        let files: [String: String] = [
            "katex/katex.min.css": "katexCSS",
            "highlight/github.min.css": "hljsCSS",
            "katex/katex.min.js": "katexJS",
            "katex/auto-render.min.js": "autoRenderJS",
            "mermaid/mermaid.min.js": "mermaidJS",
            "highlight/highlight.min.js": "hljsJS",
        ]
        var result: [String: String] = [:]
        for (relative, key) in files {
            let url = baseURL.appendingPathComponent(relative)
            if let data = try? String(contentsOf: url, encoding: .utf8) {
                result[key] = data
            }
        }
        return result
    }

    /// 预览基础样式（preview.html `<style>` 主体镜像——导出单文件离线可用）
    static let baseCSS = """
    :root { --bg: #ffffff; --fg: #24292e; --muted: #6a737d; --code-bg: #f6f8fa; --border: #d0d7de; --link: #0969da; --font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; --code-font-family: ui-monospace, Menlo, monospace; }
    body.dark { --bg: #0d1117; --fg: #c9d1d9; --muted: #8b949e; --code-bg: #161b22; --border: #30363d; --link: #58a6ff; }
    body { background: var(--bg); color: var(--fg); font-family: var(--font-family); margin: 0; padding: 16px; line-height: 1.6; }
    #content { max-width: 780px; margin: 0 auto; word-wrap: break-word; }
    code { background: var(--code-bg); padding: .15em .4em; border-radius: 3px; font-family: var(--code-font-family); font-size: 90%; }
    pre { background: var(--code-bg); padding: 12px; border-radius: 6px; overflow-x: auto; }
    pre.mermaid { background: transparent; border: 1px solid var(--border); text-align: center; }
    pre code.hljs { padding: 0; background: transparent; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid var(--border); padding: 6px 12px; }
    .katex-error { color: #d73a49 !important; }
    .footnotes { margin-top: 24px; padding-top: 12px; border-top: 1px solid var(--border); font-size: 0.9em; color: var(--muted); }
    """

    /// 导出 HTML 文档组装（模板 + 内联资源；缺失资源降级跳过；组装前先净化 data-sourcepos）
    static func exportHTMLDocument(content: String, resources: [String: String], title: String) -> String {
        let cleanedContent = stripSourcePos(from: content)
        var css = baseCSS
        if let katexCSS = resources["katexCSS"] { css += "\n" + katexCSS }
        if let hljsCSS = resources["hljsCSS"] { css += "\n" + hljsCSS }
        var scripts = ""
        if let katexJS = resources["katexJS"] { scripts += "<script>\(katexJS)</script>\n" }
        if let autoRenderJS = resources["autoRenderJS"] { scripts += "<script>\(autoRenderJS)</script>\n" }
        if let mermaidJS = resources["mermaidJS"] { scripts += "<script>\(mermaidJS)</script>\n" }
        if let hljsJS = resources["hljsJS"] { scripts += "<script>\(hljsJS)</script>\n" }
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        <style>\(css)</style>
        </head>
        <body>
        <div id="content">\(cleanedContent)</div>
        \(scripts)
        </body>
        </html>
        """
    }

    /// 打印配置（FR-092：printOperation；A4 纵向 + 20mm 边距）
    static func printConfiguration() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.2, height: 841.8)   // A4 (pt)
        info.orientation = .portrait
        info.topMargin = 56.7
        info.bottomMargin = 56.7
        info.leftMargin = 56.7
        info.rightMargin = 56.7
        info.horizontalPagination = .fit
        return info
    }

    /// 纯 Markdown 文档（FR-093）：当前即原文——预留纯函数面（后续如需包裹/规范化在此扩展）
    static func markdownDocument(_ text: String) -> String {
        text
    }

    /// 复制 Markdown 源码到剪贴板（FR-093）：清空后写入 .string 类型。
    /// 注入面——测试用局部命名剪贴板（不污染用户真实剪贴板），生产默认 .general
    @discardableResult
    static func copyMarkdown(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    // MARK: - 实例方法（WKWebView 本体，手动验收）

    /// 导出 HTML：等渲染稳定 → getContent → 内联组装 → NSSavePanel 写盘
    func exportHTML(webView: PreviewWebView,
                    renderDoneTimestamp: @escaping () -> Date?,
                    baseURL: URL? = nil) async {
        let wait = Self.waitSeconds(lastRenderDoneAt: renderDoneTimestamp(), now: Date(), timeout: 2)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        guard let content = await getContent(webView: webView) else {
            presentError("导出内容读取失败（webview 未就绪）")
            return
        }
        // 未完成 mermaid 渲染降级警告（设计 §错误处理：导出当前状态 + 警告）
        if let unrendered = await getUnrenderedCount(webView: webView), unrendered > 0 {
            NSLog("[Export] mermaid 未完成渲染块数=%d，导出当前状态", unrendered)
        }
        let assets = baseURL ?? Bundle.main.resourceURL?.appendingPathComponent("WebAssets", isDirectory: true)
        let resources = assets.map { Self.readResources(from: $0) } ?? [:]
        let document = Self.exportHTMLDocument(content: content, resources: resources, title: "导出")
        guard let url = savePanel(types: [.html]) else { return }
        do {
            try document.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    /// 导出 PDF：等渲染稳定 → createPDF 直接生成 PDF → NSSavePanel 保存
    /// ⚠️ 修复（真机验收）：原 printOperation+打印面板 = 打印对话框（用户预期"导出 PDF"）；
    /// 改用 WKWebView.createPDF（macOS 11+）直接产出 PDF 数据 → 保存面板
    /// 渲染稳定等待保持（防 mermaid 中途状态入 PDF）
    func exportPDF(webView: PreviewWebView,
                   renderDoneTimestamp: @escaping () -> Date?) async {
        let wait = Self.waitSeconds(lastRenderDoneAt: renderDoneTimestamp(), now: Date(), timeout: 2)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        guard let data = try? await webView.webView.pdf() else { return }
        guard let url = savePanel(types: [Self.pdfType], defaultName: "export.pdf") else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Export] PDF 写盘失败: %@", error.localizedDescription)
        }
    }

    /// PDF 文件类型（NSSavePanel allowedContentTypes 用）
    static let pdfType = UTType.pdf

    /// 导出纯 Markdown（FR-093）：原始源码经 markdownDocument 纯函数面流转后写盘（无渲染——不走 webview 链路）。
    /// NSSavePanel（.md 类型）→ 写盘；window 参数为菜单路由预留（多窗口 sheet 展示后续增强，
    /// 当前与 exportHTML 同 app-modal runModal 模式）
    func exportMarkdown(text: String, from window: NSWindow?) {
        guard let url = savePanel(types: [Self.markdownType], defaultName: "export.md") else { return }
        do {
            try Self.markdownDocument(text).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - 私有

    /// .md 类型（SDK 无 UTType.markdown 静态成员——经 filenameExtension 解析 net.daringfireball.markdown）
    private static let markdownType = UTType(filenameExtension: "md") ?? .plainText

    private func getContent(webView: PreviewWebView) async -> String? {
        let result = try? await webView.webView.evaluateJavaScript("window.getContent()")
        return result as? String
    }

    private func getUnrenderedCount(webView: PreviewWebView) async -> Int? {
        let result = try? await webView.webView.evaluateJavaScript("window.getUnrenderedCount()")
        return (result as? NSNumber)?.intValue
    }

    private func savePanel(types: [UTType], defaultName: String = "export.html") -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "导出失败"
        alert.informativeText = message
        alert.runModal()
    }
}
