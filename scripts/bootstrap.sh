#!/usr/bin/env bash
# bootstrap.sh — 一键引导 POC + MVP 工作区
# One-shot bootstrap: ensures xcodegen, creates stub dirs, generates project, downloads web assets.
set -euo pipefail

cd "$(dirname "$0")/.."   # 切到项目根 / cd to project root

echo "===> [1/4] 检查 xcodegen / Checking xcodegen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "     xcodegen 未安装，通过 Homebrew 安装 / Installing via Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew 未安装，请先安装 https://brew.sh"
    exit 1
  fi
  brew install xcodegen
fi
echo "     xcodegen: $(xcodegen --version)"

echo "===> [2/4] 检查 Swift 工具链 / Checking Swift toolchain..."
swift --version | head -1
xcodebuild -version | head -1

echo "===> [3/4] 创建 target 源码占位目录 / Creating stub source dirs..."
# xcodegen 要求 sources 路径存在；占位目录由各微任务填充真实代码
# xcodegen requires sources paths to exist; micro-tasks fill these with real code.
for target in POC-S-001-MermaidRender POC-S-002-BundleLoad POC-S-003-PreviewUpdate \
              POC-S-004-DownSourceMap POC-S-005-Highlightr; do
  mkdir -p "$target"
  # 占位文件，避免空目录被 git 忽略 / Placeholder so dir is non-empty
  if [ ! -f "$target/.keep" ]; then
    echo "# 此目录由对应微任务填充 Swift 源码 / Filled by corresponding micro-task" > "$target/.keep"
  fi
done
mkdir -p WebAssets/templates WebAssets/mermaid WebAssets/katex WebAssets/highlight WebAssets/morphdom

# MVP 主模块（S-006：6 特性模块目录骨架，AD-2）+ 测试目录
for dir in App Window Editor Preview RenderPipeline File Settings Shortcuts; do
  mkdir -p "MarkdownEditor/$dir"
  if [ ! -f "MarkdownEditor/$dir/.keep" ]; then
    echo "# 由对应微任务填充 / Filled by corresponding micro-task" > "MarkdownEditor/$dir/.keep"
  fi
done
mkdir -p MarkdownEditorTests
# 测试目录同样放 .keep：git 不跟踪空目录，fresh clone 后 xcodegen 会因 sources 路径缺失失败
# Also place .keep here: git does not track empty dirs; fresh clone would break xcodegen sources path
if [ ! -f MarkdownEditorTests/.keep ]; then
  echo "# 由对应微任务填充 / Filled by corresponding micro-task" > MarkdownEditorTests/.keep
fi

echo "===> [4/4] 生成 Xcode 工程 + 下载 Web 资源 / Generate project + download web assets..."
xcodegen generate
bash scripts/download-web-assets.sh

echo ""
echo "✅ Bootstrap 完成 / Done."
echo "   打开工程 / Open project: open MarkdownEditor.xcodeproj"
echo "   构建某 POC / Build a POC: xcodebuild -project MarkdownEditor.xcodeproj -scheme POC-S-001-MermaidRender build"
echo "   构建 MVP / Build MVP:     xcodebuild -project MarkdownEditor.xcodeproj -scheme MarkdownEditor -destination 'platform=macOS' build"
echo "   跑 MVP 测试 / Run tests:  xcodebuild test -project MarkdownEditor.xcodeproj -scheme MarkdownEditor -destination 'platform=macOS'"
