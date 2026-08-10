import AppKit
import UniformTypeIdentifiers   // ⚠️ 修复 #2（第 5 轮）：UTType 转换需要

// FileOperations.swift — 新建/打开/保存/另存为（S-014，FR-071/072/073；FR-076 关闭确认）
@MainActor  // ⚠️ 修复 #4（第 7 轮）：同步调用 NSDocument/NSOpenPanel/NSAlert（@MainActor）
final class FileOperations: DocumentHandling {
    /// mtime 容差（秒）：云同步/原子写 touch 的误报窗口（真机验收修复——iCloud 桌面同步
    /// 在写盘后 touch mtime，导致外部修改检测误报）
    static let mtimeTolerance: TimeInterval = 5.0

    // ⚠️ 修复 #2（第 5 轮）：allowedContentTypes 需要 [UTType]（非 [String]），
    // 直接声明 UTType 数组，避免每次 compactMap 转换
    static let supportedTypes: [UTType] = [
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
        .plainText,
    ]

    /// 当前文档（单文档生命周期）
    private(set) var currentDocument: Document?
    /// 打开/新建后回填编辑器（MainApp 挂接 → editorText binding）
    var onTextRead: ((String) -> Void)?
    // ⚠️ S-030：defaults 注入（RecentFiles 记录隔离——测试 suiteName 防真实 defaults 污染）
    let defaults: UserDefaults
    /// ⚠️ S-030：错误展示注入点（测试记录；生产默认 NSAlert.runModal——CloseConfirming 先例）
    var errorPresenter: ((Error) -> Void)?
    /// ⚠️ T4.2（FR-077）：mtime 读取注入点——测试注入模拟 clock（确定性，不依赖真实文件系统时间）；
    /// 生产默认读 URL.contentModificationDate（与 Document.read/write 同源，比对基准一致）
    var mtimeReader: ((URL) -> Date?)?
    /// ⚠️ T4.2 fix1（评审 IMPORTANT-1）：弹窗取消后的检测冷却——取消不刷新基准，
    /// 而 runModal 关闭会使窗口 re-key → didBecomeKey 再触发检测 → 无冷却则无限弹窗；
    /// 冷却窗口内重复检测直接返回 false（不弹窗），打破 re-key 循环
    private var cancelCooldownUntil: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    // ⚠️ 修复 #6（第 7 轮）：onDocumentEdited 删除——无调用点（编辑流直接
    // documentDidEdit 方法，不经过闭包），属死代码

    // MARK: - 命令（FR-071/072/073）

    // ⚠️ 适配（T5.2 实施）：DocumentHandling 协议要求无参 newDocument()——Swift 协议
    // 一致性要求精确签名匹配，带默认参数的方法无法作为协议 witness；此无参版本
    // 委托带参版本（notifyTextRead 默认 true），保持 FR-071 语义
    func newDocument() {
        newDocument(notifyTextRead: true)
    }

    // ⚠️ 修复 #5（第 5 轮）：notifyTextRead 参数——documentDidEdit 自动建文档路径
    // 传入 false，避免 onTextRead("") 清空编辑器导致首字丢失（FR-071 语义 + 无丢字）
    func newDocument(notifyTextRead: Bool = true) {
        // ⚠️ 修复（review T5.2，NFR-011）：新建前确认未保存修改（复用 FR-076 confirmCloseIfNeeded 流程）
        guard currentDocument?.confirmCloseIfNeeded() ?? true else { return }
        let doc = Document()
        doc.displayName = "Untitled.md"
        currentDocument = doc
        if notifyTextRead { onTextRead?("") }
    }

