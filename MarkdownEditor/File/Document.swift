import AppKit
import UniformTypeIdentifiers   // ⚠️ 修复 C：UTType 需要此 import（NSSavePanel.allowedContentTypes）

// Document.swift — NSDocument 子类（S-014，FR-071~076，NFR-011）
// 决策：MVP 不采用 DocumentGroup（与自定义 NSSplitView 窗口体系冲突）；
// 复用 NSDocument 的 updateChangeCount/isDocumentEdited 支撑"已修改"状态与关闭确认
// ⚠️ 遗留 #2（批次 1）：CloseConfirming 注入——模态 runModal 不可自动化（零单测），
// 协议抽离 + saveFlow 纯逻辑抽离；生产路径 = SystemCloseConfirmer（NSAlert.runModal 语义不变）

// 关闭确认协议（FR-076）：生产实现 SystemCloseConfirmer = NSAlert.runModal；
// 测试注入 mock 返回序列（保存/不保存/取消/写盘失败 beep）
/// ⚠️ Swift 6：@MainActor（NSAlert 调用隔离；测试 Mock 同步标注）
@MainActor
protocol CloseConfirming {
    func confirm(message: String, informative: String, buttons: [String]) -> NSApplication.ModalResponse
}

/// 生产实现：NSAlert 模态对话框（原 confirmCloseIfNeeded runModal 行为，逐字保持）
/// ⚠️ 修复（Release 构建）：NSAlert 为 @MainActor 隔离——非隔离调用在 Release（-O +
/// 完整并发检查）下触发运行时崩溃（Debug -Onone 侥幸工作）→ 补 @MainActor
@MainActor
struct SystemCloseConfirmer: CloseConfirming {
    func confirm(message: String, informative: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}

/// ⚠️ 修复（Release 构建）：@MainActor——NSDocument 的 text/lastSavedMtime 等属性与
/// read/write/data 方法均操作 @MainActor 隔离的 AppKit 类型；非隔离在 Release（-O +
/// 完整并发检查）下运行时崩溃（Debug -Onone 侥幸工作）→ 类级 @MainActor 统一隔离
@MainActor
final class Document: NSDocument {
    var text: String = "" {
        didSet { updateChangeCount(.changeDone) }
    }

    /// ⚠️ T4.2（FR-077）：外部修改检测基准——上次 read/write 时的文件 mtime
    ///（private(set)：仅 Document 自身可写；"保留本地"路径经 adoptExternalMtime 刷新）
    private(set) var lastSavedMtime: Date?
    /// 内容哈希基准（真机验收修复）：iCloud 桌面同步 touch mtime 导致 mtime 比对误报——
    /// 用内容哈希（FNV-1a 轻量）比对替代 mtime，内容不变即非外部修改
    private(set) var lastSavedContentHash: UInt64?

    /// 关闭确认注入点（#2）：测试替换为 mock；生产默认 SystemCloseConfirmer（语义不变）。
    /// ⚠️ 注：生产路径无任何注入（默认值即真实实现），注入仅测试可见（设计 §7 失败模式）
    var confirmer: CloseConfirming = SystemCloseConfirmer()

    override static var autosavesInPlace: Bool { false }   // MVP：手动保存（FR-073）

    /// ⚠️ 修复（真机验收）：NSDocument 的 init(contentsOf:ofType:) 依赖 NSDocumentController
    /// 参与（本 app 自管理无 controller）→ read 不触发、doc.text 恒空。改用显式 read。
    /// 自管理单文档：contentsOf → init → read(from:) 显式加载
    override init() {
        super.init()
    }

    init(contentsOf url: URL, ofType typeName: String) throws {
        NSLog("[DIAG-DOC] init contentsOf path=%@", url.path)
        super.init()
        do {
            try read(from: url, ofType: typeName)
        } catch {
            NSLog("[DIAG-DOC] read threw: %@", error.localizedDescription)
            throw error
        }
        NSLog("[DIAG-DOC] after read textLen=%d", text.count)
        fileURL = url
        displayName = url.lastPathComponent
    }

    override func makeWindowControllers() {
        // 单文档单窗口（主窗口由 MainWindowView 管理）；保留 NSDocument 注册以复用保存/关闭机制
    }

