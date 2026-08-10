import XCTest
@testable import MarkdownEditor

// RenderCoordinator：debounce 时序 / IME 暂停恢复 / 降级路由 / 埋点（S-010 AC-1/2/4/6/7）
@MainActor
final class RenderCoordinatorTests: XCTestCase {
    final class MockParser: MarkdownParsing {
        var received: [String] = []
        var error: Error?
        func render(markdown: String) throws -> String {
            received.append(markdown)
            if let error { throw error }
            return "<p>\(markdown)</p>"
        }
    }
    final class MockPreprocessor: MermaidPreprocessing {
        var lastInput = ""
        func transform(html: String) -> MermaidTransformResult {
            lastInput = html
            return MermaidTransformResult(html: html, needsJsFallback: false)
        }
    }
    final class MockPreview: PreviewProtocol {
        var contents: [String] = []
        var onRenderDone: ((RenderDonePayload) -> Void)?
        var onLinkClicked: ((URL) -> Void)?
        var onErrorOccurred: ((String, String) -> Void)?
        func setContent(_ html: String) { contents.append(html) }
        func setTheme(_ mode: ThemeMode) {}
        func setConfig(_ config: PreviewConfig) {}   // ⚠️ S-026：协议新增（本类不测，保编译）
        func setViewport(_ scrollTop: Double) {}
        func setViewportSource(_ startLine: Int, _ endLine: Int) {}   // ⚠️ S-032（T1.4）：协议新增（本类不测，保编译）
    }
    final class MockError: Error {}

    private func makeCoordinator(parser: MockParser = MockParser(),
                                 pre: MockPreprocessor = MockPreprocessor(),
                                 preview: MockPreview = MockPreview()) -> RenderCoordinator {
        RenderCoordinator(parser: parser, preprocessor: pre, errorHandler: ErrorHandling(), preview: preview)
    }

    // ⚠️ P1 后置（flake 加固）：确定性等待替代固定时长 sleep——等待真实 debounce 完成
    func testDebounceFiresOnceWithLatestText() async throws {
        let parser = MockParser()
        let preview = MockPreview()
        let rc = makeCoordinator(parser: parser, preview: preview)
        rc.debounceInterval = 0.05

        rc.input("a")
        rc.input("ab")
        rc.input("abc")                 // 快速连续输入 → 仅最后一次生效
        await rc.waitForPendingRender() // 确定性等待（替代 sleep(200ms)——CI flake 修复）

        XCTAssertEqual(parser.received, ["abc"], "debounce 只渲染最后一次输入")
        XCTAssertEqual(preview.contents.count, 1, "只注入一次")
    }

    func testPauseSuppressesThenResumeRendersOnce() async throws {
        let parser = MockParser()
        let preview = MockPreview()
        let rc = makeCoordinator(parser: parser, preview: preview)
        rc.debounceInterval = 0.05

        rc.pause()
        rc.input("compose 中")          // 暂停期间输入 → 不渲染（无挂起任务，等待立即返回）
        await rc.waitForPendingRender()
        XCTAssertTrue(parser.received.isEmpty, "compose 期间不得触发渲染（FR-006/NFR-014）")

        rc.resume()                     // 上屏 → 立即渲染一次
        await rc.waitForPendingRender() // 确定性等待恢复后的 debounce 完成
        XCTAssertEqual(parser.received, ["compose 中"])
        XCTAssertEqual(preview.contents.count, 1)
    }

    func testDownFailureDegradesToPlaceholder() async {
        let parser = MockParser()
        parser.error = MockError()
        let preview = MockPreview()
        let rc = makeCoordinator(parser: parser, preview: preview)
        var reported: RenderError?

        rc.onRenderError = { reported = $0 }
        await rc.render("boom")

        XCTAssertNotNil(reported, "阶段 2 失败必须上报（NFR-012）")
        XCTAssertEqual(preview.contents.count, 1)
        XCTAssertTrue(preview.contents.first?.contains("render-error") == true,
                      "错误占位非空白（设计 §7：预览显示错误占位）")
    }

    func testStageMetricsEmitted() async {
        let rc = makeCoordinator()
        var metrics: [RenderCoordinator.Stage: TimeInterval] = [:]
        rc.onStageMetric = { metrics[$0] = $1 }
        await rc.render("# Hello")
        XCTAssertNotNil(metrics[.down])
        XCTAssertNotNil(metrics[.preprocess])
        XCTAssertNotNil(metrics[.inject])
    }

