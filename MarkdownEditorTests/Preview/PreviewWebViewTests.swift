import XCTest
@testable import MarkdownEditor

// PreviewWebView 可测部分：schema 解析 + jsString 转义（WKWebView 本体需运行验收）
// ⚠️ 修复 #1（第 5 轮）：@MainActor — parseRenderDone/jsString 是 @MainActor static，
//   无标注则 Swift 6 语言模式报 "call to main actor-isolated static method" 编译错误
@MainActor
final class PreviewWebViewTests: XCTestCase {
    func testParseRenderDoneOk() {
        let body: [String: Any] = ["status": "ok", "scrollHeight": 1234.5, "elapsed": 88]
        let payload = PreviewWebView.parseRenderDone(body)
        XCTAssertEqual(payload.status, "ok")
        XCTAssertNil(payload.error)
        XCTAssertEqual(payload.scrollHeight, 1234.5)
        XCTAssertEqual(payload.elapsed, 88)
    }

    func testParseRenderDoneErrorAndMissingFields() {
        let body: [String: Any] = ["status": "error", "error": "boom"]
        let payload = PreviewWebView.parseRenderDone(body)
        XCTAssertEqual(payload.status, "error")
        XCTAssertEqual(payload.error, "boom")
        XCTAssertEqual(payload.scrollHeight, 0, "缺失字段回落 0")
        XCTAssertEqual(payload.elapsed, 0)
    }

    func testParseRenderDoneNonDictBody() {
        let payload = PreviewWebView.parseRenderDone("garbage")
        XCTAssertEqual(payload.status, "error", "非字典 body 回落 error")
    }

    // ⚠️ Epic-6 T1.4 追加：parseRenderDone 解析 sourceMap 字段（数组透传不解析；缺失回落空数组）
    func testParseRenderDoneSourceMap() {
        let body: [String: Any] = ["status": "ok", "scrollHeight": 100, "elapsed": 1,
                                   "sourceMap": ["1:1-2:5", "3:1-4:9"]]
        let payload = PreviewWebView.parseRenderDone(body)
        XCTAssertEqual(payload.sourceMap, ["1:1-2:5", "3:1-4:9"], "sourceMap 数组透传不解析")
        let missing = PreviewWebView.parseRenderDone(["status": "ok"])
        XCTAssertEqual(missing.sourceMap, [], "缺失 sourceMap 回落空数组")
    }

    func testJsStringEscaping() {
        let input = "say \"hi\"\nline2\\path"
        let escaped = PreviewWebView.jsString(input)
        XCTAssertEqual(escaped, "\"say \\\"hi\\\"\\nline2\\\\path\"")
    }

    // ⚠️ deep-analysis 条件项修复（T5.4-DA）：didFinish → onPageLoaded（启动主题重放闭合 FR-105）
    func testOnPageLoadedFiresOnDidFinish() {
        let view = PreviewWebView()
        var fired = false
        view.onPageLoaded = { fired = true }
        view.webView(view.webView, didFinish: nil)
        XCTAssertTrue(fired, "webView(_:didFinish:) 应触发 onPageLoaded 回调")
    }

    // ⚠️ 新增（focus-fix，根因 3）：未就绪时 setTheme/setContent 缓冲而非 evaluate——
    // 修复前首帧 evaluateJavaScript 抛 ReferenceError → onErrorOccurred 噪声（用户日志证据）
    @MainActor
    func testSetThemeBeforeLoadBuffers() {
        let view = PreviewWebView()
        var errors: [(String, String)] = []
        view.onErrorOccurred = { phase, message in errors.append((phase, message)) }
        view.setTheme(.dark)          // 未就绪 → 缓冲
        view.setContent("<p>hi</p>")  // 未就绪 → 缓冲
        XCTAssertEqual(view.evaluateCallCount, 0, "未就绪调用必须缓冲而非 evaluate（⚠️ 修订 MINOR #6：计数断言补强——errors.isEmpty 依赖异步错误回调时序，可能假阳性）")
        XCTAssertTrue(errors.isEmpty, "未就绪调用应缓冲而非 evaluateJavaScript（不得产生错误上报）")
    }

