import SwiftUI
import WebKit

// PreviewView.swift — WKWebView 经 NSViewRepresentable 桥接（S-009，AD-1：单一 webview）
// PreviewWebView 实例由上层持有注入（@MainActor，POC 已验证模式）
// ⚠️ 修复 T2.4（review）：PreviewWebView 为 @MainActor，容器补 @MainActor 标注；
// 与 EditorView.Coordinator 先例一致（持有 @MainActor 引用类型的容器补标注，complete 严格模式防御）
@MainActor
struct PreviewView: NSViewRepresentable {
    let preview: PreviewWebView

    func makeNSView(context: Context) -> WKWebView {
        preview.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
