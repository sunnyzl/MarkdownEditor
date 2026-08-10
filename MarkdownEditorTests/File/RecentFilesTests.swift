import XCTest
@testable import MarkdownEditor

// RecentFiles：去重/前移/截断 10 + defaults 隔离（suiteName）（S-030，FR-074）
final class RecentFilesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.epic5.recentfiles.\(UUID().uuidString)")!
    }

    func testUpdatedPathsAddsToFront() {
        XCTAssertEqual(RecentFiles.updatedPaths(["b", "c"], adding: "a"), ["a", "b", "c"])
    }

    func testUpdatedPathsDeduplicatesAndMovesToFront() {
        XCTAssertEqual(RecentFiles.updatedPaths(["a", "b", "c"], adding: "b"), ["b", "a", "c"])
    }

    func testUpdatedPathsTruncatesToMax() {
        let paths = (1...12).map { "file\($0)" }
        let result = RecentFiles.updatedPaths(Array(paths.dropFirst()), adding: "file1", max: 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first, "file1")
    }

    func testRecordAndListRoundtrip() {
        let d = makeDefaults()
        RecentFiles.record(URL(fileURLWithPath: "/tmp/a.md"), defaults: d)
        RecentFiles.record(URL(fileURLWithPath: "/tmp/b.md"), defaults: d)
        XCTAssertEqual(RecentFiles.list(defaults: d).map(\.path), ["/tmp/b.md", "/tmp/a.md"])
    }

    func testRecordDedupeMovesToFront() {
        let d = makeDefaults()
        RecentFiles.record(URL(fileURLWithPath: "/tmp/a.md"), defaults: d)
        RecentFiles.record(URL(fileURLWithPath: "/tmp/b.md"), defaults: d)
        RecentFiles.record(URL(fileURLWithPath: "/tmp/a.md"), defaults: d)
        XCTAssertEqual(RecentFiles.list(defaults: d).map(\.path), ["/tmp/a.md", "/tmp/b.md"])
    }

    func testRemove() {
        let d = makeDefaults()
        RecentFiles.record(URL(fileURLWithPath: "/tmp/a.md"), defaults: d)
        RecentFiles.remove(URL(fileURLWithPath: "/tmp/a.md"), defaults: d)
        XCTAssertTrue(RecentFiles.list(defaults: d).isEmpty)
    }

    func testClear() {
        let d = makeDefaults()
        RecentFiles.record(URL(fileURLWithPath: "/tmp/a.md"), defaults: d)
        RecentFiles.clear(defaults: d)
        XCTAssertTrue(RecentFiles.list(defaults: d).isEmpty)
    }
}
