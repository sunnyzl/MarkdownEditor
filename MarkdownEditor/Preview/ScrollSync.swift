import Foundation

// ScrollSync.swift — 单向滚动同步（S-013，FR-013，AD-7 MVP；v2 source map 精确路径 S-032/T1.4）
// 编辑器 → 预览单向；信号锁防死循环（R-A2）；挂起渲染超时跳过（设计 §7）
// 双路径共存：source map 命中块 → 精确行定位（setViewportSource）；未命中 → 比例回退（原逻辑）
@MainActor
final class ScrollSync {
    private let preview: PreviewProtocol

    /// 信号锁：程序化滚动期间置位，防双向同步死循环（R-A2；v2 双向预留机制）
    private var isSyncing = false
    /// renderDone 最新 scrollHeight（比例 → 像素换算依据）
    private var lastScrollHeight: Double = 0
    /// 有未完成渲染请求的时间点（nil = 无挂起渲染）。
    /// 超时语义基于"请求发起"而非"完成"：编辑停止后（>1s 无新渲染）滚动是常态，
    /// 此时无 pending → 正常同步（FR-013）；仅挂起渲染超时才跳过
    private var pendingRenderAt: Date?
    /// 最近一次编辑器滚动比例（renderDone 补偿同步用，FR-016）
    private var lastEditorRatio: Double = 0
    /// ⚠️ 修复 A：var（测试需赋值改短超时；生产默认 1.0）
    var renderTimeout: TimeInterval = 1.0

    // ⚠️ S-024（FR-014）：选区同步 debounce 间隔（100-200ms 区间；默认 150ms；测试注入短间隔，仿 renderTimeout 先例）
    var selectionDebounceInterval: TimeInterval = 0.15
    /// 选区同步挂起任务（debounce 计时；Task 继承 @MainActor 上下文，与 RenderCoordinator.debounceTask 同模式）
    private var selectionTask: Task<Void, Never>?

    // ⚠️ S-032（T1.4）：source map 精确路径状态（与比例路径共存，共用守卫，零新守卫机制）
    /// source map 块缓存（renderDone 随 scrollHeight 刷新；精确路径行→块查找依据）
    var sourceBlocks: [SourcePos] = []
    /// 最近下发的精确块行（去重：同块不重复下发；块变化才下发）
    private var lastSourceLines: (Int, Int)?

    init(preview: PreviewProtocol) {
        self.preview = preview
    }

    /// 渲染请求发起（RenderCoordinator 发送 setContent 时调用）
    func renderRequested() {
        pendingRenderAt = Date()
    }

    /// 编辑器滚动（比例 0~1，MarkdownTextView.reportScroll 产出）
    func editorScrolled(ratio: Double) {
        selectionTask?.cancel()   // 审查修复：手动滚动取消挂起选区同步（用户最新意图优先）
        guard !isSyncing else { return }
        let r = Self.clamp(ratio)
        lastEditorRatio = r
        guard lastScrollHeight > 0 else { return }   // 首次 renderDone 前无基准
        // 仅在"有挂起渲染且超时"时跳过；无挂起（编辑停止常态）→ 正常同步
        if let pending = pendingRenderAt, Date().timeIntervalSince(pending) > renderTimeout {
            return   // 挂起渲染超时：跳过该次同步（预览即将被覆盖）
        }
        isSyncing = true
        preview.setViewport(r * lastScrollHeight)
        isSyncing = false
    }

