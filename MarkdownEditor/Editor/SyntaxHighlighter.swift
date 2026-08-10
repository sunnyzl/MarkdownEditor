import AppKit
import Highlightr

// SyntaxHighlighter.swift — 编辑器内语法高亮（S-023，FR-003，设计 §4 方案 A）
// Highlightr 封装：① markdown 全文高亮 → ② 代码围栏区间（```lang）替换为语言高亮 →
// 拼接 NSAttributedString → textStorage（属性编辑不触发 didChangeNotification → 无循环 ✅）
// 450ms 独立 debounce（与渲染管线解耦）；light→github-gist / dark→github-dark（AD-8 双轨同名主题）；
// 开关 UserDefaults syntaxHighlightEnabled（FR-108，默认开启）；Highlightr 失败 → 内部降级
// 纯文本路径（NFR-012 精神，不崩溃）
// Wraps Highlightr: markdown full-text highlight → fence-range language highlight replacement;
// 450ms debounce; theme mapping; UserDefaults switch (default on); graceful degradation.
@MainActor
final class SyntaxHighlighter {
    static let enabledKey = "syntaxHighlightEnabled"

    /// 开关读取（FR-108）：默认开启（FR-003 功能卖点，设计 §9 Open Question 定稿）
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// 当前主题名（light → "github-gist" / dark → "github-dark"；测试断言用）
    private(set) var currentThemeName = "github-gist"

    private let defaults: UserDefaults
    private let highlightClosure: ((String, String) -> NSAttributedString?)?
    private let debounceInterval: TimeInterval
    private var engine: Highlightr?        // 生产引擎（Highlightr() 失败 → nil → 降级）
    private var pendingWorkItem: DispatchWorkItem?
    private var scheduleVersion = 0        // 过期结果守卫（debounce 竞争防串位）

    /// - Parameters:
    ///   - defaults: UserDefaults 注入（测试 suite 注入）
    ///   - highlightClosure: 高亮函数注入（测试 Mock；nil → 生产 Highlightr）
    ///   - debounceInterval: debounce 间隔（测试缩短；生产 450ms，设计 §4）
    init(defaults: UserDefaults = .standard,
         highlightClosure: ((String, String) -> NSAttributedString?)? = nil,
         debounceInterval: TimeInterval = 0.45) {
        self.defaults = defaults
        self.highlightClosure = highlightClosure
        self.debounceInterval = debounceInterval
        if highlightClosure == nil {
            if let engine = Highlightr() {
                self.engine = engine
                // ⚠️ light 默认 github-gist——Highlightr 2.3.0 stripTheme 正则不解析复合选择器
                // （如 .hljs-keyword.hljs-atrule），github light 主题关键规则丢失 → 单色渲染；
                // POC-S-005 已验证 github-gist（零复合选择器，多色输出）
                // Light default is github-gist — Highlightr 2.3.0 stripTheme regex cannot parse
                // compound selectors, github light theme colors are broken; POC-S-005 verified github-gist.
                _ = engine.setTheme(to: "github-gist")
            } else {
                // 失败降级（NFR-012 精神）：禁用标志，走 recolor 纯文本路径，不崩溃
                NSLog("[Editor] highlight disabled: Highlightr init failed")
            }
        }
    }

    var isHighlightingEnabled: Bool { Self.isEnabled(defaults: defaults) }

    /// 主题映射（AD-8：与预览侧 highlight.js 共用同名主题 github-gist / github-dark）
    func setTheme(_ mode: ThemeMode) {
        currentThemeName = mode == .dark ? "github-dark" : "github-gist"
        guard let engine else { return }
        // ⚠️ 审查修复（MINOR #6，兑现 plan-index 风险表承诺）：github-dark 主题名不兼容时
        // 回退 POC-S-005 已验证的 github-gist（setTheme 返回 Bool = 是否成功）；light 分支
        // 直接使用已验证主题（github light 因 Highlightr 2.3.0 stripTheme 正则不解析复合
        // 选择器而颜色损坏 → 已映射 github-gist，非回退路径）
        // Review fix (MINOR #6, plan risk-table commitment): fall back to POC-S-005-verified
        // github-gist when theme name is incompatible (setTheme returns Bool); light branch uses
        // the verified theme directly (github light is broken under Highlightr 2.3.0 stripTheme).
        if !engine.setTheme(to: currentThemeName) {
            _ = engine.setTheme(to: "github-gist")
        }
    }

    /// 同步立即高亮（主题切换重放入口 + 测试用）
    func highlightNow(_ text: String) -> NSAttributedString? { highlight(text) }

    /// 450ms debounce 调度：输入瞬间先 recolor 过渡色，停笔后高亮覆盖（设计 §4）；
    /// hasMarkedText 由调用方延后（IME 安全）；version 守卫丢弃过期结果
    func scheduleHighlight(_ text: String, completion: @escaping (NSAttributedString?) -> Void) {
        scheduleVersion += 1
        let capturedVersion = scheduleVersion
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.scheduleVersion == capturedVersion else { return }   // 过期结果丢弃
                completion(self.highlight(text))
            }
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    func cancelPending() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    // MARK: - 双层高亮（设计 §4 方案 A：markdown 全文 → 围栏语言替换）

    private func highlight(_ text: String) -> NSAttributedString? {
        guard isHighlightingEnabled, !text.isEmpty else { return nil }
        let base = highlightClosure?(text, "markdown") ?? engine?.highlight(text, as: "markdown")
        guard let base else { return nil }
        return applyFenceLanguages(to: base, text: text)
    }

    /// ② 围栏区间替换：从后往前替换（offset 不失效）；语言高亮失败 → 保留 markdown 层
    private func applyFenceLanguages(to base: NSAttributedString, text: String) -> NSAttributedString? {
        let fences = parseFences(text)
        guard !fences.isEmpty else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        for fence in fences.reversed() {
            guard let highlighted = highlightClosure?(fence.code, fence.language)
                    ?? engine?.highlight(fence.code, as: fence.language) else { continue }
            result.replaceCharacters(in: fence.range, with: highlighted)
        }
        return result
    }

    // MARK: - 围栏解析（按行扫描 ``` 开闭对；未闭合容错——剩余按 markdown，设计 §6）

    private struct Fence {
        let range: NSRange    // 代码内容区间（不含 ``` 标记行）/ code content range
        let language: String  // 语言标记（空 → markdown）/ language tag
        let code: String      // 代码内容 / code content
    }

    private func parseFences(_ text: String) -> [Fence] {
        let ns = text as NSString
        var result: [Fence] = []
        var lines: [(range: NSRange, content: String)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byLines) { substring, range, _, _ in
            if let substring { lines.append((range, substring)) }
        }
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].content.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { i += 1; continue }
            // 语言标记：``` 后首个空白分隔词；空 → markdown
            let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let language = tag.isEmpty ? "markdown" : String(tag.split(separator: " ").first ?? "markdown")
            // 找闭合行
            var j = i + 1
            while j < lines.count,
                  !lines[j].content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                j += 1
            }
            guard j < lines.count else { break }   // 未闭合容错：剩余按 markdown
            // 代码内容 = (i+1) 行起点 ~ j 行起点（去尾换行）
            let contentStart = lines[i + 1].range.location
            var contentEnd = lines[j].range.location
            var length = contentEnd - contentStart
            if length > 0, ns.character(at: contentEnd - 1) == 0x0A { length -= 1 }   // 去尾换行
            let codeRange = NSRange(location: contentStart, length: length)
            result.append(Fence(range: codeRange, language: language,
                                code: ns.substring(with: codeRange)))
            i = j + 1
        }
        return result
    }
}