    // ⚠️ 遗留 #3（批次 2）追加：旧代次丢弃（latest-wins）
    // Task 交错构造：setContent 同步（慢 mock 不可行）→ 用显式 renderID 模拟过期代次
    // ⚠️ 修复 #1（第 1 轮）：renderID 必须用 0（过期值）——Task 继承 MainActor 排队，
    // input("b") 同步先执行使 renderID 0→1；stale 任务体执行时若传 renderID: 1
    // 会与 self.renderID(1) 相等而校验通过（旧代次不被丢弃，测试必红）。
    // 传 renderID: 0 → stale 执行时 0 != self.renderID(1) → 丢弃 ✓
    func testStaleRenderDiscarded() async throws {
        let parser = MockParser()
        let preview = MockPreview()
        let rc = makeCoordinator(parser: parser, preview: preview)
        rc.debounceInterval = 0.05

        // 交错构造：旧代次渲染（renderID: 0——过期值，当前 renderID 已为 1）
        let stale = Task { await rc.render("a", renderID: 0) }
        rc.input("b")   // 同步先执行：renderID 0→1，scheduleRender("b", renderID: 1)
        await stale.value   // stale 执行 render("a", renderID: 0)：0 != 1 → 丢弃
        await rc.waitForPendingRender() // 确定性等待（替代 sleep）——debounce 后渲染 "b"

        XCTAssertEqual(preview.contents, ["<p>b</p>"], "过期代次渲染必须静默丢弃（latest-wins）")
    }

    // 直调抢占挂起代次：input 调度（renderID 1）→ 直调 render（renderID 2）→ 挂起任务过期丢弃
    // Direct render supersedes pending debounce: input schedules (renderID 1) → direct render (renderID 2) → pending task expires
    func testDirectRenderSupersedesPendingDebounce() async throws {
        let parser = MockParser()
        let preview = MockPreview()
        let rc = makeCoordinator(parser: parser, preview: preview)
        rc.debounceInterval = 0.05

        rc.input("a")                       // renderID 0→1，调度挂起任务（renderID: 1）
        await rc.render("b")                // 直调 nil → renderID 1→2，注入 b
        await rc.waitForPendingRender()     // 确定性等待（替代 sleep）——挂起任务到期 → 1 != 2 → 丢弃

        XCTAssertEqual(preview.contents, ["<p>b</p>"], "直调必须抢占挂起的 debounce 任务（latest-wins）")
    }

    // ⚠️ T3.3（FR-104）追加：clamp 边界（100/1000/越界）——纯函数断言
    // T3.3 (FR-104) addition: clamp boundaries (100/1000/out-of-range) — pure-function assertions.
    func testClampDebounceBoundaries() {
        XCTAssertEqual(RenderCoordinator.clampDebounce(100), 100, "下限 100ms 保持")
        XCTAssertEqual(RenderCoordinator.clampDebounce(1000), 1000, "上限 1000ms 保持")
        XCTAssertEqual(RenderCoordinator.clampDebounce(50), 100, "越下界 → 抬升到 100ms")
        XCTAssertEqual(RenderCoordinator.clampDebounce(2000), 1000, "越上界 → 压制到 1000ms")
        XCTAssertEqual(RenderCoordinator.clampDebounce(300), 300, "范围内原样返回")
    }

