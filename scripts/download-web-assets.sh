#!/usr/bin/env bash
# download-web-assets.sh — 版本锁定的 Web 资源下载
# Version-locked web asset downloader. NFR-033 requires build-time version pinning.
# 适配说明 / Adaptation note: Mermaid v11+ 的 GitHub release 不再附带独立 dist 资产，
# 统一改用 jsDelivr CDN（npm 镜像，版本锁定）。所有 URL 均经验证可用。
# Uses jsDelivr CDN (version-locked npm mirror) for all assets.
set -euo pipefail
cd "$(dirname "$0")/.."

# ── 版本锁 / Version pins (NFR-033) ──
MERMAID_VERSION="11.4.0"
KATEX_VERSION="0.16.11"
HIGHLIGHTJS_VERSION="11.10.0"
MORPHDOM_VERSION="2.7.1"

ASSETS="WebAssets"
mkdir -p "$ASSETS"/{mermaid,katex,highlight,morphdom,templates}

dl() {  # dl <url> <output-path>  下载并校验 / download + verify
  local url="$1" out="$2"
  echo "  ↓ $url"
  curl -fsSL "$url" -o "$out"
  if [ ! -s "$out" ]; then
    echo "ERROR: 下载失败或空文件 / Download failed or empty: $out"
    exit 1
  fi
  echo "    → $(du -h "$out" | cut -f1) → $out"
}

echo "===> 下载 Mermaid v${MERMAID_VERSION}..."
dl "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VERSION}/dist/mermaid.min.js" \
   "$ASSETS/mermaid/mermaid.min.js"

echo "===> 下载 KaTeX v${KATEX_VERSION}..."
dl "https://cdn.jsdelivr.net/npm/katex@${KATEX_VERSION}/dist/katex.min.js" \
   "$ASSETS/katex/katex.min.js"
dl "https://cdn.jsdelivr.net/npm/katex@${KATEX_VERSION}/dist/katex.min.css" \
   "$ASSETS/katex/katex.min.css"
dl "https://cdn.jsdelivr.net/npm/katex@${KATEX_VERSION}/dist/contrib/auto-render.min.js" \
   "$ASSETS/katex/auto-render.min.js"
# KaTeX 字体（CSS 依赖 woff2）/ KaTeX fonts (CSS depends on woff2)
mkdir -p "$ASSETS/katex/fonts"
for font in KaTeX_Main-Regular KaTeX_Math-Italic KaTeX_Size1-Regular KaTeX_Size2-Regular \
            KaTeX_AMS-Regular KaTeX_Caligraphic-Regular KaTeX_Fraktur-Regular KaTeX_SansSerif-Regular \
            KaTeX_Typewriter-Regular; do
  dl "https://cdn.jsdelivr.net/npm/katex@${KATEX_VERSION}/dist/fonts/${font}.woff2" \
     "$ASSETS/katex/fonts/${font}.woff2"
done

echo "===> 下载 highlight.js v${HIGHLIGHTJS_VERSION}..."
dl "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@${HIGHLIGHTJS_VERSION}/build/highlight.min.js" \
   "$ASSETS/highlight/highlight.min.js"
# 默认 github 主题 CSS / Default github theme CSS
dl "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@${HIGHLIGHTJS_VERSION}/build/styles/github.min.css" \
   "$ASSETS/highlight/github.min.css"
dl "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@${HIGHLIGHTJS_VERSION}/build/styles/github-dark.min.css" \
   "$ASSETS/highlight/github-dark.min.css"

echo "===> 下载 morphdom v${MORPHDOM_VERSION}（S-003 选项 C）..."
dl "https://cdn.jsdelivr.net/npm/morphdom@${MORPHDOM_VERSION}/dist/morphdom.min.js" \
   "$ASSETS/morphdom/morphdom.min.js"

# ── 版本清单 / Version manifest（NFR-033 可追溯）──
cat > "$ASSETS/VERSIONS.txt" <<EOF
# WebAssets 版本清单 / WebAssets version manifest
# 由 download-web-assets.sh 生成，请勿手改 / Generated, do not edit by hand.
# CDN: jsDelivr (npm/gh mirror, version-locked)
mermaid = v${MERMAID_VERSION}   # S-001/002/003 共享
katex   = v${KATEX_VERSION}     # S-002/003 共享
highlight.js = v${HIGHLIGHTJS_VERSION}  # S-002 共享
morphdom = v${MORPHDOM_VERSION}  # S-003 选项 C
generated = $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo ""
echo "✅ Web 资源下载完成 / Done. 总大小 / Total size:"
du -sh "$ASSETS"
