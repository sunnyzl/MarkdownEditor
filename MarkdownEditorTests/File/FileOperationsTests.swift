import XCTest
@testable import MarkdownEditor

// FileOperations：纯逻辑部分（类型过滤/新建语义/编辑标记）（Panel UI 手动验收）
final class FileOperationsTests: XCTestCase {
    @MainActor   // ⚠️ 修复 F2（第 8 轮）：supportedTypes 是 @MainActor 类属性，需同隔离域
    func testSupportedTypes() {
        // ⚠️ 适配（T5.2 实施）：系统将 .md/.markdown 归一为 public.markdown（二者
        // preferredFilenameExtension 均为 "md"），故改为验证 tags 覆盖三类扩展名
        // （保留 FR-071 意图：打开/保存 .md/.markdown/.txt；.plainText 覆盖 "txt"）
        let supported = Set(
            FileOperations.supportedTypes.flatMap { $0.tags[.filenameExtension] ?? [] }
        )
        XCTAssertEqual(FileOperations.supportedTypes.count, 3, "md/markdown/txt 三个类型")
        XCTAssertTrue(supported.isSuperset(of: ["md", "markdown", "txt"]),
                      "supportedTypes 应覆盖 .md/.markdown/.txt（FR-071/072/073）")
    }

    @MainActor
    func testNewDocumentClearsEditor() {
        let ops = FileOperations()
        var readText: String?
        ops.onTextRead = { readText = $0 }
        ops.newDocument()
        XCTAssertNotNil(ops.currentDocument)
        XCTAssertEqual(ops.currentDocument?.displayName, "Untitled.md", "FR-071 默认名")
        XCTAssertEqual(readText, "", "新建清空编辑器")
    }

    @MainActor
    func testDocumentDidEditMarksCurrent() {
        let ops = FileOperations()
        ops.newDocument()
        ops.currentDocument?.updateChangeCount(.changeCleared)
        ops.documentDidEdit("# new")
        XCTAssertTrue(ops.currentDocument?.hasUnsavedChanges == true)
    }

    @MainActor
    func testDocumentDidEditWithoutDocumentCreatesUntitled() {
        let ops = FileOperations()
        ops.documentDidEdit("typing")
        XCTAssertNotNil(ops.currentDocument, "未打开文档时输入自动建立 Untitled（FR-071 语义）")
        XCTAssertEqual(ops.currentDocument?.text, "typing")
    }

    @MainActor
    func testNewDocumentWithUneditedCurrentProceeds() {
        // ⚠️ 修复（review T5.2，NFR-011）：Cmd-N 新建前确认未保存修改——未编辑文档
        // confirmCloseIfNeeded 直接放行（guard isDocumentEdited 短路，不弹窗），
        // 此测试守护 NFR-011 guard 不得误伤正常新建路径（回归保护）
        let ops = FileOperations()
        ops.newDocument()
        ops.currentDocument?.updateChangeCount(.changeCleared)
        ops.newDocument()
        XCTAssertEqual(ops.currentDocument?.displayName, "Untitled.md",
                       "未编辑文档新建不被 NFR-011 确认阻塞")
    }

    @MainActor
    func testDocumentDidEditSameTextDoesNotMarkEdited() {
        // ⚠️ 修复（review T5.2）：程序化回填与 doc.text 一致时跳过赋值——Swift didSet
        // 即使值相同仍触发 updateChangeCount(.changeDone)，导致刚打开就"已修改"
        //（脏标记污染：打开文件即被标记为有未保存修改）
        let ops = FileOperations()
        ops.newDocument()
        ops.currentDocument?.updateChangeCount(.changeCleared)
        ops.documentDidEdit("")
        XCTAssertFalse(ops.currentDocument?.hasUnsavedChanges ?? true,
                       "与当前内容相同的回填不应标记未保存（脏标记污染）")
    }

    // ⚠️ S-030 追加：open(url:) 抽取 + 自动保存（FR-074/075；NFR-011 确认链路）

