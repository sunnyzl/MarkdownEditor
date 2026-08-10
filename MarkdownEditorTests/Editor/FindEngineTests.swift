import XCTest
@testable import MarkdownEditor

// FindEngine：普通/正则匹配、大小写、全匹配、替换文本生成、非法正则（S-029，FR-002）
final class FindEngineTests: XCTestCase {
    func testPlainMatchesAllOccurrences() {
        let r = FindEngine.matches(in: "a b a c a", query: "a",
                                   isRegularExpression: false, caseSensitive: false)
        XCTAssertEqual(r.ranges.count, 3)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.ranges[0], NSRange(location: 0, length: 1))
    }

    func testCaseSensitiveRespected() {
        let text = "Ab A ab"
        let insensitive = FindEngine.matches(in: text, query: "ab",
                                             isRegularExpression: false, caseSensitive: false)
        XCTAssertEqual(insensitive.ranges.count, 2, "不区分大小写：Ab/ab 两处")
        let sensitive = FindEngine.matches(in: text, query: "ab",
                                           isRegularExpression: false, caseSensitive: true)
        XCTAssertEqual(sensitive.ranges.count, 1, "区分大小写：仅小写 ab")
    }

    func testRegexMatches() {
        let r = FindEngine.matches(in: "foo123 bar456", query: #"\d+"#,
                                   isRegularExpression: true, caseSensitive: false)
        XCTAssertEqual(r.ranges.count, 2)
        XCTAssertNil(r.error)
    }

    func testInvalidRegexReturnsError() {
        let r = FindEngine.matches(in: "text", query: "([",
                                   isRegularExpression: true, caseSensitive: false)
        XCTAssertTrue(r.ranges.isEmpty)
        XCTAssertNotNil(r.error, "非法正则 → 错误提示（不崩溃）")
    }

    func testNoMatchReturnsEmpty() {
        let r = FindEngine.matches(in: "hello", query: "xyz",
                                   isRegularExpression: false, caseSensitive: false)
        XCTAssertTrue(r.ranges.isEmpty)
    }

    func testReplacementStringRegexCaptureGroup() {
        let text = "2026-08-07"
        let r = FindEngine.replacementString(
            in: text, matchRange: NSRange(location: 0, length: (text as NSString).length),
            query: #"(\d{4})-(\d{2})-(\d{2})"#, replacement: "$3/$2/$1",
            isRegularExpression: true, caseSensitive: false)
        XCTAssertEqual(r, "07/08/2026")
    }

    func testPlainReplacementTextAndCount() {
        let (newText, count) = FindEngine.replacement(
            in: "cat dog cat", query: "cat", replacement: "DOG",
            isRegularExpression: false, caseSensitive: false)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(newText, "DOG dog DOG")
    }

    func testRegexReplacementTextAndCount() {
        let (newText, count) = FindEngine.replacement(
            in: "a1 b2", query: #"\d"#, replacement: "X",
            isRegularExpression: true, caseSensitive: false)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(newText, "aX bX")
    }
}
