import Foundation

// TextFormatting.swift — Markdown 文本变换纯函数集（S-021/S-022，AC-FR-051~064）
// 无 AppKit 依赖（仅 Foundation NSRange），可直接单测（NFR-032）。
// Result 携带 editRange + replacement（替换区间语义），供 NSText 原生编辑
// shouldChangeText + replaceCharacters 使用 → didChange 自动驱动渲染管线，undo 自动进栈
// Pure-function Markdown transformations; Result carries editRange + replacement so
// NSText's native edit path (shouldChangeText + replaceCharacters) applies the change.
enum TextFormatting {

    /// 变换结果 / Transformation result
    struct Result: Equatable {
        let text: String        // 变换后全文 / full text after transformation
        let editRange: NSRange  // 实际编辑区间（包裹=原选区；行级=行区间）/ edit range
        let replacement: String // 替换 editRange 的字符串 / replacement for editRange
        let selection: NSRange  // 变换后选区（光标或选中）/ selection after transformation
    }

    // MARK: - 命令映射（MarkdownTextView.performFormatting 薄壳调用入口）

    /// 命令 → 文本变换；.togglePane 布局命令返回 nil（不经文本变换）
    static func format(_ text: String, range: NSRange, command: EditorCommand) -> Result? {
        switch command {
        case .bold: return wrap(text, range: range, prefix: "**", suffix: "**", placeholder: "粗体文本")
        case .italic: return wrap(text, range: range, prefix: "*", suffix: "*", placeholder: "斜体文本")
        case .inlineCode: return wrap(text, range: range, prefix: "`", suffix: "`", placeholder: "code")
        case .codeBlock: return wrap(text, range: range, prefix: "```\n", suffix: "\n```", placeholder: "code")
        case .link: return wrap(text, range: range, prefix: "[", suffix: "](url)", placeholder: "链接文字")
        case .image: return wrap(text, range: range, prefix: "![", suffix: "](url)", placeholder: "图片描述")
        case .heading1: return setHeading(text, range: range, level: 1)
        case .heading2: return setHeading(text, range: range, level: 2)
        case .heading3: return setHeading(text, range: range, level: 3)
        case .heading4: return setHeading(text, range: range, level: 4)
        case .heading5: return setHeading(text, range: range, level: 5)
        case .heading6: return setHeading(text, range: range, level: 6)
        case .table: return insertTable(text, range: range)
        case .taskList: return insertLinePrefix(text, range: range, prefix: "- [ ] ")
        case .mathInline: return wrap(text, range: range, prefix: "$", suffix: "$", placeholder: "公式")
        case .mathBlock: return wrap(text, range: range, prefix: "$$\n", suffix: "\n$$", placeholder: "公式")
        case .blockquote: return insertLinePrefix(text, range: range, prefix: "> ")
        case .strikethrough: return wrap(text, range: range, prefix: "~~", suffix: "~~", placeholder: "删除线文本")
        case .togglePane: return nil   // 布局命令 / layout command
        }
    }

    // MARK: - 包裹类（粗体/斜体/行内代码/代码块/链接/图片/公式/删除线）

    /// 包裹/去包裹（toggle）：有选区 → prefix+选中+suffix；已含完整标记 → 去标记（保留内部选区）；
    /// 空选区 → 插入 prefix+placeholder+suffix，光标落于 placeholder 之后
    static func wrap(_ text: String, range: NSRange, prefix: String, suffix: String, placeholder: String) -> Result {
        let ns = text as NSString
        let nsPrefix = prefix as NSString
        let nsSuffix = suffix as NSString
        let nsPlaceholder = placeholder as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        let editRange = NSRange(location: location, length: length)

        if length == 0 {
            // 空选区：插入标记对 + placeholder，光标居中
            let replacement = prefix + placeholder + suffix
            let newText = ns.replacingCharacters(in: editRange, with: replacement)
            let cursor = location + nsPrefix.length + nsPlaceholder.length
            return Result(text: newText, editRange: editRange, replacement: replacement,
                          selection: NSRange(location: cursor, length: 0))
        }

        let selected = ns.substring(with: editRange)
        // toggle：已包裹 → 去包裹（内部选区保留）
        if selected.hasPrefix(prefix), selected.hasSuffix(suffix),
           selected.utf16.count >= nsPrefix.length + nsSuffix.length {
            let innerLength = selected.utf16.count - nsPrefix.length - nsSuffix.length
            let inner = (selected as NSString).substring(with: NSRange(location: nsPrefix.length, length: innerLength))
            return Result(text: ns.replacingCharacters(in: editRange, with: inner), editRange: editRange,
                          replacement: inner, selection: NSRange(location: location, length: innerLength))
        }

        // 包裹 / wrap
        let wrapped = prefix + selected + suffix
        return Result(text: ns.replacingCharacters(in: editRange, with: wrapped), editRange: editRange,
                      replacement: wrapped, selection: NSRange(location: location, length: wrapped.utf16.count))
    }

    // MARK: - 行首前缀（引用/任务列表，多行支持）

