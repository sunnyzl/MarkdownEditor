import XCTest
import AppKit
@testable import MarkdownEditor

// SyntaxHighlighter（S-023）：双层拼接、围栏解析（语言识别/未闭合容错）、主题映射
//（light→github-gist / dark→github-dark）、开关读取（默认开启）、debounce 调度
// ⚠️ 注入 highlightClosure 假引擎——围栏/拼接/开关/调度逻辑与 Highlightr 解耦单测；
// 真实 Highlightr 集成由 MarkdownTextViewTests 污染-断言模式覆盖（T5.1）
@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    private func makeSuite(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// 假引擎：记录 (code, language) 调用序列，返回绿色属性串
    /// ⚠️ 适配（T4.2 测试脚手架修复）：calls 用 class 记录器承载——若直接返回局部
    /// `var calls` 的数组值，返回即快照（数组是值类型），闭包后续 append 对测试不可见
    /// （Swift 转义闭包捕获装箱 + 返回值拷贝语义）。class 引用语义保证调用序列可观测。
    /// Adaptation (T4.2 test-harness fix): calls live in a class recorder — returning the
    /// local `var calls` array value snapshots it (arrays are value types), so later appends
    /// inside the escaping closure are invisible to the test. Class reference semantics
    /// keep the call sequence observable.
    private final class CallRecorder {
        var calls: [((String, String))] = []
    }
    private func makeMockEngine() -> (SyntaxHighlighter, CallRecorder) {
        let recorder = CallRecorder()
        let highlighter = SyntaxHighlighter(
            defaults: makeSuite("test-highlighter"),
            highlightClosure: { code, language in
                recorder.calls.append((code, language))
                return NSAttributedString(string: code, attributes: [.foregroundColor: NSColor.green])
            },
            debounceInterval: 0.05
        )
        return (highlighter, recorder)
    }

    // S-023 ②：围栏语言识别——```swift 块用 swift 高亮（markdown 全文 + swift 双层调用）
    func testFenceLanguageDetected() {
        let (highlighter, recorder) = makeMockEngine()
        let text = "# Title\n\n```swift\nlet x = 1\n```\n"
        let result = highlighter.highlightNow(text)
        XCTAssertNotNil(result)
        XCTAssertEqual(recorder.calls.count, 2, "markdown 全文 + swift 围栏 = 2 次高亮调用")
        XCTAssertEqual(recorder.calls[0].0, text)
        XCTAssertEqual(recorder.calls[1].0, "let x = 1")
        XCTAssertEqual(recorder.calls[1].1, "swift")
    }

    // 未标注语言围栏 → markdown 回退
    func testUnlabelledFenceFallsBackToMarkdown() {
        let (highlighter, recorder) = makeMockEngine()
        _ = highlighter.highlightNow("```\nplain code\n```\n")
        XCTAssertTrue(recorder.calls.contains { $0.1 == "markdown" }, "未标注语言 → markdown 语言高亮")
    }

    // 未闭合围栏容错：不崩溃，仅 markdown 全文层调用
    func testUnclosedFenceTolerated() {
        let (highlighter, recorder) = makeMockEngine()
        let result = highlighter.highlightNow("# T\n```swift\nlet x = 1")
        XCTAssertNotNil(result, "未闭合围栏不崩溃，降级 markdown 着色")
        XCTAssertEqual(recorder.calls.count, 1, "未闭合 → 仅全文层调用")
    }

    // 主题映射（AD-8）：light → github-gist / dark → github-dark
    // ⚠️ 修订（T5.1 收尾）：light 映射 github-gist（Highlightr 2.3.0 stripTheme 正则不解析
    // 复合选择器，github light 主题颜色损坏；POC-S-005 已验证 github-gist）
    func testThemeMapping() {
        let (highlighter, _) = makeMockEngine()
        highlighter.setTheme(.light)
        XCTAssertEqual(highlighter.currentThemeName, "github-gist")
        highlighter.setTheme(.dark)
        XCTAssertEqual(highlighter.currentThemeName, "github-dark")
    }

    // 开关：默认开启（FR-003 卖点）；显式 false → 关闭（FR-108）
    func testEnabledDefaultTrue() {
        XCTAssertTrue(SyntaxHighlighter.isEnabled(defaults: makeSuite("test-default-on")),
                      "默认开启（FR-003 功能卖点）")
    }
    func testEnabledRespectsStoredValue() {
        let suite = makeSuite("test-toggle-off")
        suite.set(false, forKey: SyntaxHighlighter.enabledKey)
        XCTAssertFalse(SyntaxHighlighter.isEnabled(defaults: suite))
        suite.set(true, forKey: SyntaxHighlighter.enabledKey)
        XCTAssertTrue(SyntaxHighlighter.isEnabled(defaults: suite))
    }

    // 关闭时 highlight 返回 nil（调度方跳过 → 走 recolor 纯文本路径，零回归）
    func testDisabledReturnsNil() {
        let suite = makeSuite("test-disabled-nil")
        suite.set(false, forKey: SyntaxHighlighter.enabledKey)
        let highlighter = SyntaxHighlighter(defaults: suite,
                                            highlightClosure: { code, _ in NSAttributedString(string: code) })
        XCTAssertNil(highlighter.highlightNow("code"))
    }

    // debounce：连续调度仅执行最后一次（version 守卫）
    func testScheduleHighlightDebouncesToLatest() {
        let (highlighter, _) = makeMockEngine()
        let exp = expectation(description: "debounce")
        var results: [NSAttributedString?] = []
        highlighter.scheduleHighlight("first") { results.append($0) }
        highlighter.scheduleHighlight("second") { results.append($0) }
        highlighter.scheduleHighlight("third") { results.append($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(results.count, 1, "连续调度只执行最后一次")
        XCTAssertEqual(results.first??.string, "third")
    }
}
