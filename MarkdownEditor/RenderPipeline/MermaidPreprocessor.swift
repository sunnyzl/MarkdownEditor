import Foundation

// MermaidPreprocessor.swift — Mermaid 代码块 Swift 正则转换（S-010 阶段 3，设计 §5.2 方案 B）
// 正则: <pre><code class="language-mermaid">([\s\S]*?)</code></pre> → <pre class="mermaid">$1</pre>
// 注意 $1（非 \1）；unescape 实体（Down 输出 code 内容已转义）；残留检测驱动 JS 兜底（方案 A）
struct MermaidPreprocessor: MermaidPreprocessing {
    /// 与 POC S-001 一致的匹配模式（Down 输出格式隐式契约，POC S-004 已确认）
    /// ⚠️ 宽容化（Epic-6 T1.2）：<pre[^>]*><code[^>]* class=... 允许 sourcePos 属性（data-sourcepos）
    static let pattern = #"<pre[^>]*><code[^>]* class="language-mermaid">([\s\S]*?)</code></pre>"#

    func transform(html: String) -> MermaidTransformResult {
        guard let regex = try? NSRegularExpression(pattern: Self.pattern) else {
            return MermaidTransformResult(html: html, needsJsFallback: true)
        }
        let ns = html as NSString
        var output = ""
        var lastEnd = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: lastEnd,
                                                 length: match.range.location - lastEnd))
            let code = ns.substring(with: match.range(at: 1))
            output += "<pre class=\"mermaid\">" + Self.unescapeEntities(code) + "</pre>"
            lastEnd = match.range.location + match.range.length
        }
        output += ns.substring(from: lastEnd)

        // 残留检测（⚠️ 修复 C3/第 7 轮）：转换后仍存在 language-mermaid code 块 → 需 JS DOM 兜底（方案 A）
        // 用宽模式（仅匹配 class 含 language-mermaid 的 code 元素），
        // 使属性变体（如 data-x、属性顺序）也能被捕获；原精确模式漏检
        let residual = output.range(of: #"<code[^>]*class="[^"]*language-mermaid"#,
                                    options: .regularExpression) != nil
        return MermaidTransformResult(html: output, needsJsFallback: residual)
    }

    /// 实体还原（&lt; &gt; &quot; &amp;）——Mermaid 源码含 < > 时 Down 已转义，需还原
    static func unescapeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&amp;", with: "&")   // 最后处理，避免二次转义
    }
}