    // ⚠️ 新增（focus-fix，根因 3）：didFinish 后 flush 缓冲——theme + content 各一次 evaluate。
    // ⚠️ 修订 MINOR #5：不依赖 onErrorOccurred 作为 evaluate 证据（平台行为变化时挂起）——
    // 改用测试可见的 internal evaluateCallCount 计数器（确定性证据）
    @MainActor
    func testDidFinishFlushesPendingCalls() {
        let view = PreviewWebView()
        view.setTheme(.dark)          // 缓冲（未就绪）——不应触发 evaluate
        view.setContent("<p>hi</p>")  // 缓冲（未就绪）——不应触发 evaluate
        XCTAssertEqual(view.evaluateCallCount, 0, "flush 前不得有 evaluate")
        view.webView(view.webView, didFinish: nil)   // 置就绪 + flush
        XCTAssertEqual(view.evaluateCallCount, 2, "flush 应恰好触发两次 evaluate（theme + content 各一）")
    }

    // ⚠️ 新增（round5 T1.2）：缩放 clamp 纯函数——0.5x~3.0x 边界 + NaN 兜底
    @MainActor
    func testClampedZoomRanges() {
        XCTAssertEqual(PreviewWebView.clampedZoom(1.0), 1.0, "默认系数不变")
        XCTAssertEqual(PreviewWebView.clampedZoom(0.5), 0.5, "下限边界保持")
        XCTAssertEqual(PreviewWebView.clampedZoom(3.0), 3.0, "上限边界保持")
        XCTAssertEqual(PreviewWebView.clampedZoom(0.1), 0.5, "低于下限 clamp 到 0.5x")
        XCTAssertEqual(PreviewWebView.clampedZoom(9.9), 3.0, "高于上限 clamp 到 3.0x")
        XCTAssertEqual(PreviewWebView.clampedZoom(.nan), 1.0, "NaN 回落 1.0（isFinite 兜底）")
        // ⚠️ 修订 MINOR #5：补齐 ±Infinity/0/负值边界
        XCTAssertEqual(PreviewWebView.clampedZoom(.infinity), 1.0, "+Infinity 回落 1.0（isFinite 兜底）")
        XCTAssertEqual(PreviewWebView.clampedZoom(-.infinity), 1.0, "-Infinity 回落 1.0（isFinite 兜底）")
        XCTAssertEqual(PreviewWebView.clampedZoom(0), 0.5, "0 clamp 到下限 0.5x")
        XCTAssertEqual(PreviewWebView.clampedZoom(-5.0), 0.5, "负值 clamp 到下限 0.5x")
    }

    // ⚠️ 新增（round5 T1.2）：实例状态——zoomIn/zoomOut/zoomReset 更新 currentZoom 且 clamp；
    // 未就绪时 evaluate 受 pageLoaded 守卫（与 setViewport 一致，防 ReferenceError 噪声）
    @MainActor
    func testZoomStateAndPageLoadedGuard() {
        let view = PreviewWebView()
        XCTAssertEqual(view.currentZoom, 1.0, "初始 100%")
        view.zoomIn()
        XCTAssertEqual(view.currentZoom, 1.2, "放大 ×1.2")
        view.zoomIn()
        XCTAssertEqual(view.currentZoom, 1.44, "连续放大累积")
        view.setZoom(100)
        XCTAssertEqual(view.currentZoom, 3.0, "超上限 clamp 到 3.0x")
        view.zoomOut()
        XCTAssertEqual(view.currentZoom, 2.5, "缩小 ÷1.2（3.0/1.2 = 2.5）")
        view.zoomReset()
        XCTAssertEqual(view.currentZoom, 1.0, "重置回 100%")
        XCTAssertEqual(view.evaluateCallCount, 0, "未就绪时 evaluate 被守卫拦截（evaluateCallCount 不增）")
    }

