import AppKit
import UniformTypeIdentifiers

// DragDrop.swift — 拖拽打开路由（S-030，FR-078：拖到窗口/Dock）
// 窗口 .onDrop（MainContentAssembly 容器挂接）+ Dock application(_:openFiles:)
// 统一复用 FileOperations.open(url:)（NFR-011 确认链路）
enum DragDrop {

    /// 窗口拖拽：NSItemProvider → URL → openURL
    /// 修复：loadObject(ofClass:) 在部分场景回调不可靠 → 用 loadItem + 读取 Data 转 URL
    ///（fileURL 类型在 NSPasteboard 中为 file URL 字符串/Data；双通道保证）
    static func handle(_ providers: [NSItemProvider], openURL: @escaping (URL) -> Void) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in openURL(url) }
                } else if let data = item as? Data,
                          let path = String(data: data, encoding: .utf8) {
                    // loadItem 对 fileURL 返回 Data：形如 "file:///var/..." 或 "/var/..."
                    Task { @MainActor in openURL(Self.normalizedFileURL(from: path)) }
                } else if let string = item as? String {
                    Task { @MainActor in openURL(Self.normalizedFileURL(from: string)) }
                }
            }
        }
    }

    /// 规范化 file URL 字符串 → URL（剥掉可能的 "file://" 前缀，兼容 loadItem 两种 Data 形态）
    static func normalizedFileURL(from path: String) -> URL {
        if path.hasPrefix("file://") {
            return URL(fileURLWithPath: String(path.dropFirst("file://".count)))
        }
        return URL(fileURLWithPath: path)
    }

    /// Dock/Finder openFiles 文件名列表 → URL 列表（纯函数，可测）
    static func urls(from filenames: [String]) -> [URL] {
        filenames.map { URL(fileURLWithPath: $0) }
    }
}
