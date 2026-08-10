import Foundation

// ErrorHandling.swift — 渲染管线贯穿式错误处理（S-010，NFR-012，TOP 3 关注项 3）
// 类型化错误 + 统一降级路由 + 错误占位（非空白）；友好提示增强在 S-019（Epic-2）
enum RenderError: Error {
    case down(String)      // 阶段 2 Down 解析异常
    case js(String)        // 阶段 4/5 JS 侧异常（MessageBridge 上报）
    case timeout(String)   // renderDone 超时（设计 §7：~1s 跳过，不阻塞输入）
}

struct ErrorHandling {
    /// 错误上报回调（状态栏提示基础，NFR-012）
    var onReport: ((RenderError) -> Void)?

    /// 统一降级入口：日志 + 回调
    func fail(_ error: RenderError) {
        NSLog("[RenderPipeline] %@", String(describing: error))
        onReport?(error)
    }

    /// 错误占位 HTML（非空白：预览显示错误提示而非空屏，设计 §7）
    /// - Parameter message: 已转义的安全消息
    func placeholderHTML(_ message: String) -> String {
        let safe = Self.escape(message)
        return "<div class=\"render-error\">Render error: \(safe)</div>"
    }

    /// 阶段计时合计（NFR-001 端到端埋点辅助）
    static func totalDuration(_ metrics: [(stage: String, duration: TimeInterval)]) -> TimeInterval {
        metrics.reduce(0) { $0 + $1.duration }
    }

    /// HTML 转义（占位消息防注入）
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
