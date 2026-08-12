import WebKit

// PreviewWebView.swift — WKWebView 封装（S-009，AD-5/AD-9，FR-011）
// POC S-002/S-003 模式搬用：@MainActor、loadFileURL+allowingReadAccessTo、jsString 转义
// 实现 PreviewProtocol（设计 §5.1 消息 schema 两端契约的 Swift 侧）
@MainActor
final class PreviewWebView: NSObject, PreviewProtocol, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView

    /// 进程池单例（批次1 内存优化 / design §批次1 根因①）：
    /// 所有 PreviewWebView 共享同一 WKProcessPool，避免 Apple 默认每实例新建
    /// WebContent 进程导致内存随窗口数线性增长。Apple 多 WKWebView 标准模式。
    /// Shared process pool singleton — Apple standard pattern for multi-WKWebView apps.
    static let sharedProcessPool = WKProcessPool()

    // Web → Swift 三回调（设计 §5.1）
    var onRenderDone: ((RenderDonePayload) -> Void)?
    var onLinkClicked: ((URL) -> Void)?
    var onErrorOccurred: ((String, String) -> Void)?
    /// 页面加载完成回调（启动主题重放用，deep-analysis 条件项修复）
    var onPageLoaded: (() -> Void)?

    // ⚠️ 修复（focus-fix，根因 3）：页面就绪缓冲——WKWebView 异步加载，容器 init 的
    // theme.apply() 早于 didFinish → 未就绪 evaluateJavaScript → ReferenceError
    //（window.setTheme 未定义）→ errorOccurred 噪声（用户日志 "JavaScript exception" 证据）。
    // 未就绪调用暂存，didFinish 后 flush
    private var pageLoaded = false
    private var pendingTheme: ThemeMode?
    private var pendingConfig: PreviewConfig?   // ⚠️ S-026：配置缓冲（未就绪时暂存，didFinish flush）
    // ⚠️ S-027：预览字体缓冲（未就绪暂存，didFinish flush——与 pendingConfig 同模式）
    private var pendingFont: (fontFamily: String, codeFontFamily: String)?
    private var pendingContent: String?
    /// ⚠️ 修订 MINOR #5：evaluate 调用计数（internal，测试确定性证据——替代依赖 onErrorOccurred 的平台行为假设）
    var evaluateCallCount = 0
    /// ⚠️ S-026：最近一次请求的预览配置（状态先行——guard 前记录，未就绪未下发也记录；internal，测试确定性证据——MainContentStateTests 断言 init 下发）
    internal private(set) var receivedConfig: PreviewConfig?
    /// ⚠️ 收尾批次（清理④）：最近一次已受理配置（变更检测基准——相等跳过 evaluate）
    private var lastConfig: PreviewConfig?

    private let contentController = WKUserContentController()

    override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool   // 批次1：共享进程池（内存优化，design §批次1 根因①）
        config.userContentController = contentController
        config.websiteDataStore = .nonPersistent()   // 离线单机，无缓存残留
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        // 注册消息 handler（命名空间：MessageBridge，AD-9）
        // 修复：WeakScriptMessageDelegate 弱代理——WKUserContentController 强持有 handler，
        // 直接 add(self) 构成 self→webView→configuration→contentController→self 保留环；
        // 代理弱持有 self 断环（Apple 标准模式）——断环后 deinit 可达，
        // 移除清理为冗余兜底（收尾批次清理②，Edit 1 已删）
        contentController.add(WeakScriptMessageDelegate(self), name: MessageName.renderDone.rawValue)
        contentController.add(WeakScriptMessageDelegate(self), name: MessageName.linkClicked.rawValue)
        contentController.add(WeakScriptMessageDelegate(self), name: MessageName.errorOccurred.rawValue)
        // deep-analysis 条件项修复：loadPreview() 之前设置导航委托（页面就绪回调挂接点）
        webView.navigationDelegate = self
        loadPreview()
        setupPinchGesture()   // ⚠️ round7 T1.2：触控板捏合缩放手势（根因 2）
    }

    /// 显式 teardown（关闭窗口时调用——WKWebView 在 JS 在途时 dealloc 是 WebKit
    /// 间歇崩溃源；停载 + 移除 handler + 置空回调，再随 state 释放）
    func teardown() {
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.gestureRecognizers.forEach { webView.removeGestureRecognizer($0) }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        onRenderDone = nil
        onLinkClicked = nil
        onErrorOccurred = nil
        onPageLoaded = nil
    }

    // 批次1 内存诊断埋点（D3）：验证 PreviewWebView 实例随窗口关闭释放。
    // 手动开关窗 5 次 → Console 观察 [LEAK] 日志计数应与开关次数一致。
    // 验证通过后可保留（仅 NSLog 无副作用）或删除。
    // Leak probe (batch 1, D3): verify instance dealloc on window close.
    deinit {
        MainActor.assumeIsolated { teardown() }
        MainActor.assumeIsolated {
            NSLog("[LEAK] PreviewWebView dealloc")
        }
    }

    // MARK: - 加载（AD-5：loadFileURL + allowingReadAccessTo，POC S-002 验证）

    private func loadPreview() {
        guard let assets = Bundle.main.resourceURL?.appendingPathComponent("WebAssets", isDirectory: true) else {
            NSLog("[DIAG-WEB] loadPreview FAILED: WebAssets not found, resourceURL=%@", String(describing: Bundle.main.resourceURL))
            return
        }
        let indexURL = assets.appendingPathComponent("preview.html")
        NSLog("[DIAG-WEB] loadPreview url=%@ exists=%d", indexURL.path, FileManager.default.fileExists(atPath: indexURL.path) ? 1 : 0)
        // ⚠️ 修复（archive/安装版白屏根因）：allowingReadAccessTo 传根目录 "/"——
        // 之前传 NSHomeDirectory() 只覆盖主目录前缀：app 装在 /Applications（主目录外）时
        // WebKit 沙箱拒绝加载 preview.html（didFinish 不触发 → 内容缓冲 → 白屏）。
        // 根目录同时覆盖 app bundle（/Applications）与本地图片（/Users/...）；
        // 个人工具（ENABLE_APP_SANDBOX=NO）安全可接受
        webView.loadFileURL(indexURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: - PreviewProtocol（Swift → Web，AD-9 evaluateJavaScript）

    func setContent(_ html: String) {
        // ⚠️ focus-fix：未就绪时缓冲（didFinish 后 flush），消除首帧 ReferenceError
        guard pageLoaded else { pendingContent = html; return }
        evaluate("window.setContent(\(Self.jsString(html)))")
    }

    func setTheme(_ mode: ThemeMode) {
        // ⚠️ focus-fix：未就绪时缓冲（didFinish 后 flush）
        guard pageLoaded else { pendingTheme = mode; return }
        evaluate("window.setTheme(\(Self.jsString(mode.rawValue)))")
    }

    func setConfig(_ config: PreviewConfig) {
        // ⚠️ S-026：状态先行（测试确定性证据；未就绪也记录）+ 未就绪缓冲（与 setTheme 同模式）
        receivedConfig = config
        // ⚠️ 收尾批次（清理④）：与上次相等 → 跳过 evaluate（幂等下发去冗余——
        // 面板/容器双 PreviewSettings 实例的广播重读常下发同值配置）
        guard config != lastConfig else { return }
        lastConfig = config
        guard pageLoaded else { pendingConfig = config; return }
        evaluate("window.setConfig(\(Self.configJS(config)))")
    }

    /// 预览字体（S-027，FR-086）：CSS 变量 --font-family/--code-font-family 切换。
    /// ⚠️ 不走 setContent——morphdom 同源跳过会拦截未变化内容，字体不生效（设计 §S-027）；
    /// evaluate 失败走现有 errorOccurred 通道（NFR-012）
    func setFont(fontFamily: String, codeFontFamily: String) {
        guard pageLoaded else { pendingFont = (fontFamily, codeFontFamily); return }
        evaluate("window.setFont(\(Self.jsString(fontFamily)), \(Self.jsString(codeFontFamily)))")
    }

    /// 纯函数（可测）：PreviewConfig → JS 对象字面量（契约：window.setConfig({mermaidTheme, katexSingleDollar})）
    static func configJS(_ config: PreviewConfig) -> String {
        "{\"mermaidTheme\":\(jsString(config.mermaidTheme)),\"katexSingleDollar\":\(config.katexSingleDollar)}"
    }

    func setViewport(_ scrollTop: Double) {
        // ⚠️ 修订 IMPORTANT #4：未就绪时丢弃（滚动缓冲无意义，首帧窗口极小）——
        // 防页面未就绪时滚动触发 ReferenceError 噪声（与用户日志同类）
        guard pageLoaded else { return }
        evaluate("window.setViewport(\(scrollTop))")
    }

    /// 精确滚动同步（S-032/T1.4）：window.setScrollToSource(startLine, endLine)
    /// （T1.5 已交付 JS 入口；source map 命中块 → 精确行定位）
    /// 与 setViewport 同守卫：未就绪时丢弃（防 ReferenceError 噪声，根因 3 同类）
    func setViewportSource(_ startLine: Int, _ endLine: Int) {
        guard pageLoaded else { return }
        evaluate("window.setScrollToSource(\(startLine), \(endLine))")
    }

    // MARK: - 预览缩放（round5 T1.2）

    /// 当前缩放系数（1.0 = 100%；clamped 0.5~3.0）——Swift 侧状态先行，evaluate 仅下发
    private(set) var currentZoom: Double = 1.0
    /// ⚠️ 第七轮修复（round7 T1.2，根因 2）：捏合基准 zoom——手势 .began 时记录，
    /// .changed 期间按 baseZoom × (1 + magnification) 连续计算（相对捏合起点缩放）
    private var pinchBaseZoom: Double = 1.0

    /// 缩放 clamp 纯函数（可测）：0.5x ~ 3.0x；NaN/Infinity 回落 1.0（与 JS 侧 Math 契约对齐）
    static func clampedZoom(_ factor: Double) -> Double {
        let f = factor.isFinite ? factor : 1.0
        return min(max(f, 0.5), 3.0)
    }

    /// 设置缩放：状态先行（UI 立即响应）；evaluate 受 pageLoaded 守卫——
    /// 未就绪仅更新状态不 evaluate（didFinish 时重放，见 webView(_:didFinish:)），
    /// 防 ReferenceError 噪声的同时避免 Swift 状态与 web 视图分叉
    func setZoom(_ factor: Double) {
        // ⚠️ 修复 round5 盲审 MINOR #3：幂等守卫——clamp 后不变则跳过
        //（3.0×1.2 → clamp 3.0 不再冗余 evaluate）；didFinish 重放路径直接 evaluate 绕开守卫
        let clamped = Self.clampedZoom(factor)
        guard clamped != currentZoom else { return }
        currentZoom = clamped
        guard pageLoaded else { return }
        evaluate("window.setZoom(\(currentZoom))")
    }

    /// 放大 ×1.2（上限 3.0x，clampedZoom 兜底）
    func zoomIn() { setZoom(currentZoom * 1.2) }
    /// 缩小 ÷1.2（下限 0.5x，clampedZoom 兜底）
    func zoomOut() { setZoom(currentZoom / 1.2) }
    /// 重置 100%
    func zoomReset() { setZoom(1.0) }

    // MARK: - 捏合缩放手势（round7 T1.2，根因 2）

    /// 注册触控板捏合手势（NSMagnificationGestureRecognizer）到 webView；
    /// allowsMagnification 显式置 false（默认即 false，显式化防 SDK 默认变化）——
    /// 禁用 WKWebView 原生缩放，避免与 CSS zoom 叠加（设计 §3.3）
    private func setupPinchGesture() {
        webView.allowsMagnification = false
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        webView.addGestureRecognizer(pinch)
    }

    /// 捏合处理：.began 记录基准 zoom；.changed 期间按 baseZoom × (1 + magnification)
    /// 连续缩放（显式 clampedZoom 0.5-3x 复用，与按钮/快捷键同一 setZoom 体系）；
    /// .ended/.cancelled 不动作——状态已在 changed 期间同步，保持当前 zoom
    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseZoom = currentZoom
        case .changed:
            setZoom(Self.clampedZoom(pinchBaseZoom * Double(1 + gesture.magnification)))
        default:
            break   // ended/cancelled：保持当前 zoom
        }
    }

    /// 错误上报（NFR-012：JS 侧 errorOccurred 的 Swift 主动入口）
    func reportError(phase: String, message: String) {
        // ⚠️ 修订 B2：未就绪时丢弃（与 setViewport 一致）——window.reportError 未定义时 evaluate 触发 ReferenceError 噪声（根因 3 同类）
        guard pageLoaded else { return }
        evaluate("window.reportError(\(Self.jsString(phase)), \(Self.jsString(message)))")
    }

    private func evaluate(_ js: String) {
        evaluateCallCount += 1   // evaluate 实际执行证据（测试确定性）
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                self?.onErrorOccurred?("evaluateJavaScript", error.localizedDescription)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    // MARK: - WKNavigationDelegate（S-025，FR-029 兜底）

    /// 导航策略纯函数（可测）：file:// 放行；外链拒绝——JS preventDefault 失效时
    /// 外链不接管 webview（MainApp onLinkClicked → NSWorkspace.open 链路保持，FR-029）
    static func navigationPolicy(for url: URL) -> WKNavigationActionPolicy {
        url.scheme?.lowercased() == "file" ? .allow : .cancel
    }

    /// ⚠️ Epic-5 P3（backlog）：linkClicked scheme 白名单——http/https/mailto 放行，
    /// 其余拒绝（防自定义 scheme 意外唤起系统应用；navigationPolicy 先例同构）
    static func isOpenableScheme(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return true
        default: return false
        }
    }

    /// ⚠️ S-025 兜底：非 file:// 导航拒绝（页面内锚点/初始加载均为 file:// 放行；http/https/about 拒绝）
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            decisionHandler(Self.navigationPolicy(for: url))
        } else {
            decisionHandler(.allow)   // 无 URL 导航（罕见）放行
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[DIAG-WEB] didFinish url=%@", String(describing: webView.url))
        // ⚠️ focus-fix（根因 3）：置就绪 + flush 缓冲（theme 先于 content，与调用序一致）；
        // flush 先于 onPageLoaded——onPageLoaded 的 themeService.apply() 重放此时直接
        // evaluate（不再二次缓冲），幂等覆盖为当前主题
        pageLoaded = true
        if let theme = pendingTheme { setTheme(theme); pendingTheme = nil }
        // ⚠️ 收尾批次（清理④）：flush 直发绕开变更检测——pendingConfig 缓冲时已写入 lastConfig，
        // 走 setConfig 会被相等守卫拦截 → JS 永不收到配置（setZoom 重放直发先例同构）；
        // 配置先于内容 flush
        if let config = pendingConfig {
            evaluate("window.setConfig(\(Self.configJS(config)))")
            pendingConfig = nil
        }
        if let font = pendingFont { setFont(fontFamily: font.fontFamily, codeFontFamily: font.codeFontFamily); pendingFont = nil }   // ⚠️ S-027：字体先于内容 flush（CSS 变量先就位）
        if let content = pendingContent { setContent(content); pendingContent = nil }
        // ⚠️ 修复 round5 盲审 IMPORTANT #1：缩放状态重放——未就绪时 setZoom 只更新状态
        // 不 evaluate（工具栏加载期间即可点击），didFinish 时 currentZoom != 1.0 补发，
        // 否则 Swift 按 1.44×1.2 继续下发而 web 端从未经过 1.2/1.44 → 预览跳变、状态永久分叉
        if currentZoom != 1.0 { evaluate("window.setZoom(\(currentZoom))") }
        onPageLoaded?()
    }

    // ⚠️ 修订 B3：加载失败上报——loadFileURL 失败时 pageLoaded 永 false → 缓冲永不清空、onPageLoaded 永不触发（静默卡死）；本地文件缺失通常走 didFailProvisionalNavigation，两入口都实现
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onErrorOccurred?("didFail", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        onErrorOccurred?("didFailProvisionalNavigation", error.localizedDescription)
    }

    // MARK: - WKScriptMessageHandler（Web → Swift）

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let name = MessageName(rawValue: message.name) else { return }
        switch name {
        case .renderDone:
            onRenderDone?(Self.parseRenderDone(message.body))
        case .linkClicked:
            if let dict = message.body as? [String: Any],
               let href = dict["href"] as? String,
               let url = URL(string: href) {
                onLinkClicked?(url)
            }
        case .errorOccurred:
            if let dict = message.body as? [String: Any] {
                onErrorOccurred?(dict["phase"] as? String ?? "unknown",
                                 dict["message"] as? String ?? "")
            }
        }
    }

    // MARK: - schema 解析（设计 §5.1 锁定；静态方法便于 XCTest 覆盖）

    static func parseRenderDone(_ body: Any) -> RenderDonePayload {
        let dict = body as? [String: Any]
        return RenderDonePayload(
            status: dict?["status"] as? String ?? "error",
            error: dict?["error"] as? String,
            scrollHeight: (dict?["scrollHeight"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: (dict?["elapsed"] as? NSNumber)?.doubleValue ?? 0,
            sourceMap: dict?["sourceMap"] as? [String] ?? []   // ⚠️ Epic-6 T1.4：数组透传不解析（ScrollSync 消费）
        )
    }

    /// POC jsString 直接搬用：转义为 JS 字符串字面量
    static func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    enum MessageName: String {
        case renderDone, linkClicked, errorOccurred
    }
}

/// 弱代理：WKUserContentController 强持有注册 handler，直接 add(self) 形成保留环；
/// 代理弱持有 self 断环后 deinit 可达（移除清理已在收尾批次清理②删除，contentController 随 self 释放）。
@MainActor
private final class WeakScriptMessageDelegate: NSObject, WKScriptMessageHandler {
    weak var handler: WKScriptMessageHandler?

    init(_ handler: WKScriptMessageHandler) {
        self.handler = handler
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        handler?.userContentController(userContentController, didReceive: message)
    }
}
