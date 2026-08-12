import Foundation

// MathBlockProtector.swift — $$...$$ 块级公式 Down 前置保护
// 根因（真机验收）：cmark 把"独立 = 行"解析为 setext 标题下划线 → 多行 $$ 块被拆成
// <h1>+<p> 两段 → $$ 分属两个元素 → KaTeX auto-render 无法跨元素匹配 → 原文残留；
// 同时 cmark 反斜杠转义折叠 \\ → \，KaTeX 行分隔符丢失（静默 1×N 错版）。
// 方案：渲染前把 $$...$$ 块替换为 PUA 单字符 token（0xE200+，与 GfmPostProcessor
// 0xE000/0xE100 错开）→ cmark 不"看见"块内内容（= 行不触发 setext，\\ 不折叠）→
// 渲染后还原为 HTML 转义原文（& → &amp;；\ 字面保留——HTML 中 \ 非特殊字符）
// 块内 \\\\（4 个，为 cmark 折叠预转义的写法）→ \\（2 个，KaTeX 行分隔符），
// 保证 comprehensive.md 既有输出零回归；\\（2 个）原样保留
struct MathBlockProtector {
    static let mathPattern = #"\$\$[\s\S]*?\$\$"#   // 非贪婪；单 $ 与 \(...\) 不触及

    static func protect(_ markdown: String) -> (text: String, blocks: [String]) {
        guard let regex = try? NSRegularExpression(pattern: mathPattern) else {
            return (markdown, [])
        }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var blocks: [String] = []
        var out = ""
        var last = 0
        for m in regex.matches(in: markdown, range: full) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var block = ns.substring(with: m.range)
            while block.contains("\\\\\\\\") {          // \\\\ → \\（KaTeX 行分隔符）
                block = block.replacingOccurrences(of: "\\\\\\\\", with: "\\\\")
            }
            blocks.append(block)
            out += String(UnicodeScalar(0xE200 + blocks.count - 1)!)   // PUA token
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, blocks)
    }

    static func restore(_ html: String, blocks: [String]) -> String {
        var out = html
        for (i, block) in blocks.enumerated() {
            let token = String(UnicodeScalar(0xE200 + i)!)
            let escaped = block
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            out = out.replacingOccurrences(of: token, with: escaped)
        }
        return out
    }
}