    // MARK: - 读写（UTF-8 文本）

    override func read(from url: URL, ofType typeName: String) throws {
        // ⚠️ Swift 6：NSDocument override 为 nonisolated——属性访问经 assumeIsolated
        let content = try MainActor.assumeIsolated { try String(contentsOf: url, encoding: .utf8) }
        try MainActor.assumeIsolated {
            text = content
            updateChangeCount(.changeCleared)   // 打开后不标记未保存
            // ⚠️ T4.2（FR-077）：记录基准 mtime（外部修改检测数据源；静默重载/重新加载也经此刷新）
            lastSavedMtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lastSavedContentHash = Self.contentHash(of: content)
        }
    }

    /// 轻量内容哈希（FNV-1a 64 位；外部修改检测数据源——不依赖 mtime）
    nonisolated static func contentHash(of text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "Document", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "文本编码为 UTF-8 失败"])
        }
        return data
    }

    override func write(to url: URL, ofType typeName: String) throws {
        // ⚠️ Swift 6：NSDocument override 为 nonisolated——属性访问经 assumeIsolated
        //（AppKit 对象主线程写盘，显式断言；项目先例 MarkdownTextView deinit）
        try MainActor.assumeIsolated {
            try text.write(to: url, atomically: true, encoding: .utf8)
            // ⚠️ T4.2（FR-077）：写盘成功后刷新基准 mtime——手动保存/另存为/AutoSave
            // 均经此链路（防自触自警：自动保存写盘改变 mtime 不被 didBecomeKey 外改检测误判）
            lastSavedMtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            lastSavedContentHash = Self.contentHash(of: text)
        }
    }


    /// ⚠️ T4.2（FR-077）：外部修改弹窗"保留本地"路径——刷新检测基准为当前文件 mtime
    ///（防同一外部修改在每次窗口激活时重复弹窗；下次文件再次变化才重新检测）
    func adoptExternalMtime(_ mtime: Date) {
        lastSavedMtime = mtime
    }

    // MARK: - 关闭确认辅助（FR-076，NFR-011 不丢数据）

    /// 是否有未保存修改（FileOperations/MainWindowView 关闭确认时调用）
    var hasUnsavedChanges: Bool { isDocumentEdited }

    /// 确认对话框：返回 true 表示可以关闭（已保存/放弃），false 表示取消
    /// ⚠️ 遗留 #2（批次 1）：模态经 confirmer 注入；保存流程抽离 saveFlow(to:)
    ///（FR-076 语义保持：isDocumentEdited 短路 / 三按钮顺序 / 写盘失败 beep+false）
    func confirmCloseIfNeeded() -> Bool {
        guard isDocumentEdited else { return true }
        let response = confirmer.confirm(
            message: "保存更改？",
            informative: "文档 \(displayName ?? "Untitled") 有未保存的更改。",
            buttons: ["保存", "不保存", "取消"])
        switch response {
        case .alertFirstButtonReturn:   // 保存
            return saveFlow(to: fileURL)
        case .alertSecondButtonReturn:  // 放弃
            return true
        default:                        // 取消
            return false
        }
    }

    /// 保存流程（#2 抽离）：fileURL 非 nil → 直接写盘 + 清除标记；Untitled（nil）→
    /// NSSavePanel 选路径（数据安全，原语义）。写盘失败：beep + 返回 false（FR-076）
    func saveFlow(to url: URL?) -> Bool {
        if let url {
            do {
                try write(to: url, ofType: "md")
                updateChangeCount(.changeCleared)
                return true
            } catch {
                NSSound.beep()
                return false
            }
        }
        // fileURL 为 nil（Untitled 新文档）→ 不可写 /dev/null（数据丢失），
        // 必须弹 NSSavePanel 选择路径（原 confirmCloseIfNeeded 逻辑，逐字保持）
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try write(to: url, ofType: "md")
            fileURL = url
            displayName = url.lastPathComponent   // 与 FileOperations.saveDocumentAs 一致：写盘成功后同步
            updateChangeCount(.changeCleared)
            return true
        } catch {
            NSSound.beep()
            NSLog("saveFlow 写盘失败: %@", error.localizedDescription)   // 错误可见性（行为不变：beep+false）
            return false
        }
    }
}