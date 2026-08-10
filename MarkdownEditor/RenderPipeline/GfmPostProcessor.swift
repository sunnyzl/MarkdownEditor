import Foundation

// GfmPostProcessor.swift — GFM 能力后处理（S-011，FR-021~024）
// ⚠️ 第 9 轮事实修正：Down-gfm fork 无 GFM 扩展实现（源码验证），
// 方案 B（Swift 后处理）为预期路径；fork 仅承担 CommonMark 渲染
// ⚠️ 遗留 #6（批次 1）：表格边界收紧 — ⑥分隔行判定收紧（≥3 连字符 + 可选对齐冒号，
// 防 `| - |` 普通管道段落误转）；⑦对齐标记（:---: / ---: / :---）兼容且不泄漏输出；
// ⚠️ 修复（round4 T1.3，根因 4）：⑧body 行列数不一致 → 补齐空 cell（不再整行丢弃）
struct GfmPostProcessor {
    // 任务列表：<li>[ ] / [x] → checkbox（CommonMark 原样渲染文本，此步可靠）
    // ⚠️ fix（review T4.3）：分两阶段保留 checked 语义（FR-023 复选框渲染正确）——
    // [x]/[X] → checked；[ ] → 未勾选。两 pattern 互斥，顺序无关
    func processTaskLists(_ html: String) -> String {
        // ⚠️ 宽容化（Epic-6 T1.2）：<li[^>]*> 允许 sourcePos 属性（data-sourcepos）
        var out = html.replacingOccurrences(
            of: #"<li[^>]*>\[[xX]\] "#,
            with: #"<li class="task-list-item"><input type="checkbox" disabled checked> "#,
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"<li[^>]*>\[ \] "#,
            with: #"<li class="task-list-item"><input type="checkbox" disabled> "#,
            options: .regularExpression)
        return out
    }