    // ⚠️ 新增（round5 T1.2，盲审 MINOR #5 补齐）：就绪后 setZoom 确实 evaluate——
    // didFinish 后缩放下发 web 端；幂等守卫（MINOR #3）同值不重复 evaluate
    @MainActor
    func testSetZoomAfterPageLoadedEvaluates() {
        let view = PreviewWebView()
        view.webView(view.webView, didFinish: nil)
        view.setZoom(1.5)
        XCTAssertEqual(view.currentZoom, 1.5)
        XCTAssertEqual(view.evaluateCallCount, 1, "就绪后 setZoom 应 evaluate 一次")
        view.setZoom(1.5)
        XCTAssertEqual(view.evaluateCallCount, 1, "幂等守卫：clamp 后同值不重复 evaluate")
        view.setZoom(9.9)
        XCTAssertEqual(view.currentZoom, 3.0, "clamp 生效")
        XCTAssertEqual(view.evaluateCallCount, 2, "clamp 后值变化仍需 evaluate")
    }

    // ⚠️ 新增（round5 T1.2，盲审 IMPORTANT #1 修复验证）：未就绪缩放后 didFinish 重放——
    // currentZoom != 1.0 时补发 window.setZoom，Swift 状态与 web 视图不再分叉
    @MainActor
    func testDidFinishReplaysZoomState() {
        let view = PreviewWebView()
        view.zoomIn()   // 未就绪：状态 1.2，evaluate 被守卫拦截
        XCTAssertEqual(view.currentZoom, 1.2)
        XCTAssertEqual(view.evaluateCallCount, 0)
        view.webView(view.webView, didFinish: nil)
        XCTAssertEqual(view.evaluateCallCount, 1, "didFinish 应重放 window.setZoom(1.2)")
        XCTAssertEqual(view.currentZoom, 1.2, "重放后状态保持 1.2")
    }

    // ⚠️ S-025（FR-029）追加：导航兜底策略（file:// 放行 / 外链拒绝）
    @MainActor
    func testNavigationPolicyAllowsFileURL() {
        let fileURL = URL(string: "file:///Users/x/WebAssets/preview.html")!
        XCTAssertEqual(PreviewWebView.navigationPolicy(for: fileURL), .allow, "初始加载 file:// 放行")
    }

    @MainActor
    func testNavigationPolicyCancelsExternal() {
        XCTAssertEqual(PreviewWebView.navigationPolicy(for: URL(string: "https://example.com")!), .cancel, "外链拒绝（FR-029 兜底）")
        XCTAssertEqual(PreviewWebView.navigationPolicy(for: URL(string: "about:blank")!), .cancel, "about 拒绝")
    }

    // ⚠️ S-026（FR-035/046）追加：setConfig 缓冲/下发 + configJS 序列化