    // ⚠️ T3.3（FR-104）追加：defaults 链路双段验证——init 读 defaults（启动生效）+ 广播重读（实时生效）。
    // 注入短间隔 100ms（clamp 下限）→ debounceInterval 0.1s（与默认 0.3s 可区分）；
    // 广播经 NotificationCenter 同步投递（queue: .main），断言确定性。
    // T3.3 (FR-104) addition: two-segment defaults-chain verification — init reads defaults
    // (launch-time effect) + broadcast re-read (live effect). Injects a short 100ms interval
    // (clamp floor) → debounceInterval 0.1s (distinguishable from the 0.3s default);
    // the broadcast is delivered synchronously (queue: .main), so assertions are deterministic.
    func testDebounceIntervalReadsDefaultsAndUpdatesOnBroadcast() {
        let defaults = makeDefaults()
        defaults.set(100, forKey: SettingsChangeKey.renderDebounce)
        let state = MainContentState(defaults: defaults)
        XCTAssertEqual(state.coordinator.debounceInterval, 0.1, "init 读 defaults → debounceInterval=0.1s（FR-104 启动生效）")

        defaults.set(500, forKey: SettingsChangeKey.renderDebounce)   // 模拟面板写入端（SettingsApplier.setRenderDebounce）
        NotificationCenter.default.post(
            name: .editorSettingsDidChange, object: nil,
            userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.renderDebounce]])
        XCTAssertEqual(state.coordinator.debounceInterval, 0.5, "广播 renderDebounce 键 → 重读 clamp → 实时生效（FR-104）")
    }

    // ⚠️ T3.3 修复 #1（评审 IMPORTANT）：写入端 clamp——SettingsApplier.setRenderDebounce 落盘前
    // clamp（100-1000ms）；越界输入不得污染 defaults（T3.5 面板 Slider 经此写入端）
    // T3.3 fix #1 (review IMPORTANT): write-end clamp — SettingsApplier.setRenderDebounce clamps
    // before persisting (100-1000ms); out-of-range input must not pollute defaults (T3.5 Slider
    // writes through this write end).
    func testSetRenderDebounceClampsBeforePersist() {
        let defaults = makeDefaults()
        let applier = SettingsApplier(defaults: defaults)
        applier.setRenderDebounce(50)
        XCTAssertEqual(defaults.integer(forKey: SettingsChangeKey.renderDebounce), 100,
                       "写入端 clamp：50ms 越下界 → 抬升 100ms 落盘（FR-104）")
        applier.setRenderDebounce(2000)
        XCTAssertEqual(defaults.integer(forKey: SettingsChangeKey.renderDebounce), 1000,
                       "写入端 clamp：2000ms 越上界 → 压制 1000ms 落盘（FR-104）")
    }

    // ⚠️ T3.3 修复 #1（评审 IMPORTANT）：未设置键 → init 回落 0.3 默认；空键广播不扰动
    //（订阅端按键重读，changedKeys 不含 renderDebounce → 不重读）
    // T3.3 fix #1 (review IMPORTANT): unset key → init falls back to the 0.3s default;
    // an empty-key broadcast does not disturb it (subscriber re-reads by key — no key, no re-read).
    func testDebounceIntervalDefaultsToZeroPointThreeWhenUnset() {
        let defaults = makeDefaults()
        let state = MainContentState(defaults: defaults)
        XCTAssertEqual(state.coordinator.debounceInterval, 0.3, "未设置 renderDebounce → init 回落 0.3s 默认（FR-104）")

        NotificationCenter.default.post(
            name: .editorSettingsDidChange, object: nil,
            userInfo: [SettingsNotificationUserInfoKey.changedKeys: [String]()])
        XCTAssertEqual(state.coordinator.debounceInterval, 0.3, "空键广播 → 不触发重读 → 仍 0.3s（FR-104）")
    }

    // ⚠️ T3.3 修复 #1（评审 IMPORTANT）：越界值从 defaults 读取时 clamp——init 读 2000 → 1.0s；
    // 广播重读 50 → 0.1s（读取端 clamp 双路径）
    // T3.3 fix #1 (review IMPORTANT): out-of-range values clamp on the defaults read path —
    // init reads 2000 → 1.0s; broadcast re-reads 50 → 0.1s (read-end clamp, both paths).
    func testDebounceIntervalClampsOutOfRangeFromDefaults() {
        let defaults = makeDefaults()
        defaults.set(2000, forKey: SettingsChangeKey.renderDebounce)
        let state = MainContentState(defaults: defaults)
        XCTAssertEqual(state.coordinator.debounceInterval, 1.0, "init 读越界 2000 → clamp 到 1.0s（FR-104）")

        defaults.set(50, forKey: SettingsChangeKey.renderDebounce)   // 模拟面板写入越界值
        NotificationCenter.default.post(
            name: .editorSettingsDidChange, object: nil,
            userInfo: [SettingsNotificationUserInfoKey.changedKeys: [SettingsChangeKey.renderDebounce]])
        XCTAssertEqual(state.coordinator.debounceInterval, 0.1, "广播重读越界 50 → clamp 到 0.1s（FR-104）")
    }

    /// suiteName 隔离 defaults（防本机 .standard 存储干扰断言——MainContentStateTests 先例）
    /// suiteName-isolated defaults (guards assertions against local .standard storage —
    /// MainContentStateTests precedent).
    private func makeDefaults() -> UserDefaults {
        let name = "render-coordinator-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}