    @MainActor
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.epic5.fileops.\(UUID().uuidString)")!
    }

    @MainActor
    private func writeTempMarkdown(_ content: String, named: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(named)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    func testOpenURLLoadsDocumentAndRecordsRecent() throws {
        let url = try writeTempMarkdown("# 打开测试", named: "open-a.md")
        let ops = FileOperations(defaults: makeDefaults())
        var readText: String?
        ops.onTextRead = { readText = $0 }
        ops.open(url: url)
        XCTAssertEqual(ops.currentDocument?.text, "# 打开测试")
        XCTAssertEqual(readText, "# 打开测试")
        XCTAssertEqual(RecentFiles.list(defaults: ops.defaults).map(\.path), [url.path], "打开成功 → 记录最近文件")
    }

    @MainActor
    func testOpenURLFailureRemovesFromRecents() {
        let d = makeDefaults()
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).md")
        RecentFiles.record(missing, defaults: d)
        let ops = FileOperations(defaults: d)
        var presented: [Error] = []
        ops.errorPresenter = { presented.append($0) }   // 注入防 NSAlert 模态阻塞测试
        ops.open(url: missing)
        XCTAssertTrue(RecentFiles.list(defaults: d).isEmpty, "打开失败 → 从最近文件移除（设计 §错误处理）")
        XCTAssertEqual(presented.count, 1, "错误经注入出口展示（不弹模态）")
    }

    @MainActor
    func testAutoSaveWritesAndKeepsEditedMarker() throws {
        let url = try writeTempMarkdown("初始", named: "auto-a.md")
        let ops = FileOperations(defaults: makeDefaults())
        ops.open(url: url)
        ops.currentDocument?.updateChangeCount(.changeCleared)
        ops.documentDidEdit("自动保存内容")
        XCTAssertTrue(ops.currentDocument?.hasUnsavedChanges == true)
        ops.autoSave()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "自动保存内容", "内容已落盘")
        XCTAssertTrue(ops.currentDocument?.hasUnsavedChanges == true, "保留 edited 标记（设计决策）")
    }

    @MainActor
    func testAutoSaveSkipsUntitled() {
        let ops = FileOperations(defaults: makeDefaults())
        ops.newDocument()
        ops.documentDidEdit("内容")
        ops.autoSave()   // fileURL nil → 不落盘、不崩溃
        XCTAssertNil(ops.currentDocument?.fileURL)
        XCTAssertTrue(ops.currentDocument?.hasUnsavedChanges == true, "Untitled 保持未保存状态")
    }

    // ⚠️ T4.2（FR-077）追加：外部修改检测——mtime 比对 + 冲突弹窗/静默重载 + AutoSave 刷新防护
    // MockConfirmer 与 DocumentTests 同构（每文件自含 mock，测试隔离惯例）

    final class MockConfirmer: CloseConfirming {
        var responses: [NSApplication.ModalResponse]
        var calls: [String] = []
        init(_ responses: [NSApplication.ModalResponse]) { self.responses = responses }
        func confirm(message: String, informative: String, buttons: [String]) -> NSApplication.ModalResponse {
            calls.append(message)
            return responses.isEmpty ? .alertThirdButtonReturn : responses.removeFirst()
        }
    }

    @MainActor
    func testExternalModificationMtimeUnchangedNoTrigger() throws {
        // 测试 1：mtime 一致不触发——read 基准与当前一致 → 不重载不弹窗
        let url = try writeTempMarkdown("初始", named: "ext-unchanged.md")
        let ops = FileOperations(defaults: makeDefaults())
        var reloadCount = 0
        ops.onTextRead = { _ in reloadCount += 1 }
        ops.open(url: url)   // open 回填 1 次
        XCTAssertFalse(ops.checkExternalModification(), "mtime 一致不触发（FR-077）")
        XCTAssertEqual(reloadCount, 1, "不触发则不额外重载（保持 open 的 1 次回填）")
    }

    @MainActor
    func testExternalModificationMtimeChangedSilentReloadWhenUnedited() throws {
        // 测试 2：mtime 变化 + 未编辑 → 静默重载（onTextRead 链路，无弹窗）
        let url = try writeTempMarkdown("初始", named: "ext-silent.md")
        let ops = FileOperations(defaults: makeDefaults())
        var texts: [String] = []
        ops.onTextRead = { texts.append($0) }
        ops.open(url: url)
        texts.removeAll()   // 清 open 回填，只观察 check 的重载
        try "外部修改内容".write(to: url, atomically: true, encoding: .utf8)   // 外部改盘
        ops.mtimeReader = { _ in Date().addingTimeInterval(60) }   // 注入模拟 clock（mtime 变化）
        XCTAssertTrue(ops.checkExternalModification(), "mtime 变化触发检测")
        XCTAssertEqual(texts, ["外部修改内容"], "未编辑静默重载走 onTextRead 链路")
        XCTAssertFalse(ops.currentDocument?.hasUnsavedChanges ?? true, "重载后不标记未保存")
    }

    @MainActor
    func testExternalModificationDialogReloadWhenEdited() throws {
        // 测试 2（已编辑分支）：mtime 变化 + 已编辑 → 三按钮弹窗；"重新加载" → 重读磁盘
        let url = try writeTempMarkdown("初始", named: "ext-reload.md")
        let ops = FileOperations(defaults: makeDefaults())
        var texts: [String] = []
        ops.onTextRead = { texts.append($0) }
        ops.open(url: url)
        texts.removeAll()
        ops.documentDidEdit("本地未保存修改")
        try "外部版本文本".write(to: url, atomically: true, encoding: .utf8)
        let doc = ops.currentDocument!
        doc.confirmer = MockConfirmer([.alertFirstButtonReturn])   // 重新加载
        ops.mtimeReader = { _ in Date().addingTimeInterval(120) }   // 注入模拟 clock
        XCTAssertTrue(ops.checkExternalModification())
        XCTAssertEqual(texts, ["外部版本文本"], "重新加载 → 磁盘内容经 onTextRead 回填")
        XCTAssertEqual(doc.text, "外部版本文本", "本地修改被重载覆盖（用户显式选择）")
        XCTAssertFalse(doc.hasUnsavedChanges, "重载后不标记未保存")
    }

    @MainActor
    func testExternalModificationKeepLocalRefreshesBaseline() throws {
        // 弹窗"保留本地" → 不重载 + 刷新检测基准（防同一外改每次激活重复弹窗）
        let url = try writeTempMarkdown("初始", named: "ext-keep.md")
        let ops = FileOperations(defaults: makeDefaults())
        ops.open(url: url)
        ops.documentDidEdit("本地版本")
        let doc = ops.currentDocument!
        doc.confirmer = MockConfirmer([.alertSecondButtonReturn])   // 保留本地
        // 模拟外部修改：真实改文件内容（哈希变化触发检测——真机验收改哈希比对）
        try "外部修改内容".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(ops.checkExternalModification())
        XCTAssertEqual(doc.text, "本地版本", "保留本地 → 不重载")
        XCTAssertTrue(doc.hasUnsavedChanges, "保留本地 → 本地修改保持未保存")
    }

    @MainActor
    func testExternalModificationCancelDoesNothing() throws {
        // 弹窗"取消" → 不重载不改动，基准不刷新
        let url = try writeTempMarkdown("初始", named: "ext-cancel.md")
        let ops = FileOperations(defaults: makeDefaults())
        ops.open(url: url)
        ops.documentDidEdit("本地版本")
        let doc = ops.currentDocument!
        doc.confirmer = MockConfirmer([.alertThirdButtonReturn])   // 取消
        try "外部修改内容".write(to: url, atomically: true, encoding: .utf8)
        let baselineHash = doc.lastSavedContentHash
        XCTAssertTrue(ops.checkExternalModification(), "检测到外改返回 true（取消仅不做处理）")
        XCTAssertEqual(doc.text, "本地版本", "取消 → 不重载")
        XCTAssertEqual(doc.lastSavedContentHash, baselineHash, "取消 → 哈希基准不刷新")
    }

    @MainActor
    func testAutoSaveRefreshesMtimeNoFalseAlarm() throws {
        // 测试 3：自动保存后 mtime 刷新不误报（防自触自警——注入 mock confirmer 断言不弹窗）
        let url = try writeTempMarkdown("初始", named: "ext-autosave.md")
        let ops = FileOperations(defaults: makeDefaults())
        ops.open(url: url)
        ops.currentDocument?.updateChangeCount(.changeCleared)
        ops.documentDidEdit("自动保存内容")
        let doc = ops.currentDocument!
        doc.confirmer = MockConfirmer([.alertFirstButtonReturn])   // 误报则弹窗 → calls 非空
        ops.autoSave()   // 写盘 → Document.write 刷新 lastSavedMtime（防自触自警）
        XCTAssertFalse(ops.checkExternalModification(), "自动保存后 mtime 刷新，不误报外改")
        let mock = doc.confirmer as! MockConfirmer
        XCTAssertTrue(mock.calls.isEmpty, "不弹冲突窗（calls 为空）")
    }

    // ⚠️ T4.2 修复（评审 IMPORTANT-1）：取消冷却 + autoSave mtime 守卫（NFR-011 数据安全）

    @MainActor
    func testExternalModificationCancelCooldownSuppressesRePrompt() throws {
        // 评审 IMPORTANT-1：取消后冷却窗口内重复检测不弹窗（防 re-key 无限循环——
        // runModal 关闭使窗口 re-key → didBecomeKey 再触发 → 取消不刷新基准 → 无冷却则再弹窗）
        let url = try writeTempMarkdown("初始", named: "ext-cooldown.md")
        let ops = FileOperations(defaults: makeDefaults())
        ops.open(url: url)
        ops.documentDidEdit("本地版本")
        let doc = ops.currentDocument!
        let mock = MockConfirmer([.alertThirdButtonReturn, .alertThirdButtonReturn])   // 两次取消
        doc.confirmer = mock
        try "外部修改内容".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(ops.checkExternalModification(), "首次检测到外改 → 弹窗（取消）")
        XCTAssertFalse(ops.checkExternalModification(), "冷却窗口内重复检测被抑制（不弹窗）")
        XCTAssertEqual(mock.calls.count, 1, "仅弹窗一次——冷却抑制第二次弹窗（防 re-key 无限循环）")
    }

    @MainActor
    func testAutoSaveSkipsWhenExternalMtimeDiffers() throws {
        // 评审盲审 IMPORTANT-2/3（NFR-011 数据安全）：外部改盘 + mtime 变化 →
        // autoSave 不得静默覆盖（key 窗口 30s 定时 / 冲突弹窗期间 .common runloop 定时）
        let url = try writeTempMarkdown("初始", named: "ext-autosave-guard.md")
        let ops = FileOperations(defaults: makeDefaults())
        ops.open(url: url)
        ops.documentDidEdit("本地未保存版本")
        try "外部修改内容".write(to: url, atomically: true, encoding: .utf8)   // 外部改盘
        ops.mtimeReader = { _ in Date().addingTimeInterval(90) }   // 注入模拟 clock（mtime 变化）
        ops.autoSave()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "外部修改内容",
                       "外部修改不被 autoSave 静默覆盖（mtime 不一致 → 跳过写盘）")
        XCTAssertTrue(ops.currentDocument?.hasUnsavedChanges == true,
                      "跳过写盘 → 保留 edited 标记（交由 didBecomeKey 弹窗决策）")
    }

    // ⚠️ P1-1（保存通道收敛）：折叠态保存完整原文——保存通道传 rawText（MainContentAssembly
    // onRawTextDidChange 路由后的契约锁定）；修复前传渲染文本 → 折叠区间行永久丢失
    @MainActor
    func testSaveAfterFoldWritesFullRawText() throws {
        let suiteName = "test.p1.fops.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }
        let ops = FileOperations(defaults: d)
        ops.errorPresenter = { _ in }   // 防御：写盘失败走注入出口，防 NSAlert 模态阻塞测试
        // 折叠态编辑器：显示文本缺行、rawText 完整
        let tv = MarkdownTextView(defaults: d)
        tv.setTextProgrammatically("# Title\nIntro\nMore text\n## Sub\nEnd")
        tv.toggleFold(at: 3)
        XCTAssertEqual(tv.string, "# Title\nIntro\nMore text\n▸ ## Sub", "前置：折叠态显示文本")
        // 新链路：保存通道传 rawText（折叠态下显示文本缺行，不可作保存数据源）
        ops.documentDidEdit(tv.rawText)
        XCTAssertEqual(ops.currentDocument?.text, "# Title\nIntro\nMore text\n## Sub\nEnd",
                       "doc.text 为完整原文（折叠区间行未丢失）")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1-save-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        ops.currentDocument?.fileURL = url
        ops.saveDocument()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "# Title\nIntro\nMore text\n## Sub\nEnd",
                       "保存写盘完整原文（P1-1 数据完整性）")
    }
}
