import Foundation
import Combine   // ⚠️ 修复 #1：ObservableObject 来自 Combine（MainContentAssembly 以 @StateObject 持有）

// RenderCoordinator.swift — 5 阶段渲染状态机（S-010，AD-3，设计 §5.2）
// 阶段：① debounce 300ms → ② Down 解析 → ③ Mermaid 预处理 → ④ morphdom 注入（JS 侧）
//      → ⑤ 三件套重渲染（JS 侧）→ renderDone 回调
// 每阶段 try-catch + 降级路由 + 计时埋点（NFR-001/012，TOP 3 关注项 3）
// ⚠️ 修复 #1：conform ObservableObject（@StateObject 泛型约束；无需 @Published，持有即用）
// ⚠️ 遗留 #3（批次 2）：renderID 代次守卫（latest-wins，防御性——当前全同步管线无真实竞态；
//     AD-9 契约不变：JS 侧不加 token；v2 扩展点：可升级为 token 握手 + 取消旧代次 Task）
@MainActor
final class RenderCoordinator: ObservableObject {
    enum Stage: String, CaseIterable {
        case debounce, down, preprocess, inject, jsRender
    }

    // 依赖注入（可测性：mock 替身）
    let parser: MarkdownParsing
    let preprocessor: MermaidPreprocessing
    let errorHandler: ErrorHandling
    let preview: PreviewProtocol

    /// debounce 间隔（FR-012 默认 300ms；FR-104 可配；测试注入短间隔）
    var debounceInterval: TimeInterval = 0.3

    /// debounce 时长 clamp 纯函数（FR-104，可测）：100ms ~ 1000ms（clampedZoom 先例）
    /// Debounce clamp pure function (FR-104, testable): 100ms ~ 1000ms (clampedZoom precedent).
    static func clampDebounce(_ ms: Int) -> Int {
        min(max(ms, 100), 1000)
    }

    /// 计时埋点输出（NFR-001 验收：每阶段耗时）
    var onStageMetric: ((Stage, TimeInterval) -> Void)?
    /// 渲染错误回调（NFR-012 状态栏提示基础）
    var onRenderError: ((RenderError) -> Void)?
    /// ⚠️ 修复 #4-③：注入前回调（ScrollSync.renderRequested 挂起渲染计时；T4.2 接线）
    var onWillInject: (() -> Void)?

    private var debounceTask: Task<Void, Never>?
    private var isPaused = false          // IME compose 暂停（S-008）
    private var pendingText: String?      // 暂停期间累积的最新内容
    private var renderID = 0              // ⚠️ 遗留 #3：渲染代次计数器（latest-wins 守卫）

    init(parser: MarkdownParsing,
         preprocessor: MermaidPreprocessing,
         errorHandler: ErrorHandling,
         preview: PreviewProtocol,
         defaults: UserDefaults = .standard) {
        self.parser = parser
        self.preprocessor = preprocessor
        self.errorHandler = errorHandler
        self.preview = preview
        // ⚠️ T3.3（FR-104）：debounce 时长 UserDefaults 化——init 读 defaults（clamp 100-1000ms；
        // 未设置回落 0.3 默认；T3.5 面板 Slider 写入端 SettingsApplier.setRenderDebounce）
        // Debounce interval is now UserDefaults-backed (FR-104): init reads the stored value
        // (clamped 100-1000ms), falls back to the 0.3s default when unset; the panel Slider
        // writes via SettingsApplier.setRenderDebounce (T3.5).
        let stored = defaults.object(forKey: SettingsChangeKey.renderDebounce) as? Int
        self.debounceInterval = stored.map { Double(Self.clampDebounce($0)) / 1000 } ?? 0.3
    }

    // MARK: - 阶段 1：编辑事件入口

    /// 编辑事件入口：IME compose 期间暂停收集，恢复后立即渲染一次（FR-012/FR-006）
    func input(_ text: String) {
        if isPaused {
            pendingText = text
            return
        }
        scheduleRender(text)
    }