    func openDocument() {
        // ⚠️ S-030（review T4.1）：确认收敛于 open(url:)——openDocument 自身不再重复
        // confirmCloseIfNeeded，避免"不保存"路径双重确认弹窗（NFR-011 确认链路单一出口）
        // ⚠️ 修复（真机验收）：runModal 阻塞问题 → 异步 sheet（有窗口）/浮动（无窗口）
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.open(url: url)
            }
        } else {
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.open(url: url)
            }
        }
    }

    /// ⚠️ S-030：打开 URL（抽取内部方法）——NFR-011 确认链路 + 成功记录/失败移除最近文件
    func open(url: URL) {
        NSLog("[DIAG-OPEN] open url=%@", url.lastPathComponent)
        guard currentDocument?.confirmCloseIfNeeded() ?? true else {
            NSLog("[DIAG-OPEN] confirmCloseIfNeeded blocked")
            return
        }
        do {
            let doc = try Document(contentsOf: url, ofType: "md")
            NSLog("[DIAG-OPEN] doc.text len=%d", doc.text.count)
            currentDocument = doc
            RecentFiles.record(url, defaults: defaults)   // ⚠️ S-030：打开成功路径记录（FR-074）
            NSLog("[DIAG-OPEN] onTextRead len=%d", doc.text.count)
            onTextRead?(doc.text)
        } catch {
            RecentFiles.remove(url, defaults: defaults)   // 设计 §错误处理：失效 URL 从列表移除
            presentError(error)
        }
    }

    func saveDocument() {
        guard let doc = currentDocument else { newDocument(); return }
        guard let url = doc.fileURL else { saveDocumentAs(); return }
        do {
            NSLog("[DIAG-SAVE] saveDocument write url=%@", url.lastPathComponent)
            try doc.write(to: url, ofType: "md")
            NSLog("[DIAG-SAVE] after write lastSavedMtime=%@", String(describing: doc.lastSavedMtime))
            doc.updateChangeCount(.changeCleared)
            RecentFiles.record(url, defaults: defaults)   // ⚠️ S-030：保存成功路径记录（FR-074）
        } catch {
            presentError(error)
        }
    }

    func saveDocumentAs() {
        guard let doc = currentDocument else { newDocument(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.supportedTypes  // ⚠️ 修复 #8：统一 allowedContentTypes（allowedFileTypes 已废弃）
        panel.nameFieldStringValue = doc.displayName ?? "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try doc.write(to: url, ofType: "md")
            doc.fileURL = url
            doc.displayName = url.lastPathComponent
            doc.updateChangeCount(.changeCleared)
            RecentFiles.record(url, defaults: defaults)   // ⚠️ S-030：保存成功路径记录（FR-074）
        } catch {
            presentError(error)
        }
    }

    /// 编辑器文本流 → 文档（配合 RenderCoordinator.input 调用，保持未保存标记正确）
    func documentDidEdit(_ text: String) {
        guard let doc = currentDocument else {
            // 未打开文档时输入 → 自动建立 Untitled 文档（FR-071 语义）
            // ⚠️ 修复 #5（第 5 轮）：notifyTextRead: false——跳过 onTextRead("") 清空回填，
            // 否则用户刚输入的首字会被 updateNSView 回填清空
            newDocument(notifyTextRead: false)
            currentDocument?.text = text
            return
        }
        // ⚠️ 修复（review T5.2）：程序化回填内容与 doc.text 一致时跳过赋值
        //（Swift didSet 值相同仍触发 updateChangeCount(.changeDone)，导致刚打开就"已修改"）
        guard doc.text != text else { return }
        doc.text = text
    }

    // MARK: - 自动保存（S-030，FR-075）

    /// 自动保存：仅已保存路径（fileURL != nil，Untitled 不落盘）；
    /// 保留 edited 标记（不调 updateChangeCount(.changeCleared)——设计决策：关闭确认
    /// 行为一致 + 已落盘时确认框无数据损失 + 防"自动保存后继续编辑"标记混乱）；
    /// 写盘失败：NSLog + 保留标记（下次失焦/定时重试，NFR-011 不丢数据）
    func autoSave() {
        guard let doc = currentDocument, let url = doc.fileURL else { return }
        guard doc.hasUnsavedChanges else { return }   // ⚠️ review T4.1：无修改不重写（防 30s 定时 mtime 刷新/云同步误报）
        // ⚠️ T4.2 fix1（盲审 IMPORTANT-2/3，NFR-011 数据安全）+ 真机验收：写盘前比对
        // 内容哈希——外部修改后（key 窗口 30s 定时 / 弹窗期间定时）自动保存不得静默覆盖；
        // 哈希比对替代 mtime（iCloud 同步 touch mtime 不误判）
        let currentContent = try? String(contentsOf: url, encoding: .utf8)
        if let baselineHash = doc.lastSavedContentHash, let currentContent {
            let currentHash = Document.contentHash(of: currentContent)
            if currentHash != baselineHash {
                // 内容确实被外部修改 → 跳过写盘（交由 didBecomeKey 弹窗决策）
                NSLog("[AutoSave] 外部修改已检测（内容哈希不一致），跳过自动保存")
                return
            }
        }
        do {
            NSLog("[DIAG-SAVE] autoSave write url=%@", url.lastPathComponent)
            try doc.write(to: url, ofType: "md")
            NSLog("[DIAG-SAVE] autoSave after write lastSavedMtime=%@", String(describing: doc.lastSavedMtime))
        } catch {
            NSLog("[AutoSave] 写盘失败: %@", error.localizedDescription)
        }
    }

    // MARK: - 关闭确认（FR-076，NFR-011）

    /// 挂接 NSWindowDelegate.windowShouldClose
    func shouldCloseWindow() -> Bool {
        currentDocument?.confirmCloseIfNeeded() ?? true
    }

    // MARK: - 外部修改检测（T4.2，FR-077）

    /// 外部修改检测（didBecomeKey 挂接调用）——mtime 与基准（lastSavedMtime）比对：
    /// 基准存在 且 fileURL 存在 → 读取当前 mtime → 不同即外部修改：
    ///   isDocumentEdited → 三按钮弹窗（重新加载/保留本地/取消，CloseConfirming 先例，PRD FR-077 文案）
    ///   未编辑 → 静默重载（走 onTextRead 链路，read 刷新基准）
    /// - Returns: true = 检测到外部修改（已弹窗/已重载处理），false = 无修改或不可判定
    func checkExternalModification() -> Bool {
        guard let doc = currentDocument else { return false }
        guard let lastHash = doc.lastSavedContentHash else { return false }   // 未 read/未写盘过 → 不判定
        guard let url = doc.fileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // ⚠️ 修复（真机验收）：内容哈希比对替代 mtime——iCloud 桌面同步/原子写会 touch mtime
        // 导致 mtime 误报；内容不变（哈希一致）即非外部修改，无论 mtime 如何变化
        guard let currentContent = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let currentHash = Document.contentHash(of: currentContent)
        NSLog("[DIAG-EXT] check: lastHash=%llu currentHash=%llu edited=%d", lastHash, currentHash, doc.isDocumentEdited ? 1 : 0)
        guard currentHash != lastHash else { return false }
        // ⚠️ T4.2 fix1（评审 IMPORTANT-1）：取消后冷却窗口内不再弹窗——防 re-key 无限循环
        if let until = cancelCooldownUntil, Date() < until { return false }
        if doc.isDocumentEdited {
            // 冲突弹窗（FR-077 PRD 文案 + 计划三按钮；SystemCloseConfirmer 生产，测试注入 mock）
            let response = doc.confirmer.confirm(
                message: "文件已被外部修改，是否重新加载",
                informative: "文档 \(doc.displayName ?? "Untitled") 有未保存的更改。",
                buttons: ["重新加载", "保留本地", "取消"])
            switch response {
            case .alertFirstButtonReturn:   // 重新加载：丢弃本地修改，重读磁盘（read 刷新基准）
                reloadCurrentDocument()
            case .alertSecondButtonReturn:  // 保留本地：仅刷新检测基准（防同一外改重复弹窗）
                doc.adoptExternalMtime(Date())
            default:                        // 取消：本次不处理（下次窗口激活再检测）
                // ⚠️ T4.2 fix1（评审 IMPORTANT-1）：取消 → 记录冷却窗口——runModal 关闭使
                // 窗口 re-key → didBecomeKey 立即再触发；冷却 1s 抑制重复弹窗（基准未刷新，
                // 无冷却则死循环）。1.0s 足够吞掉 re-key 风暴，又不至于压制真实外改告警
                cancelCooldownUntil = Date().addingTimeInterval(1.0)
            }
        } else {
            reloadCurrentDocument()   // 未编辑 → 静默重载（FR-077）
        }
        return true
    }

    /// 重载当前文档（弹窗"重新加载"/未编辑静默重载共用）：read 刷新 lastSavedMtime + onTextRead 回填编辑器
    private func reloadCurrentDocument() {
        guard let doc = currentDocument, let url = doc.fileURL else { return }
        do {
            try doc.read(from: url, ofType: "md")
            onTextRead?(doc.text)
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        if let errorPresenter { errorPresenter(error); return }
        let alert = NSAlert(error: error)
        alert.runModal()   // NFR-011：标准错误弹窗，不丢数据
    }
}
