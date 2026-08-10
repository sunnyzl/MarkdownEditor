import SwiftUI
import AppKit

// FindPanel.swift — 查找/替换面板（S-029，FR-002：Cmd+F/G/Shift+G + 正则开关，替换可撤销）
// FindCoordinator：会话状态 + 匹配/替换执行（@MainActor 容器模式）
// FindPanel：SwiftUI 底部 overlay 条（Batch 7 经 FindPanelHost 挂到 MainContentAssembly）
// 替换走原生编辑链（shouldChangeText + replaceCharacters + didChangeText）→ undo 自动进栈
// 高亮：NSTextStorage .backgroundColor 属性编辑（不触发 didChange 通知 → 无渲染循环）

@MainActor
final class FindCoordinator: ObservableObject {
    @Published var isVisible = false
    @Published var searchText = ""
    @Published var replaceText = ""
    @Published var isRegex = false
    @Published var isCaseSensitive = false
    @Published var statusMessage = ""

    /// 查找/替换目标 textView（Batch 7 attachTextView 注入）
    weak var textView: MarkdownTextView?

    private(set) var matchRanges: [NSRange] = []
    private var currentMatchIndex = 0

    /// 匹配高亮色（NSTextStorage 背景；当前匹配橙色醒目、其余黄色）
    static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.35)
    static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.5)

    // MARK: - 会话

    func show() {
        isVisible = true
        if !searchText.isEmpty { updateMatches() }
    }

    func hide() {
        isVisible = false
        clearHighlights()
        matchRanges = []
        currentMatchIndex = 0
    }

    /// 文本变化 → 匹配过期清理（仅面板可见时；MainContentAssembly onTextDidChange 挂接）
    func textDidChange() {
        guard isVisible else { return }
        clearHighlights()
        matchRanges = []
        currentMatchIndex = 0
    }

    func setSearchText(_ newText: String) {
        searchText = newText
        statusMessage = ""
        updateMatches()
    }

    func setRegex(_ enabled: Bool) { isRegex = enabled; updateMatches() }
    func setCaseSensitive(_ enabled: Bool) { isCaseSensitive = enabled; updateMatches() }

    // MARK: - 导航

    func findNext() {
        guard !matchRanges.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchRanges.count
        selectCurrent()
    }

    func findPrevious() {
        guard !matchRanges.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchRanges.count) % matchRanges.count
        selectCurrent()
    }

    // MARK: - 替换（原生编辑链 → undo 自动进栈，FR-002）

    func replaceCurrent() {
        guard let textView, !matchRanges.isEmpty else { return }
        let range = matchRanges[currentMatchIndex]
        let replacement = FindEngine.replacementString(
            in: textView.string, matchRange: range, query: searchText,
            replacement: replaceText, isRegularExpression: isRegex, caseSensitive: isCaseSensitive)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        updateMatches()
    }

    func replaceAll() {
        guard let textView, !searchText.isEmpty else { return }
        let result = FindEngine.replacement(
            in: textView.string, query: searchText, replacement: replaceText,
            isRegularExpression: isRegex, caseSensitive: isCaseSensitive)
        guard result.count > 0 else { statusMessage = "未找到匹配"; return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: full, replacementString: result.newText) else { return }
        textView.replaceCharacters(in: full, with: result.newText)
        textView.didChangeText()
        updateMatches()
        statusMessage = "已替换 \(result.count) 处"
    }

    // MARK: - 私有

    private func updateMatches() {
        guard isVisible else { return }
        clearHighlights()
        matchRanges = []
        currentMatchIndex = 0
        guard let textView, !searchText.isEmpty else { return }
        let result = FindEngine.matches(in: textView.string, query: searchText,
                                        isRegularExpression: isRegex, caseSensitive: isCaseSensitive)
        if let error = result.error {
            statusMessage = error   // 非法正则：错误提示 + 空匹配（不崩溃）
            return
        }
        matchRanges = result.ranges
        statusMessage = matchRanges.isEmpty ? "未找到匹配" : "\(matchRanges.count) 处匹配"
        applyHighlights()
    }

    private func selectCurrent() {
        guard let textView, !matchRanges.isEmpty else { return }
        let range = matchRanges[currentMatchIndex]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        applyHighlights()
    }

    private func applyHighlights() {
        guard let storage = textView?.textStorage else { return }
        for (index, range) in matchRanges.enumerated() {
            storage.addAttribute(.backgroundColor,
                                 value: index == currentMatchIndex ? Self.currentMatchColor : Self.highlightColor,
                                 range: range)
        }
    }

    private func clearHighlights() {
        guard let storage = textView?.textStorage else { return }
        let validLength = storage.length
        for range in matchRanges {
            // 替换后 storage 收缩 → 旧 matchRanges 可能越界；交集裁剪防 NSRangeException
            guard let valid = range.intersection(NSRange(location: 0, length: validLength)) else { continue }
            storage.removeAttribute(.backgroundColor, range: valid)
        }
    }
}

/// 面板宿主：内部 @ObservedObject——嵌套 ObservableObject 变化不触发父容器 body 重算，
/// 须独立观察者视图承载显隐（isVisible 驱动）
struct FindPanelHost: View {
    @ObservedObject var coordinator: FindCoordinator

    var body: some View {
        if coordinator.isVisible {
            FindPanel(coordinator: coordinator)
                .padding(.bottom, 12)
        }
    }
}

/// 查找/替换面板 UI（逻辑全部在 FindCoordinator；UI 形态手动验收）
struct FindPanel: View {
    @ObservedObject var coordinator: FindCoordinator
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            // 第一行：查找输入 + 选项 + 导航按钮
            HStack(spacing: 6) {
                TextField("查找内容", text: Binding(
                    get: { coordinator.searchText },
                    set: { coordinator.setSearchText($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 200)
                    .focused($searchFocused)
                Toggle("区分大小写", isOn: Binding(
                    get: { coordinator.isCaseSensitive },
                    set: { coordinator.setCaseSensitive($0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Toggle("正则", isOn: Binding(
                    get: { coordinator.isRegex },
                    set: { coordinator.setRegex($0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Button("上一个") { coordinator.findPrevious() }
                    .fixedSize()
                Button("下一个") { coordinator.findNext() }
                    .fixedSize()
                Button("关闭") { coordinator.hide() }
                    .fixedSize()
            }
            // 第二行：替换输入 + 替换按钮 + 状态
            HStack(spacing: 6) {
                TextField("替换为", text: $coordinator.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 200)
                Button("替换") { coordinator.replaceCurrent() }
                    .fixedSize()
                Button("全部替换") { coordinator.replaceAll() }
                    .fixedSize()
                Spacer()
                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .frame(minWidth: 480, idealWidth: 580)
        .onAppear { searchFocused = true }
    }
}