    /// IME compose 开始：取消挂起任务，暂停渲染（S-008）
    func pause() {
        isPaused = true
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// IME 上屏：恢复渲染管线并立即触发一次（S-008 AC：上屏后 ≤500ms 预览更新）
    func resume() {
        isPaused = false
        if let pending = pendingText {
            pendingText = nil
            scheduleRender(pending)
        }
    }

    // MARK: - 测试入口（P1 后置：debounce 测试加固）

    /// 确定性等待：挂起 debounce 任务完成后返回——替代固定时长 Task.sleep
    ///（CI 慢机/调度抖动下的 flake 源；等待真实完成而非猜测时长）。
    /// 无挂起任务（pause 取消/nil）立即返回。生产路径零行为变化。
    /// Deterministic wait: returns after the pending debounce task completes —
    /// replaces fixed-duration sleeps in tests (the CI flake source).
    func waitForPendingRender() async {
        await debounceTask?.value
    }

    // MARK: - 阶段 1：debounce

    private func scheduleRender(_ text: String) {
        debounceTask?.cancel()
        renderID += 1                     // ⚠️ 遗留 #3：新代次抢占，旧代次自动过期
        let currentID = renderID
        let interval = debounceInterval
        let tDebounce = Date()   // 阶段 1 埋点起点（#9 修复：debounce 阶段补计时）
        debounceTask = Task { [weak self] in
            // 防御负间隔/异常值导致 UInt64 trap（MINOR 加固）
            // Guard against negative/abnormal intervals causing UInt64 trap
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.render(text, debounceStart: tDebounce, renderID: currentID)
        }
    }

    // MARK: - 阶段 2~5：渲染编排

    func render(_ text: String, debounceStart: Date? = nil, renderID: Int? = nil) async {
        // ⚠️ 遗留 #3 恢复点校验 #1：过期代次直接丢弃（latest-wins）
        // 直调（renderID: nil）先提升为新代次：抢占挂起任务且自身不被校验（保持 nil 兼容）
        // Direct call (renderID: nil) bumps to a new generation first: preempts pending tasks while staying exempt from the guard (nil compatibility)
        if renderID == nil { self.renderID += 1 }
        if let id = renderID, id != self.renderID { return }
        // 阶段 1 埋点（#9 修复：debounce 等待耗时，端到端 NFR-001 验证用）
        if let ds = debounceStart { emit(.debounce, from: ds) }
        // 阶段 2：Down 解析（try-catch → 错误占位，不崩溃，NFR-012）
        let tDown = Date()
        let html: String
        do {
            html = try parser.render(markdown: text)
        } catch {
            let err = RenderError.down(String(describing: error))
            errorHandler.fail(err)
            onRenderError?(err)
            await preview.setContent(errorHandler.placeholderHTML("Markdown 解析失败"))
            return
        }
        emit(.down, from: tDown)

        // 阶段 3：Mermaid 预处理（Swift 正则主，设计 §5.2 方案 B）
        let tPre = Date()
        let result = preprocessor.transform(html: html)
        emit(.preprocess, from: tPre)
        if result.needsJsFallback {
            // 残留检测命中：JS 端兜底（方案 A）将执行；此处仅埋点
            NSLog("[RenderCoordinator] Mermaid 正则残留，触发 JS DOM 兜底")
        }

        // 阶段 4+5：注入与三件套重渲染（JS 侧 MessageBridge.setContent 实现）
        let tInject = Date()
        // ⚠️ 修复 #4-③：注入前通知外部（ScrollSync.renderRequested 挂起渲染计时，T4.2 接线）
        onWillInject?()
        await preview.setContent(result.html)
        // ⚠️ 遗留 #3 恢复点校验 #2：await 让出期间若更新代次已抢占 → 停止后续埋点（latest-wins）
        if let id = renderID, id != self.renderID { return }
        emit(.inject, from: tInject)
        // renderDone 由 PreviewWebView 回调 → 外部挂接（ScrollSync，S-013）
        // jsRender 阶段耗时由 renderDone.elapsed 覆盖（NFR-001 端到端埋点）
    }

    // MARK: - 埋点

    private func emit(_ stage: Stage, from start: Date) {
        onStageMetric?(stage, Date().timeIntervalSince(start))
    }
}
