import XCTest
@testable import MarkdownEditor

// ErrorHandling：降级路由 + 占位安全（S-010 AC-6/7，NFR-012）
final class ErrorHandlingTests: XCTestCase {
    func testFailReports() {
        var eh = ErrorHandling()
        var reported: RenderError?
        eh.onReport = { reported = $0 }
        eh.fail(.down("boom"))
        XCTAssertNotNil(reported)
    }

    func testPlaceholderEscapesMessage() {
        let eh = ErrorHandling()
        let html = eh.placeholderHTML("<script>alert(1)</script>")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "消息必须转义防注入")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("render-error"), "占位带 class 供 CSS 定位（NFR-012 非空白）")
    }

    func testTotalDurationSums() {
        let metrics = [("down", 0.1), ("preprocess", 0.05), ("inject", 0.2)]
        XCTAssertEqual(ErrorHandling.totalDuration(metrics), 0.35, accuracy: 0.001)
    }
}
