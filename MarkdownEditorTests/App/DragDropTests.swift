import XCTest
@testable import MarkdownEditor

// DragDrop：provider → URL 路由 + openFiles 文件名转换（S-030，FR-078；窗口/Dock 手动验收）
final class DragDropTests: XCTestCase {
    @MainActor
    func testUrlsFromFilenames() {
        let urls = DragDrop.urls(from: ["/tmp/a.md", "/tmp/b.txt"])
        XCTAssertEqual(urls.map(\.path), ["/tmp/a.md", "/tmp/b.txt"])
    }

    @MainActor
    func testHandleDeliversFileURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("drop.md")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        let provider = NSItemProvider(contentsOf: url)!
        let exp = expectation(description: "drop url delivered")
        var delivered: URL?
        DragDrop.handle([provider]) { url in
            delivered = url
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(delivered?.path, url.path)
    }
}