    @MainActor
    func testSetConfigBeforeLoadBuffers() {
        let view = PreviewWebView()
        view.setConfig(PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false))
        XCTAssertEqual(view.evaluateCallCount, 0, "未就绪缓冲（不得 evaluate）")
        XCTAssertEqual(view.receivedConfig,
                       PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false),
                       "状态先行记录（测试确定性证据）")
    }

    @MainActor
    func testDidFinishFlushesPendingConfig() {
        let view = PreviewWebView()
        view.setConfig(PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false))
        XCTAssertEqual(view.evaluateCallCount, 0, "flush 前不得有 evaluate")
        view.webView(view.webView, didFinish: nil)
        XCTAssertEqual(view.evaluateCallCount, 1, "didFinish flush setConfig 一次")
    }

    @MainActor
    func testSetConfigAfterLoadEvaluates() {
        let view = PreviewWebView()
        view.webView(view.webView, didFinish: nil)
        view.setConfig(PreviewConfig(mermaidTheme: "neutral", katexSingleDollar: true))
        XCTAssertEqual(view.evaluateCallCount, 1, "就绪后 setConfig evaluate 一次")
    }

    @MainActor
    func testConfigJSSerialization() {
        let js = PreviewWebView.configJS(PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false))
        XCTAssertEqual(js, "{\"mermaidTheme\":\"forest\",\"katexSingleDollar\":false}", "JS 对象字面量契约")
        let jsDefault = PreviewWebView.configJS(PreviewConfig(mermaidTheme: "default", katexSingleDollar: true))
        XCTAssertEqual(jsDefault, "{\"mermaidTheme\":\"default\",\"katexSingleDollar\":true}")
    }

    // ⚠️ S-027（FR-086）追加：预览字体（setFont 缓冲/下发——evaluateCallCount 确定性证据）

    @MainActor
    func testSetFontBeforeLoadBuffers() {
        let view = PreviewWebView()
        view.setFont(fontFamily: "Menlo", codeFontFamily: "ui-monospace, Menlo, monospace")
        XCTAssertEqual(view.evaluateCallCount, 0, "未就绪缓冲（不得 evaluate）")
    }

    @MainActor
    func testDidFinishFlushesPendingFont() {
        let view = PreviewWebView()
        view.setFont(fontFamily: "Menlo", codeFontFamily: "ui-monospace, Menlo, monospace")
        XCTAssertEqual(view.evaluateCallCount, 0, "flush 前不得有 evaluate")
        view.webView(view.webView, didFinish: nil)
        XCTAssertEqual(view.evaluateCallCount, 1, "didFinish flush setFont 一次")
    }

    @MainActor
    func testSetFontAfterLoadEvaluates() {
        let view = PreviewWebView()
        view.webView(view.webView, didFinish: nil)
        view.setFont(fontFamily: "Menlo", codeFontFamily: "ui-monospace, Menlo, monospace")
        XCTAssertEqual(view.evaluateCallCount, 1, "就绪后 setFont evaluate 一次")
    }

    // ⚠️ Epic-5 P3（backlog）追加：linkClicked scheme 白名单

    @MainActor
    func testIsOpenableSchemeAllowsHttpHttpsMailto() {
        XCTAssertTrue(PreviewWebView.isOpenableScheme(URL(string: "https://example.com")!))
        XCTAssertTrue(PreviewWebView.isOpenableScheme(URL(string: "http://example.com")!))
        XCTAssertTrue(PreviewWebView.isOpenableScheme(URL(string: "mailto:a@b.com")!))
    }

    @MainActor
    func testIsOpenableSchemeDeniesOthers() {
        XCTAssertFalse(PreviewWebView.isOpenableScheme(URL(string: "file:///tmp/a.md")!))
        XCTAssertFalse(PreviewWebView.isOpenableScheme(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(PreviewWebView.isOpenableScheme(URL(string: "ftp://x.com")!))
        XCTAssertFalse(PreviewWebView.isOpenableScheme(URL(string: "not-a-scheme")!))
    }

    // ⚠️ 收尾批次（清理④）追加：setConfig 相等跳过——evaluate 计数不变（幂等去冗余）
    @MainActor
    func testSetConfigEqualValueSkipsEvaluate() {
        let view = PreviewWebView()
        view.webView(view.webView, didFinish: nil)
        let config = PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false)
        view.setConfig(config)
        XCTAssertEqual(view.evaluateCallCount, 1, "首次下发 evaluate 一次")
        view.setConfig(config)
        XCTAssertEqual(view.evaluateCallCount, 1, "相等配置跳过 evaluate（计数不变）")
    }

    @MainActor
    func testSetConfigChangedAfterSkipEvaluatesAgain() {
        let view = PreviewWebView()
        view.webView(view.webView, didFinish: nil)
        view.setConfig(PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false))
        view.setConfig(PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false))
        XCTAssertEqual(view.evaluateCallCount, 1, "相同值两次仅 evaluate 一次")
        view.setConfig(PreviewConfig(mermaidTheme: "neutral", katexSingleDollar: true))
        XCTAssertEqual(view.evaluateCallCount, 2, "值变化仍需 evaluate")
    }

    // ⚠️ 收尾批次（清理④）追加：缓冲→flush→再同值 跨边界去重——flush 直发绕过相等守卫后
    // lastConfig 仍为 A → 就绪后同值再下发应被拦截（lastConfig 须在 pageLoaded guard 之前写入）
    @MainActor
    func testSetConfigBufferFlushThenSameValueSkips() {
        let view = PreviewWebView()
        let config = PreviewConfig(mermaidTheme: "forest", katexSingleDollar: false)
        view.setConfig(config)                      // 未就绪：缓冲（lastConfig = A）
        view.webView(view.webView, didFinish: nil)  // flush 直发 → evaluate #1
        XCTAssertEqual(view.evaluateCallCount, 1, "缓冲配置 flush 直发 evaluate 一次")
        view.setConfig(config)                      // 就绪后再同值 → 相等守卫拦截
        XCTAssertEqual(view.evaluateCallCount, 1, "flush 后再同值跳过 evaluate（跨边界去重）")
    }
}
