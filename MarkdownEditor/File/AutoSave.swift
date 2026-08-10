import AppKit

// AutoSave.swift — 自动保存调度器（S-030，FR-075：失焦 + 每 30s 定时，仅已保存路径文件）
// 调度职责（didResignKey + Timer）；触发判定/落盘在 FileOperations.autoSave（fileURL != nil 检查）
// WindowCloseGuard 同构挂接：Batch 7 在 install(on:state:) 调用 attach(to: window)
// Scheduler only; the actual write decision lives in FileOperations.autoSave.
// ⚠️ T4.2（FR-077）mtime 刷新防护挂接点：AutoSave 的写盘经 FileOperations.autoSave →
// Document.write（写盘成功后刷新 lastSavedMtime，与手动保存同链路）——自动保存后检测基准
// 同步更新，防"自触自警"（自动保存写盘改变 mtime 被 didBecomeKey 外改检测误判为外部修改）。
// 挂接点在写盘链路（Document.write），调度器本身不落盘，无需额外动作。
@MainActor
final class AutoSave {
    /// 保存触发出口（Batch 7 接 fileOps.autoSave——仅已保存路径，保留 edited 标记；
    /// T4.2：写盘内部经 Document.write 刷新 lastSavedMtime，mtime 防护随链路生效）
    var onAutoSave: (() -> Void)?

    private let interval: TimeInterval
    private var timer: Timer?
    private weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    /// 挂接窗口（失焦 + 关闭停止；幂等——内部先 detach，窗口迁移场景安全）
    func attach(to window: NSWindow) {
        detach()
        self.window = window
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated { self?.trigger() }   // 失焦即保存（FR-075）
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }    // 窗口关闭停止调度
            },
        ]
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger() }       // 30s 定时（FR-075）
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 停止调度（观察者移除 + Timer 失效；CWE-772 防泄漏）
    func detach() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        timer?.invalidate()
        timer = nil
        window = nil
    }

    private func trigger() {
        guard onAutoSave != nil else { return }
        onAutoSave?()
    }

    deinit {
        MainActor.assumeIsolated {
            // 批次1 内存诊断埋点(D3):验证 AutoSave(Timer 持有者)随窗口关闭释放
            // Leak probe (batch 1, D3): verify AutoSave (Timer owner) dealloc on window close.
            NSLog("[LEAK] AutoSave dealloc")
            detach()
        }
    }
}
