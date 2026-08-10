import XCTest
import AppKit
@testable import MarkdownEditor

// AutoSave：失焦（didResignKey）+ 定时调度（短间隔注入可测）；落盘判定在 FileOperations.autoSave
final class AutoSaveTests: XCTestCase {
    @MainActor
    func testTimerFiresAtInjectedInterval() {
        let window = NSWindow()
        let autoSave = AutoSave(interval: 0.05)
        let exp = expectation(description: "timer tick")
        var count = 0
        autoSave.onAutoSave = {
            count += 1
            if count == 1 { exp.fulfill() }
        }
        autoSave.attach(to: window)
        wait(for: [exp], timeout: 2)
        autoSave.detach()
    }

    @MainActor
    func testDidResignKeyTriggersSave() {
        let window = NSWindow()
        let autoSave = AutoSave(interval: 60)   // 长间隔排除定时干扰
        let exp = expectation(description: "resign key")
        var count = 0
        autoSave.onAutoSave = {
            count += 1
            if count == 1 { exp.fulfill() }
        }
        autoSave.attach(to: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        wait(for: [exp], timeout: 2)
        autoSave.detach()
    }

    @MainActor
    func testDetachStopsTimer() {
        let window = NSWindow()
        let autoSave = AutoSave(interval: 0.05)
        var count = 0
        autoSave.onAutoSave = { count += 1 }
        autoSave.attach(to: window)
        autoSave.detach()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))   // 跑 runloop 让残留 Timer 有机会触发
        XCTAssertEqual(count, 0, "detach 后定时不再触发")
    }
}
