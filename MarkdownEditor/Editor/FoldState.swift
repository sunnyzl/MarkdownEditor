import Foundation

// FoldState.swift — Editor：会话级折叠区间管理 + 标题级别纯函数（Epic-6 批次 2，T2.1）
// 无 AppKit 依赖（仅 Foundation）：headingLevel / foldingRange / foldedRanges 为 nonisolated 纯函数，
// 可直接单测（NFR-032）；实例状态（folded）@MainActor 隔离，由编辑器会话持有。
// Session-scoped fold-range management; pure heading/fence helpers are unit-testable without AppKit.

/// 折叠区间（含端点，0 基行号）/ A fold range covering [startLine, endLine] (inclusive, 0-based)
struct FoldRange: Equatable {
    let startLine: Int
    let endLine: Int
}

/// 会话级折叠状态 / Session-scoped fold state
@MainActor
final class FoldState {

    /// 已折叠区间（按 startLine 升序、重叠合并归一化）/ Folded ranges, sorted and overlap-merged
    private(set) var folded: [FoldRange] = []

    // MARK: - 实例状态管理

    /// 切换指定行折叠状态：已折叠 → 展开（移除所在区间）；未折叠 → 折叠该行（追加单行区间并归一化）
    /// Toggle fold state: unfold the containing range, or fold the line as a singleton range.
    func toggle(line: Int) {
        if let idx = folded.firstIndex(where: { $0.startLine <= line && line <= $0.endLine }) {
            folded.remove(at: idx)
        } else {
            folded.append(FoldRange(startLine: line, endLine: line))
            folded = FoldState.foldedRanges(in: folded)
        }
    }

    /// 指定行是否位于任一折叠区间内 / Whether the line lies inside any folded range
    func isFolded(at line: Int) -> Bool {
        folded.contains { $0.startLine <= line && line <= $0.endLine }
    }

    /// 清空全部折叠区间（setTextProgrammatically 回填新文档时调用——换文档残留防护：
    /// 旧折叠区间指向新文档行号 → ▸ 错位残留/误折叠）
    /// Remove all folded ranges (called when programmatically backfilling a new document
    /// — stale ranges would misalign against the new document's line numbers).
    func removeAllFolds() {
        folded.removeAll()
    }

    // MARK: - 纯函数（nonisolated，可单测）

    /// 区间归一化：按 startLine 升序，重叠区间合并 / Sort by startLine and merge overlapping ranges
    nonisolated static func foldedRanges(in ranges: [FoldRange]) -> [FoldRange] {
        let sorted = ranges.sorted { $0.startLine < $1.startLine }
        var result: [FoldRange] = []
        for range in sorted {
            if let last = result.last, range.startLine <= last.endLine {
                result[result.count - 1] = FoldRange(startLine: last.startLine,
                                                     endLine: max(last.endLine, range.endLine))
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// 标题级别解析：行首空白后 `#{1,6}` 且后随空格或行尾 → 级别；否则 nil
    /// 复用 TextFormatting.setHeading 前缀语义（leading whitespace + 1...6 '#' + space or EOL）。
    /// CRLF 行尾（\r）在解析前剥离（评审 MINOR：\r 会使行尾判断失败）。
    nonisolated static func headingLevel(of line: String) -> Int? {
        var line = line
        if line.hasSuffix("\r") { line.removeLast() }
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        var hashCount = 0
        while idx < line.endIndex, line[idx] == "#" {
            hashCount += 1
            idx = line.index(after: idx)
        }
        guard hashCount > 0, hashCount <= 6 else { return nil }
        if idx == line.endIndex { return hashCount }
        guard line[idx] == " " else { return nil }
        return hashCount
    }

    /// 折叠区间计算：
    /// - H2/H3 行 → 从该行到下一个同级或更高级标题（level ≤ 当前）前一行；
    /// - 围栏行 → 围栏闭区间（开围栏到闭合围栏，闭合反引号数 ≥ 开围栏）；
    /// - 其余（非标题、H1、H4+、未闭合围栏、单行无内容）→ nil。
    /// 章节折叠前向扫描维护围栏状态，围栏内的标题样式行不参与终止判断。
    /// Folding range: section range for H2/H3, fenced interval for code fences, else nil.
    nonisolated static func foldingRange(for line: Int, in lines: [String]) -> FoldRange? {
        guard line >= 0, line < lines.count else { return nil }
        let current = lines[line]
        // 代码块围栏：开围栏行 → 第一个合法闭合围栏行（闭区间）
        if let fenceMark = foldingFenceOpenMark(of: current) {
            for end in (line + 1)..<lines.count {
                if let closingMark = foldingFenceCloseMark(of: lines[end]), closingMark >= fenceMark {
                    return FoldRange(startLine: line, endLine: end)
                }
            }
            return nil
        }
        // 仅 H2/H3 参与章节折叠；前向扫描维护围栏状态
        guard let level = headingLevel(of: current), level == 2 || level == 3 else { return nil }
        var end = line
        var inFence = false
        var fenceMark = 0
        while end + 1 < lines.count {
            let next = end + 1
            let nextLine = lines[next]
            if inFence {
                if let mark = foldingFenceCloseMark(of: nextLine), mark >= fenceMark {
                    inFence = false
                }
            } else {
                if let mark = foldingFenceOpenMark(of: nextLine) {
                    inFence = true
                    fenceMark = mark
                } else if let nextLevel = headingLevel(of: nextLine), nextLevel <= level {
                    break
                }
            }
            end = next
        }
        return end > line ? FoldRange(startLine: line, endLine: end) : nil
    }

    /// 反引号围栏开标记：行首空白后 ≥3 个反引号（允许后随 info string，如 ```swift）→ 返回反引号数
    nonisolated static func foldingFenceOpenMark(of line: String) -> Int? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        var count = 0
        while idx < line.endIndex, line[idx] == "`" { count += 1; idx = line.index(after: idx) }
        return count >= 3 ? count : nil
    }

    /// 反引号围栏闭标记：行首空白后 ≥3 个反引号且其后仅为空白或行尾 → 返回反引号数
    nonisolated static func foldingFenceCloseMark(of line: String) -> Int? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        var count = 0
        while idx < line.endIndex, line[idx] == "`" { count += 1; idx = line.index(after: idx) }
        guard count >= 3 else { return nil }
        guard idx == line.endIndex || line[idx] == " " || line[idx] == "\t" else { return nil }
        return count
    }
}
