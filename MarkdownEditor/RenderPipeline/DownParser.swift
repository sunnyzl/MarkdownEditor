import Down

// DownParser.swift — Markdown → HTML 封装（S-010 阶段 2 / S-011 GFM，设计 §5.4）
// 基于 Down-gfm fork（stackotter/Down-gfm 0.12.0，product 名仍为 Down，cmark-gfm）
// ⚠️ 第 9 轮：fork 亦无 GFM 扩展（源码验证）——GFM 由批次 4 GfmPostProcessor 后处理
// ⚠️ 第 11 轮（T4.4）：方案 B 为预期路径——GFM 后处理接入，无降级路径
// ⚠️ T1.1（Epic-6 批次 1）：启用 .sourcePos 选项（POC S-004 §1 已验证 rawValue 2）
//    ——sourcepos 使块级标签带 data-sourcepos 属性，格式 "行:列-行:列"（如 "1:1-1:1"），
//    供滚动同步定位与导出净化（ExportManager.stripSourcePos）使用
struct DownParser: MarkdownParsing {
    private let gfmProcessor = GfmPostProcessor()

    /// 阶段 2 主入口：`.default ∪ .sourcePos` 渲染 + GFM 后处理（方案 B 预期路径）
    func render(markdown: String) throws -> String {
        try render(markdown: markdown, gfm: true)
    }

    /// S-011 GFM 入口：`.default ∪ .sourcePos`（fork 无 GFM 扩展，源码验证）→ Swift 后处理
    func render(markdown: String, gfm: Bool) throws -> String {
        let down = Down(markdownString: markdown)
        let html = try down.toHTML(.default.union(.sourcePos))
        return gfm ? gfmProcessor.process(html) : html
    }
}