    /// 行首前缀插入/移除（toggle）：按选区覆盖的完整行逐行处理（空选区 → 光标所在行）
    static func insertLinePrefix(_ text: String, range: NSRange, prefix: String) -> Result {
        let ns = text as NSString
        let nsPrefix = prefix as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        let firstLine = lineRange(of: ns, containing: location)
        let lastLineEnd: Int
        if length == 0 {
            lastLineEnd = firstLine.location + firstLine.length
        } else {
            let lastLine = lineRange(of: ns, containing: location + length - 1)
            lastLineEnd = lastLine.location + lastLine.length
        }
        // 行区间扩展：选区覆盖的完整行范围
        let editRange = NSRange(location: firstLine.location, length: lastLineEnd - firstLine.location)
        let block = ns.substring(with: editRange)
        let lines = block.components(separatedBy: "\n")
        let transformed = lines.map { line -> String in
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(nsPrefix.length))   // 去前缀 / strip prefix
            }
            return prefix + line                                  // 加前缀 / add prefix
        }
        let replacement = transformed.joined(separator: "\n")

        let selection: NSRange
        if length == 0 {
            // 光标映射：前缀增减 → 光标平移（clamp 到编辑块内）
            let hadPrefix = (ns.substring(with: firstLine) as NSString).hasPrefix(prefix)
            let delta = hadPrefix ? -nsPrefix.length : nsPrefix.length
            let newCursor = min(max(location + delta, editRange.location),
                                editRange.location + (replacement as NSString).length)
            selection = NSRange(location: newCursor, length: 0)
        } else {
            // 有选区：选中整个变换块（逐行前缀可能改变行宽）
            selection = NSRange(location: editRange.location, length: (replacement as NSString).length)
        }

        return Result(text: ns.replacingCharacters(in: editRange, with: replacement),
                      editRange: editRange, replacement: replacement, selection: selection)
    }

    // MARK: - 标题层级（H1~H6）

    /// 行首标题设置/移除（toggle）：无标题 → 设为目标 level（保留缩进）；同 level → 移除；异 level → 调整
    static func setHeading(_ text: String, range: NSRange, level: Int) -> Result {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let line = lineRange(of: ns, containing: location)
        let lineContent = ns.substring(with: line)
        let lc = lineContent as NSString

        // 行首空白偏移 / leading whitespace offset
        var contentStart = 0
        while contentStart < lc.length {
            let ch = lc.character(at: contentStart)
            if ch == 0x20 || ch == 0x09 { contentStart += 1 } else { break }
        }
        // 解析已有 heading（# 序列后跟空格或行尾）
        var hashCount = 0
        var idx = contentStart
        while idx < lc.length, lc.character(at: idx) == 0x23 { hashCount += 1; idx += 1 }   // '#'
        let isHeading = hashCount > 0 && hashCount <= 6
            && (idx == lc.length || lc.character(at: idx) == 0x20)

        let headingPrefix = String(repeating: "#", count: level) + " "
        let leading = lc.substring(to: contentStart)

        let replacement: String
        if isHeading {
            // 标记后内容（跳过 '#' 序列与随后的单个空格）
            var after = idx
            if after < lc.length, lc.character(at: after) == 0x20 { after += 1 }
            let content = lc.substring(from: after)
            if hashCount == level {
                replacement = leading + content                        // 同 level → 移除（toggle）
            } else {
                replacement = leading + headingPrefix + content        // 异 level → 调整
            }
        } else {
            replacement = leading + headingPrefix + lc.substring(from: contentStart)   // 插入
        }

        // 光标：行内容起点（标记之后）
        let cursorOffset = contentStart + (isHeading && hashCount == level ? 0 : headingPrefix.utf16.count)
        return Result(text: ns.replacingCharacters(in: line, with: replacement), editRange: line,
                      replacement: replacement,
                      selection: NSRange(location: line.location + cursorOffset, length: 0))
    }

    // MARK: - 表格（FR-058）

    /// 光标处插入 3x3 表格模板，光标定位第一个单元格
    static func insertTable(_ text: String, range: NSRange) -> Result {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let replacement = "| 列 1 | 列 2 | 列 3 |\n| --- | --- | --- |\n|  |  |  |"
        let editRange = NSRange(location: location, length: 0)
        let newText = ns.replacingCharacters(in: editRange, with: replacement)
        let cursor = location + "| ".utf16.count   // 第一行第一个单元格内容起点
        return Result(text: newText, editRange: editRange, replacement: replacement,
                      selection: NSRange(location: cursor, length: 0))
    }

    // MARK: - 图片拖拽（FR-056：路径 → Markdown 图片语法）

    /// 图片路径 → Markdown 图片语法（FR-056 拖拽插入；纯函数无副作用）
    /// alt = 文件名去扩展名（lastPathComponent 剥离目录；deletingPathExtension 仅去末扩展名）；
    /// 路径 Markdown URL 转义（空格/括号/百分号 → 百分号编码——Down/CMark 渲染时 URL 解码还原；
    /// 防空格破坏 URL 语义、括号截断链接）
    static func imageMarkdown(path: String) -> String {
        let alt = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let escaped = path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return "![\(alt)](\(escaped))"
    }

    // MARK: - 辅助 / Helpers

    /// 包含 location 的完整行区间（不含行终止符）
    private static func lineRange(of ns: NSString, containing location: Int) -> NSRange {
        var start = min(max(location, 0), ns.length)
        while start > 0, ns.character(at: start - 1) != 0x0A { start -= 1 }
        var end = min(max(location, 0), ns.length)
        while end < ns.length, ns.character(at: end) != 0x0A { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
