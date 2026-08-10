import XCTest
@testable import MarkdownEditor

// Document：读写 round-trip + 修改状态（S-014 基础，NFR-011）
// ⚠️ 修复 F2（第 8 轮）：@MainActor — Document 是 NSDocument 子类（@MainActor 隔离），
// 直接调用 read/write/text 需同隔离域
@MainActor
final class DocumentTests: XCTestCase {
    func testReadFromFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-read-\(UUID().uuidString).md")
        try "# Title\n\ntext".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = Document()
        try doc.read(from: url, ofType: "md")
        XCTAssertEqual(doc.text, "# Title\n\ntext")
        XCTAssertFalse(doc.hasUnsavedChanges, "打开后不标记未保存")
    }

    func testWriteRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-write-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = Document()
        doc.text = "hello\nworld"
        try doc.write(to: url, ofType: "md")
        let back = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(back, "hello\nworld")
    }

    func testDataOfType() throws {
        let doc = Document()
        doc.text = "中文内容"
        let data = try doc.data(ofType: "md")
        XCTAssertEqual(String(data: data, encoding: .utf8), "中文内容")
    }

    func testTextMutationMarksEdited() {
        let doc = Document()
        doc.text = "x"
        doc.updateChangeCount(.changeCleared)   // 打开场景后
        XCTAssertFalse(doc.hasUnsavedChanges)
        doc.text = "y"
        XCTAssertTrue(doc.hasUnsavedChanges, "编辑标记未保存（FR-076 依赖）")
    }

    // ⚠️ 遗留 #2（批次 1）追加：CloseConfirming mock——返回序列注入（保存/不保存/取消/写盘失败）
    final class MockConfirmer: CloseConfirming {
        var responses: [NSApplication.ModalResponse]
        var calls: [String] = []
        init(_ responses: [NSApplication.ModalResponse]) { self.responses = responses }
        func confirm(message: String, informative: String, buttons: [String]) -> NSApplication.ModalResponse {
            calls.append(message)
            return responses.isEmpty ? .alertThirdButtonReturn : responses.removeFirst()
        }
    }

    func testConfirmSaveReturnsTrueAndClearsEdited() throws {
        let doc = Document()
        doc.confirmer = MockConfirmer([.alertFirstButtonReturn])   // 保存
        doc.text = "dirty"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-save-\(UUID().uuidString).md")
        doc.fileURL = url
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(doc.confirmCloseIfNeeded(), "保存后可关闭")
        XCTAssertFalse(doc.hasUnsavedChanges, "保存后清除未保存标记")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "dirty", "内容已落盘")
    }

    func testConfirmDiscardReturnsTrue() {
        let doc = Document()
        doc.confirmer = MockConfirmer([.alertSecondButtonReturn])  // 不保存
        doc.text = "dirty"
        XCTAssertTrue(doc.confirmCloseIfNeeded(), "放弃修改可关闭")
        XCTAssertTrue(doc.hasUnsavedChanges, "放弃不改标记（关闭即弃）")
    }

    func testConfirmCancelReturnsFalse() {
        let doc = Document()
        doc.confirmer = MockConfirmer([.alertThirdButtonReturn])   // 取消
        doc.text = "dirty"
        XCTAssertFalse(doc.confirmCloseIfNeeded(), "取消关闭必须保留窗口（FR-076）")
    }

    func testConfirmSaveWriteFailureBeepsAndReturnsFalse() throws {
        let doc = Document()
        doc.confirmer = MockConfirmer([.alertFirstButtonReturn])   // 保存
        doc.text = "dirty"
        // 写盘失败路径：目标目录不存在 → write 抛错 → beep + false（FR-076 语义保持）
        doc.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)/x.md")
        XCTAssertFalse(doc.confirmCloseIfNeeded(), "写盘失败 beep + 返回 false")
        XCTAssertTrue(doc.hasUnsavedChanges, "失败后保持未保存标记（不丢数据，NFR-011）")
    }

    // ⚠️ T4.2（FR-077）追加：lastSavedMtime 基准（外部修改检测数据源）

    func testReadCapturesLastSavedMtime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-mtime-\(UUID().uuidString).md")
        try "mtime 基准".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = Document()
        try doc.read(from: url, ofType: "md")
        let real = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(doc.lastSavedMtime, real, "read 记录基准 mtime（FR-077）")
    }

    func testWriteRefreshesLastSavedMtime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-write-mtime-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = Document()
        doc.text = "写盘刷新基准"
        try doc.write(to: url, ofType: "md")
        let real = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(doc.lastSavedMtime, real, "write 成功后刷新基准（防自触自警）")
    }
}
