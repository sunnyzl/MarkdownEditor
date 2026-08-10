import Foundation

// SourceMapParser.swift — data-sourcepos 解析纯函数（T1.3，Epic-6 批次 1）
// 无 AppKit 依赖，可独立 XCTest；供 ScrollSync v2（S-032）source map 行→块查找复用
// 语义：命中块内行 / 块间空白定位下一块 / 文档尾部 nil / 空数组 nil
// 源码位置（1-based，与 Down 的 data-sourcepos 语义一致：line:col-line:col）
// 顶层 struct（计划锁定）：供 SourceMapParser 及 ScrollSync v2 复用
struct SourcePos: Equatable {
    let startLine: Int
    let startCol: Int
    let endLine: Int
    let endCol: Int
}

struct SourceMapParser {
    /// 解析单个 data-sourcepos attribute 值（"line:col-line:col"）→ SourcePos
    /// 锚定完整匹配（^...$）：空串 / 垃圾 / 残缺值 / 多余段 → nil
    static func parse(_ attribute: String) -> SourcePos? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+):(\d+)-(\d+):(\d+)$"#) else { return nil }
        let full = NSRange(attribute.startIndex..<attribute.endIndex, in: attribute)
        guard let match = regex.firstMatch(in: attribute, range: full),
              let r1 = Range(match.range(at: 1), in: attribute),
              let r2 = Range(match.range(at: 2), in: attribute),
              let r3 = Range(match.range(at: 3), in: attribute),
              let r4 = Range(match.range(at: 4), in: attribute),
              let startLine = Int(attribute[r1]),
              let startCol = Int(attribute[r2]),
              let endLine = Int(attribute[r3]),
              let endCol = Int(attribute[r4]) else { return nil }
        return SourcePos(startLine: startLine, startCol: startCol, endLine: endLine, endCol: endCol)
    }

    /// 遍历 HTML 中所有 data-sourcepos="..." 匹配 → 文档顺序 SourcePos 数组
    /// 无法解析的值（如空 attribute）经 parse 过滤为 nil，不破坏顺序
    static func parseAll(in html: String) -> [SourcePos] {
        guard let regex = try? NSRegularExpression(pattern: #"data-sourcepos="([^"]*)""#) else { return [] }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: full).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: html) else { return nil }
            return parse(String(html[valueRange]))
        }
    }

    /// 行 → 块查找：
    /// ① startLine ≤ line ≤ endLine → 命中该块；
    /// ② 否则（块间空白 / 首个块前）→ 返回 startLine 最近的下一个块（startLine > line 的最小者）；
    /// ③ line 大于所有块 endLine 且无下一个块 → nil；blocks 为空 → nil
    static func findBlock(containing line: Int, in blocks: [SourcePos]) -> SourcePos? {
        let sorted = blocks.sorted { $0.startLine < $1.startLine || ($0.startLine == $1.startLine && $0.startCol < $1.startCol) }
        for block in sorted where line >= block.startLine && line <= block.endLine {
            return block
        }
        return sorted.first { $0.startLine > line }
    }
}
