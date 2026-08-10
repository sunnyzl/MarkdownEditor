#!/usr/bin/env bash
# writeback-ad-status.sh — 把 POC 结论回写到 ARCHITECTURE_SPINE 的 AD 状态
# Writes POC conclusions back into ARCHITECTURE_SPINE AD statuses.
#
# 用法 / Usage:
#   bash scripts/writeback-ad-status.sh             # dry-run，只显示 diff
#   bash scripts/writeback-ad-status.sh --apply      # 实际写入（先备份 .bak）
#
# 安全 / Safety: 默认 dry-run；--apply 时创建 .bak 备份。
set -euo pipefail
cd "$(dirname "$0")/.."

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

SPINE="thoughts/shared/artifacts/mac-markdown-editor/ARCHITECTURE_SPINE.md"
[ -f "$SPINE" ] || { echo "ERROR: $SPINE 不存在"; exit 1; }

# 读取某 POC 子报告的 status 字段 / read status field from a POC sub-report
read_status() {  # read_status <report-path>
  local f="$1"
  [ -f "$f" ] || { echo "PENDING"; return; }
  # 提取 frontmatter 中 status: 行
  awk '/^---$/{c++; next} c==1 && /^status:/ {print $2; exit}' "$f"
}

# 各 POC 报告路径 / POC report paths（bash 3.2 兼容：并行索引数组）
AD_KEYS=("AD-4" "AD-5" "AD-6" "AD-7" "AD-8")
REPORTS=(
  "POC-S-001-MermaidRender/POCReport.md"
  "POC-S-002-BundleLoad/POCReport.md"
  "POC-S-003-PreviewUpdate/POCReport.md"
  "POC-S-004-DownSourceMap/POCReport.md"
  "POC-S-005-Highlightr/POCReport.md"
)

# AD 状态行锚点模式（ARCHITECTURE_SPINE 当前格式）
# Status line anchor pattern (current ARCHITECTURE_SPINE format).
AD_STATUS_PATTERNS=(
  "### AD-4：Mermaid 代码块 DOM 转换方案"
  "### AD-5：WKWebView 本地资源加载策略"
  "### AD-6：预览更新策略"
  "### AD-7：滚动 / 光标同步策略"
  "### AD-8：双轨语法高亮"
)

# 默认 Accepted 状态文案（GO 时使用）
AD_NEW_STATUS_GO=(
  "**Status:** **Accepted（POC S-001 验证通过，方案见 POCReport）**"
  "**Status:** **Accepted（POC S-002 验证通过，loadFileURL+UMD）**"
  "**Status:** **Accepted（POC S-003 验证通过，主方案见 POCReport）**"
  "**Status:** **Accepted（MVP 比例同步）/ v2 路径确认（POC S-004）**"
  "**Status:** **Accepted（POC S-005 验证，Highlightr 维持）**"
)

# PARTIAL 降级状态文案（仅 AD-8 有意义的降级分支）
AD_NEW_STATUS_PARTIAL=(
  "**Status:** **Accepted（POC S-001 验证通过）**"
  "**Status:** **Accepted（POC S-002 验证通过）**"
  "**Status:** **Accepted（POC S-003 验证通过）**"
  "**Status:** **Accepted（MVP 比例同步，v2 待定）**"
  "**Status:** **Accepted（降级：MVP 编辑器纯文本，v1 评估 Splash/SwiftSyntax）**"
)

echo "=== POC 状态回写 / AD status writeback ==="
echo "目标 / Target: $SPINE"
echo "模式 / Mode: $([ $APPLY -eq 1 ] && echo 'APPLY (写入)' || echo 'DRY-RUN (只显示)')"
echo ""

# 1. 汇总各 POC 状态 / summarize POC statuses
ALL_GO=1
i=0
while [ $i -lt ${#AD_KEYS[@]} ]; do
  ad="${AD_KEYS[$i]}"
  st=$(read_status "${REPORTS[$i]}")
  echo "  $ad ← ${REPORTS[$i]} : status=$st"
  if [[ "$st" != "GO" && "$ad" != "AD-7" && "$ad" != "AD-8" ]]; then
    # AD-4/5/6 是 High，必须 GO；AD-7/8 非阻塞
    [ "$st" = "GO" ] || ALL_GO=0
  fi
  i=$((i + 1))
done
echo ""
echo "High 风险门控（AD-4/5/6 全 GO）：$([ $ALL_GO -eq 1 ] && echo '✅ READY' || echo '⚠️ 未全 GO（检查 NO-GO/PARTIAL）')"
echo ""

# 2. 备份 + 写入 / backup + write
if [ $APPLY -eq 1 ]; then
  cp "$SPINE" "${SPINE}.bak.$(date +%Y%m%d%H%M%S)"
  echo "已备份 / Backed up to ${SPINE}.bak.*"
fi

i=0
while [ $i -lt ${#AD_KEYS[@]} ]; do
  ad="${AD_KEYS[$i]}"
  st=$(read_status "${REPORTS[$i]}")
  [ "$st" = "GO" ] || [ "$st" = "PARTIAL" ] || { echo "  $ad: status=$st, 跳过（未完成）/ skipped"; i=$((i + 1)); continue; }

  anchor="${AD_STATUS_PATTERNS[$i]}"
  # 按 status 选择文案：GO 用 GO 文案，PARTIAL 用降级文案
  if [ "$st" = "GO" ]; then
    newstatus="${AD_NEW_STATUS_GO[$i]}"
  else
    newstatus="${AD_NEW_STATUS_PARTIAL[$i]}"
  fi

  # 在锚点后的 5 行内查找 Status 行并替换 / find Status line within 5 lines after anchor
  if [ $APPLY -eq 1 ]; then
    # 用 awk 精确替换（替换后重置标志，避免同段重复替换）
    awk -v anchor="$anchor" -v newstatus="$newstatus" '
      $0 ~ anchor { in_section=1; anchor_line=NR; replaced=0; print; next }
      in_section && !replaced && (NR - anchor_line) <= 5 && /^\- \*\*Status:/ {
        print "- " newstatus; replaced=1; in_section=0; next
      }
      { print }
    ' "$SPINE" > "${SPINE}.tmp" && mv "${SPINE}.tmp" "$SPINE"
    echo "  $ad: ✅ 已更新（${st}）→ $newstatus"
  else
    echo "  $ad: [DRY-RUN] ($st) 将替换为 / would set → $newstatus"
  fi
  i=$((i + 1))
done

echo ""
if [ $APPLY -eq 0 ]; then
  echo "（dry-run 未写入。确认无误后加 --apply 执行。）"
  echo "(Dry-run. Add --apply to write.)"
fi
