import Foundation

// FindEngine.swift — 查找/替换纯函数引擎（S-029，FR-002：Cmd+F/G/Shift+G + 正则开关）
// 无 AppKit 依赖（仅 Foundation NSRange）可直接单测（TextFormatting 先例）
// 普通匹配：NSString.range(of:) 循环收集；正则匹配：NSRegularExpression
// 非法正则 → 返回 error 字段（设计 §错误处理：提示 + 不崩溃）
enum FindEngine {

    /// 匹配结果（ranges 为空 + error 非 nil = 非法正则）
    struct MatchResult {
        let ranges: [NSRange]
        let error: String?
    }

    /// 全量匹配范围（普通/正则；大小写开关）
    static func matches(in text: String, query: String,
                        isRegularExpression: Bool, caseSensitive: Bool) -> MatchResult {
        guard !query.isEmpty else { return MatchResult(ranges: [], error: nil) }
        if isRegularExpression {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            do {
                let regex = try NSRegularExpression(pattern: query, options: options)
                let ns = text as NSString
                let ranges = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                    .map(\.range)
                return MatchResult(ranges: ranges, error: nil)
            } catch {
                return MatchResult(ranges: [], error: "正则表达式无效：\(error.localizedDescription)")
            }
        }
        let ns = text as NSString
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var ranges: [NSRange] = []
        var location = 0
        while location <= ns.length {
            let r = ns.range(of: query, options: opts,
                             range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            ranges.append(r)
            location = r.location + r.length
        }
        return MatchResult(ranges: ranges, error: nil)
    }

    /// 单次替换文本（当前匹配区间 → 替换串；正则支持 $1 捕获组）
    static func replacementString(in text: String, matchRange: NSRange, query: String,
                                  replacement: String, isRegularExpression: Bool,
                                  caseSensitive: Bool) -> String {
        guard isRegularExpression else { return replacement }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: query, options: options),
              let result = regex.firstMatch(in: text, range: matchRange) else { return replacement }
        return regex.replacementString(for: result, in: text, offset: 0, template: replacement)
    }

    /// 全量替换（新文本 + 替换计数；非法正则/空 query 原样返回 count=0）
    static func replacement(in text: String, query: String, replacement: String,
                            isRegularExpression: Bool, caseSensitive: Bool) -> (newText: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        if isRegularExpression {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else { return (text, 0) }
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            let count = regex.numberOfMatches(in: text, range: full)
            let newText = regex.stringByReplacingMatches(in: text, range: full, withTemplate: replacement)
            return (newText, count)
        }
        let ns = text as NSString
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var pairs: [(NSRange, String)] = []
        var location = 0
        while location <= ns.length {
            let r = ns.range(of: query, options: opts,
                             range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            pairs.append((r, replacement))
            location = r.location + r.length
        }
        guard !pairs.isEmpty else { return (text, 0) }
        var result = text
        for (range, rep) in pairs.reversed() {   // 逆序替换防 range 漂移
            result = (result as NSString).replacingCharacters(in: range, with: rep)
        }
        return (result, pairs.count)
    }
}
