import XCTest
@testable import MarkdownEditor

// ScrollSync：比例换算 / 信号锁 / renderDone 超时（S-013 AC，R-A2 缓解）
@MainActor
final class ScrollSyncTests: XCTestCase {
    final class MockPreview: PreviewProtocol {
        var viewports: [Double] = []
        var configs: [PreviewConfig] = []   // ⚠️ S-026：setConfig 记录（协议变更同步 + 断言面）
        /// ⚠️ S-032（T1.4）：精确路径调用记录（setViewportSource 断言面）
        var viewportSources: [(startLine: Int, endLine: Int)] = []
        var onRenderDone: ((RenderDonePayload) -> Void)?
        var onLinkClicked: ((URL) -> Void)?
        var onErrorOccurred: ((String, String) -> Void)?
        func setContent(_ html: String) {}
        func setTheme(_ mode: ThemeMode) {}
        func setConfig(_ config: PreviewConfig) { configs.append(config) }   // ⚠️ S-026：协议新增
        func setViewport(_ scrollTop: Double) { viewports.append(scrollTop) }
        func setViewportSource(_ startLine: Int, _ endLine: Int) { viewportSources.append((startLine, endLine)) }   // ⚠️ S-032（T1.4）：协议新增
    }

    func testRatioMapsToViewport() {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.editorScrolled(ratio: 0.5)
        XCTAssertEqual(preview.viewports, [1000])
    }

    func testClampRatio() {
        XCTAssertEqual(ScrollSync.clamp(-0.5), 0)
        XCTAssertEqual(ScrollSync.clamp(1.5), 1)
        XCTAssertEqual(ScrollSync.clamp(0.3), 0.3)
        XCTAssertEqual(ScrollSync.clamp(.nan), 0, "非有限值回落 0")
    }

    func testNoBaselineBeforeRenderDone() {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.editorScrolled(ratio: 0.5)
        XCTAssertTrue(preview.viewports.isEmpty, "renderDone 前无基准高度，跳过同步")
    }

    func testPendingRenderTimeoutSkipsSync() {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.renderTimeout = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.renderRequested()                        // ⚠️ 修复 #4-②：发起挂起渲染请求
        Thread.sleep(forTimeInterval: 0.1)            // 模拟挂起渲染超时（> renderTimeout）
        sync.editorScrolled(ratio: 0.5)
        XCTAssertTrue(preview.viewports.isEmpty, "挂起渲染超时跳过该次同步（设计 §7）")
    }

    func testPendingRenderNotTimedOutSyncs() {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.editorScrolled(ratio: 0.3)               // 无挂起渲染：正常同步（FR-013 常态）
        sync.renderRequested()                        // 挂起渲染请求（未超时）
        sync.editorScrolled(ratio: 0.5)               // 应正常同步（挂起未超时）
        XCTAssertFalse(preview.viewports.isEmpty)
        XCTAssertEqual(preview.viewports.last, 1000)  // 0.5 × 2000
    }

    func testErrorStatusIgnoresBaseline() {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.previewRenderDone(RenderDonePayload(status: "error", error: "x", scrollHeight: 0, elapsed: 10))
        sync.editorScrolled(ratio: 0.5)
        XCTAssertTrue(preview.viewports.isEmpty)
    }

    // ⚠️ 新增（T4.6 审查修复）：error 路径必须清除挂起渲染，否则 pending 超时逻辑
    // 永久跳过后续滚动同步（防滚动同步锁死）
    func testErrorClearsPendingRenderSyncRecovers() {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.renderTimeout = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.renderRequested()
        sync.previewRenderDone(RenderDonePayload(status: "error", error: "x", scrollHeight: 0, elapsed: 10))
        Thread.sleep(forTimeInterval: 0.1)   // 超时窗口已过
        sync.editorScrolled(ratio: 0.5)
        XCTAssertEqual(preview.viewports.last, 1000, "error renderDone 后滚动同步恢复")
    }

    // ⚠️ S-024（FR-014）追加：selectionLineRatio 纯函数（空/单行/行首/行尾/多行/越界）

