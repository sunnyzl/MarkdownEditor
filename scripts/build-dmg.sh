#!/bin/bash
# build-dmg.sh — MarkdownEditor DMG 打包脚本（Release archive → DMG）
# 用法：bash scripts/build-dmg.sh [输出目录，默认 ~/Desktop]
# 无签名版（个人/熟人分发：右键→打开 放行）；续费开发者后可加签名+公证（见注释）

set -e
cd "$(dirname "$0")/.."   # 项目根

OUT_DIR="${1:-$HOME/Desktop}"
ARCHIVE="/tmp/MarkdownEditor.xcarchive"
DMG_NAME="MarkdownEditor.dmg"
STAGING="/tmp/dmg-staging"

echo "=== 1. Archive 构建（Release）==="
xcodebuild archive -scheme MarkdownEditor -configuration Release \
  -archivePath "$ARCHIVE" -destination 'platform=macOS' 2>&1 | grep -E "ARCHIVE SUCCEEDED|Archive failed|error:" 

APP="$ARCHIVE/Products/Applications/MarkdownEditor.app"
[ -d "$APP" ] || { echo "❌ Archive 失败"; exit 1; }

# ── 可选：签名（有 Developer ID 证书时启用）──
# CERT="Developer ID Application: 你的名字 (TEAMID)"
# codesign --force --options runtime --sign "$CERT" "$APP"
# ── 可选：公证（签名后）──
# ditto -c -k --keepParent "$APP" /tmp/mdeditor-notary.zip
# xcrun notarytool submit /tmp/mdeditor-notary.zip --apple-id 你的邮箱 \
#   --password 专用密码 --team-id TEAMID --wait
# xcrun stapler staple "$APP"

echo "=== 2. 准备 DMG 内容 ==="
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "=== 3. 创建 DMG ==="
rm -f "$OUT_DIR/$DMG_NAME"
hdiutil create -volname "MarkdownEditor" -srcfolder "$STAGING" \
  -ov -format UDZO "$OUT_DIR/$DMG_NAME" 2>&1 | tail -1

echo ""
echo "✅ DMG 生成: $OUT_DIR/$DMG_NAME"
ls -la "$OUT_DIR/$DMG_NAME"
echo ""
echo "提示：无签名版分发时，接收者首次打开需 右键→打开→仍要打开"