    /// 光标定位同步入口（S-024，FR-014）：选区变化 → debounce → 行比例 → setViewport
    /// ⚠️ S-032（T1.4）：双路径——source map 命中 → 精确行定位（setViewportSource）；未命中 → 比例回退
    /// 渲染挂起期检查复用（pendingRenderAt 未超时跳过）；信号锁/基准复用（与 editorScrolled 同守卫）
    /// 补偿合并：lastEditorRatio 立即更新（"最近用户定位比例"语义升级）——renderDone 补偿用最新
    /// 定位比例，消除"光标定位后一次编辑跳回旧位置"冲突（ScrollSync.swift:74-82 现状语义升级）
    func editorSelectionChanged(text: String, selection: NSRange) {
        selectionTask?.cancel()
        let ratio = Self.selectionLineRatio(text: text, selection: selection)
        lastEditorRatio = ratio          // 补偿合并：立即更新（编辑滚动与光标移动都更新）
        let line = Self.cursorLine(text: text, selection: selection)   // S-032：0-based 光标行号（越界 nil → 回退比例）
        let interval = selectionDebounceInterval
        selectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.applySelection(ratio: ratio, line: line)   // 直接调用：Task 继承 @MainActor 上下文，applySelection 为同步 @MainActor 方法（无需 await）
        }
    }

    /// debounce 到期执行：与 editorScrolled 同守卫（信号锁 / 基准 / 挂起超时）
    /// ⚠️ S-032（T1.4）：精确路径优先——source map 命中块 → setViewportSource（同块去重）；
    /// 未命中 → 回退比例路径（原 applySelectionRatio 逻辑）
    private func applySelection(ratio: Double, line: Int?) {
        guard !isSyncing else { return }
        guard lastScrollHeight > 0 else { return }   // 首次 renderDone 前无基准
        if let pending = pendingRenderAt, Date().timeIntervalSince(pending) > renderTimeout {
            return   // 挂起渲染超时：跳过（预览即将被覆盖，与滚动同步同语义）
        }
        // 精确路径：source map 命中块 → setViewportSource（去重：同块不重复下发）
        // ⚠️ 修复（T1.4-fix1 评审 CRITICAL）：cursorLine 返回 0-based 行号，而 findBlock/
        // data-sourcepos/SourcePos/Down 为 1-based —— 0-based 行直喂 findBlock 会在块结束行后
        // 空白行（0-based L 恰等于上一块 1-based endLine）误命中前一块；+1 对齐后空白行
        // 正确定位下一块（findBlock 语义②），相邻块首行同理不再串块
        if let line, let block = SourceMapParser.findBlock(containing: line + 1, in: sourceBlocks) {
            let target = (block.startLine, block.endLine)
            if let last = lastSourceLines, last == target { return }   // 同块去重：块不变不重复下发
            isSyncing = true
            preview.setViewportSource(block.startLine, block.endLine)
            isSyncing = false
            lastSourceLines = target
            return
        }
        // 比例回退路径（原有逻辑）
        isSyncing = true
        preview.setViewport(ratio * lastScrollHeight)
        isSyncing = false
    }

    /// renderDone 回调（FR-016 时机）：缓存基准高度 + 清除挂起 + 补偿同步
    /// ⚠️ S-032（T1.4）：source map 缓存随 scrollHeight 刷新（守卫：仅非空才刷新，防后三者上报点清空缓存）
    func previewRenderDone(_ payload: RenderDonePayload) {
        guard payload.status == "ok" else {
            pendingRenderAt = nil   // 修复（T4.6 盲审 ②）：error 路径清除挂起，防滚动同步永久跳过
            return
        }
        lastScrollHeight = payload.scrollHeight
        pendingRenderAt = nil
        // ⚠️ S-032（T1.4）：source map 缓存刷新（与 scrollHeight 同步时机）
        // 守卫：仅 payload.sourceMap 非空才刷新——renderDone 上报点共 4 处（setContent/setTheme/
        // setConfig/setFont），后三者无 sourceMap 字段；不守卫会清空缓存致精确路径失效
        if !payload.sourceMap.isEmpty {
            sourceBlocks = payload.sourceMap.compactMap { SourceMapParser.parse($0) }
            lastSourceLines = nil   // 新 source map：去重状态重置（"块变化才下发"语义基础）
        }
        // 补偿同步：渲染完成后按最近编辑器比例再同步一次（FR-016）
        // ⚠️ 守卫：lastEditorRatio > 0 才补偿（初值 0 时跳过，避免把预览滚回顶部）
        guard lastScrollHeight > 0, lastEditorRatio > 0 else { return }
        isSyncing = true
        preview.setViewport(lastEditorRatio * lastScrollHeight)
        isSyncing = false
    }

    /// 比例纯函数（可测）：clamp 0~1
    static func clamp(_ ratio: Double) -> Double {
        min(max(ratio.isFinite ? ratio : 0, 0), 1)
    }

    /// 选区 → 行比例纯函数（S-024，FR-014；可独立 XCTest）
    /// 前缀换行计数 → 行比例（光标所在行 / 总行数），clamp 0-1；空文本/单行 → 0；越界 → 0
    /// NSRange 为 UTF-16 位置 → NSString.substring(to:) 前缀切分（UTF-16 安全，emoji/中文不漂移）
    static func selectionLineRatio(text: String, selection: NSRange) -> Double {
        let ns = text as NSString
        guard selection.location >= 0, selection.location <= ns.length else { return 0 }
        let prefix = ns.substring(to: selection.location)
        let currentLine = prefix.components(separatedBy: "\n").count - 1   // 0-based 行号
        let totalLines = max(ns.components(separatedBy: "\n").count, 1)
        guard totalLines > 1 else { return 0 }
        return clamp(Double(currentLine) / Double(totalLines - 1))
    }

    /// 光标行号纯函数（S-032，T1.4；可独立 XCTest）
    /// 前缀换行计数 → 0-based 行号（与 selectionLineRatio 同构提取：UTF-16 安全）；
    /// 越界（location < 0 或 > length）→ nil（调用方回退比例路径）
    static func cursorLine(text: String, selection: NSRange) -> Int? {
        let ns = text as NSString
        guard selection.location >= 0, selection.location <= ns.length else { return nil }
        let prefix = ns.substring(to: selection.location)
        return prefix.components(separatedBy: "\n").count - 1
    }
}