    func testSelectionLineRatioEmpty() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "", selection: NSRange(location: 0, length: 0)), 0)
    }

    func testSelectionLineRatioSingleLine() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "one line", selection: NSRange(location: 3, length: 0)), 0, "单行恒为 0")
    }

    func testSelectionLineRatioFirstLine() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "a\nb\nc", selection: NSRange(location: 0, length: 0)), 0, "第 0 行 → 0")
    }

    func testSelectionLineRatioLastLine() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "a\nb\nc", selection: NSRange(location: 4, length: 0)), 1, "最后一行 → 1")
    }

    func testSelectionLineRatioMiddle() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "a\nb\nc", selection: NSRange(location: 2, length: 0)), 0.5, "第 1 行 → 0.5")
    }

    func testSelectionLineRatioEndOfText() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "a\nb", selection: NSRange(location: 3, length: 0)), 1, "光标在末尾 → 最后一行")
    }

    func testSelectionLineRatioOutOfBounds() {
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "a\nb", selection: NSRange(location: 99, length: 0)), 0, "越界回落 0")
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "a\nb", selection: NSRange(location: -1, length: 0)), 0, "负位置回落 0")
    }

    // ⚠️ S-024（FR-014）追加：editorSelectionChanged（debounce/挂起跳过/补偿合并/无基准跳过）

    func testSelectionChangeDebouncesAndScrolls() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 4, length: 0))   // 最后一行 → 1.0
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewports.last, 2000, "debounce 后按行比例定位（1.0 × 2000）")
    }

    func testSelectionRapidChangesOnlyLastFires() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 1000, elapsed: 10))
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 0, length: 0))   // 0.0
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 2, length: 0))   // 0.5
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 4, length: 0))   // 1.0
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewports.last, 1000, "debounce 合并：仅最后一次生效")
    }

    func testSelectionPendingRenderTimeoutSkips() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.renderTimeout = 0.05
        sync.selectionDebounceInterval = 0.06   // debounce 到期时挂起已超时（0.06 > 0.05）
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.renderRequested()                  // 挂起渲染请求
        sync.editorSelectionChanged(text: "a\nb", selection: NSRange(location: 3, length: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(preview.viewports.isEmpty, "挂起渲染超时跳过选区同步（与滚动同步同守卫）")
    }

    func testSelectionCompensationMergesLatestRatio() async throws {
        // 补偿合并：光标定位覆盖旧滚动比例——renderDone 补偿用"最近用户定位比例"（语义升级）
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.editorScrolled(ratio: 0.2)                                      // 编辑滚动 0.2
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 4, length: 0))  // 光标定位 1.0
        try await Task.sleep(nanoseconds: 300_000_000)
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        XCTAssertEqual(preview.viewports, [400, 2000, 2000], "补偿同步按最近定位比例（光标 1.0 覆盖旧滚动 0.2；renderDone 补偿再同步一次）")
    }

    func testSelectionBeforeBaselineNoScroll() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 4, length: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(preview.viewports.isEmpty, "renderDone 前无基准高度，跳过定位")
    }

    // ⚠️ S-024 追加（review cycle 建议）：UTF-16 安全回归锁定（selectionLineRatio 核心卖点）
    func testSelectionLineRatioUtf16EmojiNoDrift() {
        // 😀=U+1F600 占 2 个 UTF-16 单元：location 4 落在 "b"（UTF-16 位置），非字符位置
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "😀a\nb", selection: NSRange(location: 4, length: 0)), 1, "emoji 前缀不漂移：最后一行 → 1")
        XCTAssertEqual(ScrollSync.selectionLineRatio(text: "中文\n行", selection: NSRange(location: 2, length: 0)), 0, "中文前缀 UTF-16 切分正确：第 0 行 → 0")
    }

    // 审查修复：手动滚动优先于挂起选区同步（顺序[光标点击→150ms 内手动滚预览]不被陈旧选区覆盖）
    func testManualScrollCancelsPendingSelectionSync() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 4, length: 0))   // 光标 1.0 → 挂起定位任务
        sync.editorScrolled(ratio: 0.2)                                                          // 150ms 窗口内手动滚动预览
        try await Task.sleep(nanoseconds: 300_000_000)                                           // 等待 debounce 窗口过期
        XCTAssertEqual(preview.viewports.last, 400, "手动滚动取消挂起选区同步，陈旧光标定位不覆盖新滚动")
    }

    // ⚠️ S-026 追加：setConfig 记录断言（协议变更同步）
    func testSetConfigRecorded() {
        let preview = MockPreview()
        preview.setConfig(PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false))
        XCTAssertEqual(preview.configs, [PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false)])
    }

    // ⚠️ S-032（Epic-6 T1.4）追加：source map 精确路径（与比例路径共存，共用守卫，零新守卫机制）

    /// 精确命中下发：source map 命中块 → setViewportSource(startLine, endLine)（经 debounce Task）
    /// 同块内光标移动去重：块不变不重复下发（lastSourceLines 去重）
    func testExactSourceMapHitUsesViewportSource() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10,
                                                 sourceMap: ["1:1-2:5", "5:1-8:3", "12:1-15:3"]))
        // 12 行文本；光标 'f'（location 10）→ 前缀换行 5 → 0-based L=5 → 命中块 5:1-8:3
        let text = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl"
        sync.editorSelectionChanged(text: text, selection: NSRange(location: 10, length: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewportSources.count, 1, "精确命中下发一次")
        XCTAssertEqual(preview.viewportSources.last?.startLine, 5, "精确路径下发块起始行")
        XCTAssertEqual(preview.viewportSources.last?.endLine, 8, "精确路径下发块结束行")
        XCTAssertTrue(preview.viewports.isEmpty, "精确路径不应走比例 setViewport")
        // 同块内移动光标（'g' location 12 → L=6，仍在块 5-8 内）→ 去重：不重复下发
        sync.editorSelectionChanged(text: text, selection: NSRange(location: 12, length: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewportSources.count, 1, "同块去重：块变化才下发")
    }

    /// 无 source map（sourceBlocks 空）→ 回退比例路径（setViewport 被调用，setViewportSource 不被调用）
    func testNoSourceMapFallsBackToRatio() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10))  // 无 sourceMap → 缓存空
        sync.editorSelectionChanged(text: "a\nb\nc", selection: NSRange(location: 4, length: 0))   // 最后一行 → 1.0
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewports.last, 2000, "无 source map 回退比例路径（1.0 × 2000）")
        XCTAssertTrue(preview.viewportSources.isEmpty, "比例路径不调用 setViewportSource")
    }

    /// 守卫断言：renderDone 无 sourceMap 不清空缓存（setTheme/setConfig/setFont 上报点无此字段）
    func testRenderDoneWithoutSourceMapKeepsCache() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10,
                                                 sourceMap: ["1:1-2:5", "5:1-8:3"]))
        XCTAssertEqual(sync.sourceBlocks.count, 2, "source map 解析入缓存")
        // 无 sourceMap 的 renderDone（后三者上报点）→ 守卫：不刷新缓存（不清空）
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2500, elapsed: 10))
        XCTAssertEqual(sync.sourceBlocks.count, 2, "无 sourceMap 的 renderDone 不清空缓存")
        XCTAssertEqual(sync.sourceBlocks.first?.startLine, 1, "缓存内容保持")
    }

    /// renderDone 后缓存刷新：带 sourceMap 的 renderDone → sourceBlocks 更新为新解析结果（无效条目过滤）
    func testRenderDoneRefreshesSourceBlocks() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10,
                                                 sourceMap: ["1:1-2:5", "5:1-8:3"]))
        XCTAssertEqual(sync.sourceBlocks.map { $0.startLine }, [1, 5], "初次解析")
        // 新文档 renderDone → 缓存刷新为新解析结果（含无效条目"garbage"丢弃）
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 3000, elapsed: 10,
                                                 sourceMap: ["3:1-4:9", "garbage", "10:1-11:2"]))
        XCTAssertEqual(sync.sourceBlocks.map { $0.startLine }, [3, 10], "刷新为新解析结果（无效条目丢弃）")
    }

    // ⚠️ 修复（T1.4-fix1 评审 CRITICAL）：cursorLine 返回 0-based 行号，findBlock 期望 1-based
    // （与 data-sourcepos/SourcePos/Down 语义一致）。修复前 0-based 行直喂 findBlock：
    // 光标在块结束行后空白行（0-based L 恰等于上一块 1-based endLine）→ 误命中前一块；
    // 修复后 line+1 对齐 → 空白行正确定位下一块（findBlock 语义②：startLine > line 的最近下一块）
    func testExactPathBoundaryGapLineTargetsNextBlock() async throws {
        let preview = MockPreview()
        let sync = ScrollSync(preview: preview)
        sync.selectionDebounceInterval = 0.05
        sync.previewRenderDone(RenderDonePayload(status: "ok", error: nil, scrollHeight: 2000, elapsed: 10,
                                                 sourceMap: ["1:1-2:5", "5:1-8:3", "12:1-15:3"]))
        // 12 行文本（与 testExactSourceMapHitUsesViewportSource 同 fixture）
        let text = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl"
        // 断言①：光标 'c'（location 4）→ 0-based L=2 → 1-based 行 3 → 块 [1,2] 后空白行 → 定位下一块 [5,8]
        // 修复前：findBlock(2) 命中块 [1,2]（endLine=2）→ 误发 (1,2)
        sync.editorSelectionChanged(text: text, selection: NSRange(location: 4, length: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewportSources.last?.startLine, 5, "块 [1,2] 后空白行应定位下一块起始行")
        XCTAssertEqual(preview.viewportSources.last?.endLine, 8, "块 [1,2] 后空白行应定位下一块结束行")
        // 断言②：光标 'i'（location 16）→ 0-based L=8 → 1-based 行 9 → 块 [5,8] 后空白行 → 定位下一块 [12,15]
        // 修复前：findBlock(8) 命中块 [5,8]（endLine=8）→ 误发 (5,8)
        sync.editorSelectionChanged(text: text, selection: NSRange(location: 16, length: 0))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preview.viewportSources.last?.startLine, 12, "块 [5,8] 后空白行应定位下一块起始行")
        XCTAssertEqual(preview.viewportSources.last?.endLine, 15, "块 [5,8] 后空白行应定位下一块结束行")
        XCTAssertTrue(preview.viewports.isEmpty, "精确路径不应走比例 setViewport")
    }
}