    // 删除线：~~text~~ → <del>（CommonMark 原样渲染文本，此步可靠）
    func processStrikethrough(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"~~([^~]+?)~~"#,
            with: #"<del>$1</del>"#,
            options: .regularExpression)
    }

    // 表格：连续管道段落 → <table>（⚠️ 脆弱：代码块管道/转义管道/对齐标记需降级；
    // 验收以常见表格形态为准，FR-022 常见用例）
    // ⚠️ 第 11 轮重写：① pattern 用 [^<]* 允许段落内软换行；② 按段落切分；
    // ③ 任一步异常返回原文（不崩溃）
    // ⚠️ 第 12 轮修复（review T4.3）：④ matches 遍历处理【所有】表格块（原 range(of:)
    // 仅第一块，多表格文档后续表格不转）；⑤ rows[1] 全部 cell 含 "-" 才是分隔行
    func processTables(_ html: String) -> String {
        // ⚠️ 宽容化（Epic-6 T1.2）：<p[^>]*> 允许 sourcePos 属性（data-sourcepos）
        // ⚠️ 修复（round4 T1.3，根因 4）：正则放宽——[^<]* 遇行内标签（<code>/<a>）
        // 立即中断 → 整块匹配失败 → 含标签的表格不转。改 [\s\S]*?（非贪婪，允许任意
        // 字符）配合段落边界 </p>；连续 <p>|...|</p> 块仍由 + 整体匹配（多表格行为保持）
        let pattern = #"(<p[^>]*>\|[\s\S]*?\|</p>\n?)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: full)
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = html.startIndex
        for match in matches {
            guard let r = Range(match.range, in: html) else { continue }
            result += html[cursor..<r.lowerBound]
            let block = String(html[r])
            result += Self.tableHTML(block) ?? block   // 非表格形态 → 保留原文
            cursor = r.upperBound
        }
        result += html[cursor...]
        return result
    }

    /// 单块管道段落 → <table>；不满足表格形态（<2 行 / 无 GFM 分隔行 / 空表头）→ nil
    /// ⚠️ 遗留 #6（批次 1）：⑥分隔行判定收紧（≥3 连字符 + 可选对齐冒号，`| - |` 不再匹配）；
    /// ⑦对齐标记（:---: / ---: / :---）兼容（分隔行不输出，MVP 不输出 align 属性）
    /// ⚠️ 修复（round4 T1.3，根因 4）：⑧空单元格保留（omittingEmptySubsequences: false
    /// + 去行首伪影空、保留真实尾部空列——final-verification 修正）——修复前 split 默认省略
    /// 空子序列 → 表头空单元格列数错位 → body 全被 filter → tbody 空；⑨列数补齐——body 行
    /// 不足表头列数补空 cell（不再整行丢弃）
    private static func tableHTML(_ block: String) -> String? {
        var rows: [[String]] = []
        // ⚠️ 宽容化（Epic-6 T1.2）：<p[^>]*>\| 允许 sourcePos 属性（data-sourcepos）——
        // 字面量 "<p>|" 遇带属性段落失效；正则形态同时兼容带属性与无属性段落
        for paragraph in block.components(separatedBy: "</p>")
            where paragraph.range(of: #"<p[^>]*>\|"#, options: .regularExpression) != nil {
            let inner = paragraph.replacingOccurrences(
                of: #"<p[^>]*>\|"#, with: "", options: .regularExpression)
            for line in inner.split(separator: "\n") {
                let s = String(line)
                guard s.hasSuffix("|") else { continue }
                // ⚠️ 修复（round4 T1.3）：空单元格保留——omittingEmptySubsequences: false
                // 保留空 cell（表头/body 空单元格列数对齐）；行以 | 开头结尾 → split 产生
                // 首尾空串 → trim 剥离
                // ⚠️ 修复（round4 final-verification）：仅删除 removeLast（尾部空串剥离）——
                // dropLast 已消费每行行尾 | → split 尾部段即真实单元格，removeLast 会误剥
                // 真实尾部空列（例：表头 `| A | B |  |` 3 列尾空 → 误剥 → columnCount=2 →
                // body 行被 prefix 截断丢列）。removeFirst 必须保留：正则替换 <p[^>]*>\| 仅消费
                // 段落首行的行首 |，单段落表格后续行仍以 | 开头 → split 前导空串为伪影
                var cells = s.dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first?.isEmpty == true { cells.removeFirst() }
                if !cells.isEmpty { rows.append(cells) }
            }
        }
        guard rows.count >= 2 else { return nil }          // 至少表头 + 分隔行
        let header = rows[0]
        guard !header.isEmpty else { return nil }
        // GFM 分隔行判定（#6 收紧）：每个 cell 匹配 ≥3 连字符 + 可选对齐冒号（:---: / ---: / :---）。
        // 防普通管道段落/单连字符分隔误转（`| - |` 不再匹配；Down 探针确认该误转场景）
        guard rows[1].allSatisfy({
            $0.range(of: #"^\s*:?-{3,}:?\s*$"#, options: .regularExpression) != nil
        }) else { return nil }
        // ⚠️ 修复（round4 T1.3）：列数对齐——body 行不足表头列数 → 补齐空 cell 至表头列数
        //（不再整行丢弃，防空单元格错位导致 tbody 全空）；超出 → 截断至表头列数
        let columnCount = header.count
        let bodyRows = rows.dropFirst(2).map { row in
            row.count >= columnCount ? Array(row.prefix(columnCount)) : row + Array(repeating: "", count: columnCount - row.count)
        }

        func tr(_ row: [String], tag: String) -> String {
            "<tr>" + row.map { "<\(tag)>\($0)</\(tag)>" }.joined() + "</tr>"
        }
        let thead = "<thead>" + tr(header, tag: "th") + "</thead>"
        let tbody = bodyRows.isEmpty ? "" : "<tbody>" + bodyRows.map { tr($0, tag: "td") }.joined() + "</tbody>"
        return "<table>" + thead + tbody + "</table>"
    }

    func process(_ html: String) -> String {
        let t = processTables(processTaskLists(processStrikethrough(html)))
        // ⚠️ S-025：脚注链尾——定义行文本可能含表格/删除线标记，基于已转换 HTML；
        // autolink 最后——脚注区块内 URL 同样转链接（链序设计 §S-025）
        // ⚠️ Epic-6 T4.1（FR-028）：TOC 链尾——TOC 基于已后处理 HTML（标题含已转换行内标记可 strip），
        // 且 TOC 自身不含 URL 需转；无 [TOC] 段落时零副作用
        return processTOC(processAutolinks(processFootnotes(t)))
    }

    // ⚠️ S-025（FR-025）：脚注两阶段后处理（设计 §S-025；Down fork 无脚注扩展）
    // ① 收集定义（独立 <p> 段形态；未引用定义也收集，编号按文档出现顺序）
    // ② 删除定义原文（正文不显示；区块统一承载）——删除后再替换引用，定义行 [^id] 天然不误替换
    // ③ 替换引用 [^id] → <sup class="footnote-ref">[n]</sup>（孤儿引用原样保留）
    // ④ 文末追加 <section class="footnotes"><ol> 区块
    // 容错：正则异常/无定义 → 原样返回（不崩溃）；定义含已转换 HTML（<del>/<a>/<table>）经 (?s) 非贪婪支持；跨段定义 MVP 不支持（记录限制）
    func processFootnotes(_ html: String) -> String {
        guard let defRegex = try? NSRegularExpression(
            pattern: #"(?s)<p[^>]*>\[\^([^\]]+)\]:\s*(.*?)</p>"#) else { return html }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        let defs = defRegex.matches(in: html, range: full)
        guard !defs.isEmpty else { return html }
        var order: [String] = []
        var definitions: [String: String] = [:]
        for m in defs {
            guard let idRange = Range(m.range(at: 1), in: html),
                  let bodyRange = Range(m.range(at: 2), in: html) else { continue }
            let id = String(html[idRange])
            // ⚠️ 修复（T1.2 实测锁定）：definitions 仅在首次赋值——原计划代码无条件覆盖导致
            // 重复定义"最后一个生效"，与计划语义"首个生效（GFM 语义）"矛盾
            //（testFootnoteRepeatedDefinitionFirstWins 锁定）；order 判重保证编号唯一
            if definitions[id] == nil {
                order.append(id)   // 重复定义：首个生效（GFM 语义）
                definitions[id] = String(html[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var out = html
        for m in defs.reversed() {                            // 逆序删除防 range 漂移
            guard let r = Range(m.range, in: out) else { continue }
            out.removeSubrange(r)
        }
        guard let refRegex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\](?!\()"#) else { return out }
        // ⚠️ P2（backlog）：引用替换前 code/a 区间 token 保护（autolink :171-226 对称）——
        // 脚注引用语法在 <code>/<a> 内原样保留（例：<code>[^1]</code> 不替换为 sup）
        var protected = out
        var tokens: [String] = []
        let tokenBase = 0xE100   // 与 autolink 的 0xE000 错开（两处保护不同时活跃，防理论冲突）
        if let protectRegex = try? NSRegularExpression(
            pattern: #"(?s)<a\b[^>]*>.*?</a>|<pre[^>]*><code[^>]*>.*?</code></pre>|<code[^>]*>.*?</code>"#) {
            let fullRange = NSRange(protected.startIndex..<protected.endIndex, in: protected)
            for m in protectRegex.matches(in: protected, range: fullRange).reversed() {
                guard let r = Range(m.range, in: protected) else { continue }
                tokens.append(String(protected[r]))
                let token = String(UnicodeScalar(tokenBase + tokens.count - 1)!)
                protected.replaceSubrange(r, with: token)
            }
        }
        var numbers: [String: Int] = [:]
        let outNS = NSMutableString(string: protected)
        let refRange = NSRange(protected.startIndex..<protected.endIndex, in: protected)
        for m in refRegex.matches(in: protected, range: refRange).reversed() {
            guard let idRange = Range(m.range(at: 1), in: protected) else { continue }
            let id = String(protected[idRange])
            guard let orderIndex = order.firstIndex(of: id) else { continue }   // 孤儿引用原样保留
            let number = numbers[id] ?? (orderIndex + 1)
            numbers[id] = number
            outNS.replaceCharacters(in: m.range, with: "<sup class=\"footnote-ref\">[\(number)]</sup>")
        }
        var result = outNS as String
        for (i, segment) in tokens.enumerated().reversed() {   // 恢复 token（PUA 唯一性保证精确命中）
            result = result.replacingOccurrences(of: String(UnicodeScalar(tokenBase + i)!), with: segment)
        }
        guard !order.isEmpty else { return result }
        let items = order.enumerated().map { index, id in
            "<li id=\"fn-\(index + 1)\">\(definitions[id] ?? "")</li>"
        }.joined()
        result += "<section class=\"footnotes\"><ol>\(items)</ol></section>"
        return result
    }

    // ⚠️ S-025（FR-026）：裸 URL 自动链接（负向排除 <code>/<a> 上下文；token 保护 + 负向断言）
    // ⚠️ UNVERIFIED 假设 #2：token 保护法为 planner 决策（ICU 无变长 lookbehind，区间排除
    // 用 PUA 占位符最稳）；implementer 以本文件测试锁定行为，若实测正则语义不符可调整
    func processAutolinks(_ html: String) -> String {
        guard let protectRegex = try? NSRegularExpression(
            pattern: #"(?s)<a\b[^>]*>.*?</a>|<pre[^>]*><code[^>]*>.*?</code></pre>|<code[^>]*>.*?</code>"#) else { return html }
        guard let urlRegex = try? NSRegularExpression(
            pattern: #"(?<![""'=])https?://[^\s<>"']+"#) else { return html }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        // ① token 保护：已有链接区间 / 行内代码 / 代码块 → PUA 单字符占位（Down 输出不含 PUA → 唯一）
        var tokens: [String] = []
        let tokenBase = 0xE000
        var protected = html
        for m in protectRegex.matches(in: html, range: full).reversed() {
            guard let r = Range(m.range, in: html) else { continue }
            let segment = String(html[r])
            tokens.append(segment)
            let token = String(UnicodeScalar(tokenBase + tokens.count - 1)!)
            protected.replaceSubrange(r, with: token)
        }
        // ② 裸 URL 替换（token 内不匹配——PUA 非 URL 字符）
        // ⚠️ MINOR #10：尾随标点剥离——. , ; : ! ? ) ] } 结尾剔除，防 "https://a.com)." 整段括入链接；
        // 剥离的标点保留在原文（replace 仅覆盖剥离后 range）；ASCII 标点均为单 UTF-16 单元 → 长度差精确
        let out = NSMutableString(string: protected)
        let urlRange = NSRange(protected.startIndex..<protected.endIndex, in: protected)
        for m in urlRegex.matches(in: protected, range: urlRange).reversed() {
            guard let r = Range(m.range, in: protected) else { continue }
            let matched = String(protected[r])
            let punct = CharacterSet(charactersIn: ".,;:!?)]}")
            var stripped = matched
            var strippedUTF16 = 0
            while let last = stripped.unicodeScalars.last, punct.contains(last) {
                // ⚠️ 修复（review cycle 1）：成对括号保护——URL 内存在配对开括号时
                // 不剥离闭合括号（https://en.wikipedia.org/wiki/Foo_(bar) 完整保留）；
                // 失衡括号（https://example.com). 无配对 (）仍剥离（MINOR #10 原语义保持）
                if (last == ")" && stripped.contains("("))
                    || (last == "]" && stripped.contains("["))
                    || (last == "}" && stripped.contains("{")) {
                    break
                }
                stripped.removeLast()
                strippedUTF16 += 1
            }
            guard !stripped.isEmpty else { continue }
            let url = stripped
            let newRange = NSRange(location: m.range.location, length: m.range.length - strippedUTF16)
            out.replaceCharacters(in: newRange, with: "<a href=\"\(url)\">\(url)</a>")
        }
        // ③ 恢复 token（PUA 唯一性保证 replace 精确命中）
        var result = out as String
        for (i, segment) in tokens.enumerated().reversed() {
            let token = String(UnicodeScalar(tokenBase + i)!)
            result = result.replacingOccurrences(of: token, with: segment)
        }
        return result
    }

    // ⚠️ Epic-6 批次 4 T4.1（FR-028）：TOC 生成——[TOC] 占位替换为目录
    //（标题收集 + 自生成 id toc-N——cmark 无标题 id；折叠语义：TOC 文本 strip 行内标签）
    // ① 识别 <p[^>]*>\[TOC\]</p> 段落（无 → 原样返回，零副作用：标题不加 id）
    // ② 收集 <h([1-6])[^>]*>(.*?)</h\1> 标题（宽容 sourcePos 属性；id 按文档顺序 toc-N）
    // ③ 生成 <div class="toc"><ul><li><a href="#toc-N">层级嵌套（首标题定基准层级，更深级别开嵌套 <ul>）
    // ④ 标题元素补 id + [TOC] 段落替换（编辑逆序应用防 range 漂移）
    func processTOC(_ html: String) -> String {
        // ① [TOC] 段落检测：无 → 原样返回（标题不加 id）
        let tocPattern = #"<p[^>]*>\[TOC\]</p>"#
        guard let tocRegex = try? NSRegularExpression(pattern: tocPattern) else { return html }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let tocMatches = tocRegex.matches(in: html, range: fullRange)
        guard !tocMatches.isEmpty else { return html }

        // ② 标题收集：h1-h6，文本 strip 行内标签（strong/em 等保纯文本）
        let headingPattern = #"<h([1-6])[^>]*>(.*?)</h\1>"#
        guard let headingRegex = try? NSRegularExpression(pattern: headingPattern) else { return html }
        let headingMatches = headingRegex.matches(in: html, range: fullRange)
        var levels: [Int] = []
        var texts: [String] = []
        for m in headingMatches {
            guard let levelRange = Range(m.range(at: 1), in: html),
                  let textRange = Range(m.range(at: 2), in: html),
                  let level = Int(String(html[levelRange])) else { continue }
            let raw = String(html[textRange])
            let plain = raw.replacingOccurrences(
                of: #"<[^>]+>"#, with: "", options: .regularExpression)
            levels.append(level)
            texts.append(plain)
        }

        // ③ 生成 TOC 列表（层级嵌套：首标题定基准层级，更深级别开嵌套 <ul>）
        var toc: String
        if levels.isEmpty {
            toc = "<div class=\"toc\"></div>"   // 容错：仅 [TOC] 无标题 → 空目录
        } else {
            var builder = "<div class=\"toc\"><ul>"
            var currentLevel = 1
            var openULs = 1
            for (index, level) in levels.enumerated() {
                let link = "<a href=\"#toc-\(index + 1)\">\(texts[index])</a>"
                if index == 0 {
                    builder += "<li>\(link)"        // 首标题：根 <ul> 直挂
                    currentLevel = level
                } else if level > currentLevel {
                    for _ in currentLevel..<level {   // 更深：逐级开嵌套 <ul>（级别跳级补空 ul）
                        builder += "<ul>"
                        openULs += 1
                    }
                    builder += "<li>\(link)"
                    currentLevel = level
                } else if level == currentLevel {
                    builder += "</li><li>\(link)"    // 同级：关旧开新
                } else {
                    while currentLevel > level && openULs > 1 {   // 变浅：逐级收嵌套
                        builder += "</li></ul>"
                        openULs -= 1
                        currentLevel -= 1
                    }
                    builder += "</li><li>\(link)"
                    currentLevel = level
                }
            }
            // ⚠️ 已知限制：跳级嵌套（≥2 级跳变，如 H1→H3）会产生多余 </li>，浏览器按 HTML5 规则忽略，DOM 嵌套仍正确（T4.1 review 豁免记录）
            for _ in 0..<openULs { builder += "</li></ul>" }
            builder += "</div>"
            toc = builder
        }

        // ④ 编辑逆序应用防 range 漂移：标题开标签注入 id + [TOC] 段落替换
        let ns = html as NSString
        var edits: [(NSRange, String)] = []
        for (index, m) in headingMatches.enumerated() {
            let openEnd = ns.range(of: ">", options: [], range: m.range).location
            guard openEnd != NSNotFound, openEnd > m.range.location else { continue }
            // 零长插入：id 注入到开标签 ">" 之前（保留原标签，仅补属性）
            let insertRange = NSRange(location: openEnd, length: 0)
            edits.append((insertRange, " id=\"toc-\(index + 1)\""))
        }
        for m in tocMatches {
            edits.append((m.range, toc))
        }
        let out = NSMutableString(string: html)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: range, with: replacement)
        }
        return out as String
    }
}
