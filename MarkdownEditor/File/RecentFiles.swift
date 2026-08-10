import Foundation

// RecentFiles.swift — 最近文件（S-030，FR-074：UserDefaults 存最近 10 个文件 URL）
// 自管理（非 NSDocumentController——本 app 无 documentController 体系，设计 §S-030 方案 1）
// 存储：URL path 字符串数组（去重/前移/截断纯逻辑可单测；defaults 注入参数防测试污染）
enum RecentFiles {
    static let storageKey = "recentFiles"
    static let maxCount = 10

    /// 纯函数：去重 → 前移 → 截断（最多 max 条，最近优先）
    static func updatedPaths(_ paths: [String], adding path: String,
                             max: Int = maxCount) -> [String] {
        var result = paths.filter { $0 != path }
        result.insert(path, at: 0)
        if result.count > max { result = Array(result.prefix(max)) }
        return result
    }

    /// 记录打开/保存成功路径（写 defaults）
    static func record(_ url: URL, defaults: UserDefaults = .standard) {
        let paths = (defaults.array(forKey: storageKey) as? [String]) ?? []
        defaults.set(updatedPaths(paths, adding: url.path), forKey: storageKey)
    }

    /// 当前列表（最近优先）
    static func list(defaults: UserDefaults = .standard) -> [URL] {
        ((defaults.array(forKey: storageKey) as? [String]) ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    /// 移除（设计 §错误处理：失效 URL 打开失败 → 从列表移除 + 提示）
    static func remove(_ url: URL, defaults: UserDefaults = .standard) {
        var paths = (defaults.array(forKey: storageKey) as? [String]) ?? []
        paths.removeAll { $0 == url.path }
        defaults.set(paths, forKey: storageKey)
    }

    /// 清空（菜单"清除最近文件"）
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
