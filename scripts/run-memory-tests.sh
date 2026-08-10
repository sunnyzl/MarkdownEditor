#!/bin/bash
# run-memory-tests.sh — 内存自动化检测（设计 §批次2 方案 D2）
# leaks:    进程级 Swift/ObjC 内存泄漏检测（MallocDebug）
# xctrace:  Instruments 命令行 Allocations 录制（图形化分析）
#
# Usage:
#   ./scripts/run-memory-tests.sh leaks    # 快速泄漏检测
#   ./scripts/run-memory-tests.sh xctrace  # Allocations 录制（生成 .trace）
#   ./scripts/run-memory-tests.sh all      # 两者都跑
#
# Exit codes: 0 = 无泄漏, 1 = 检测到泄漏, 2 = 工具不可用
# Memory automation (design batch 2 plan D2): leaks + xctrace CLI.

set -euo pipefail

SCHEME="MarkdownEditor"
APP_NAME="MarkdownEditor"
TRACE_OUT="${TRACE_OUT:-/tmp/MarkdownEditor-memory.trace}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/MarkdownEditor-mem-dd}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${YELLOW}[mem]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}  $*"; }
fail() { echo -e "${RED}[fail]${NC} $*"; }

# ⚠️ 清理 trap：脚本退出（含 set -e 提前退出）时确保 app 进程不残留
# Cleanup trap: ensure launched app quits on exit (incl. set -e early exit)
trap 'osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || killall "${APP_NAME}" 2>/dev/null || true' EXIT

# 构建调试版（确保符号） / Build debug (symbols required)
build_app() {
    log "building ${SCHEME} (DerivedData=${DERIVED_DATA})..."
    xcodebuild build \
        -scheme "${SCHEME}" \
        -configuration Debug \
        -derivedDataPath "${DERIVED_DATA}" \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        >/dev/null 2>&1 || { fail "build 失败"; exit 2; }
    ok "build done"
}

app_path() {
    # -print -quit 避免管道 head 提前关闭致 SIGPIPE（pipefail 下隐患）
    # -print -quit avoids SIGPIPE from head closing the pipe early under pipefail.
    find "${DERIVED_DATA}/Build/Products" -name "${APP_NAME}.app" -type d -print -quit
}

# leaks 检测：启动 app，对主进程 + WebContent 进程执行 leaks
# leaks check: launch app, run leaks on main + WebContent processes.
run_leaks() {
    command -v leaks >/dev/null 2>&1 || { fail "leaks 工具不可用"; exit 2; }
    build_app
    local APP="$(app_path)"
    [ -z "${APP}" ] && { fail ".app 未找到"; exit 2; }

    log "launching ${APP}..."
    open "${APP}"
    sleep 6   # 等启动稳定 / wait for stable launch

    local LEAK_FOUND=0
    # doc-reviewer MINOR #4 修复：用 -f 模糊匹配（进程名可能截断/PID 后缀），并打印命中数便于发现漏检
    # ⚠️ 主进程 PID 为主要目标（Swift @MainActor 对象泄漏在主进程）；
    # WebContent 为补充（可能含其它 app 的 WebContent，结果需人工判读）。
    # Primary target = main app PID (Swift @MainActor objects live there);
    # WebContent is supplementary (may include other apps' WebContent — interpret manually).
    # || true: pgrep 无匹配返回 1，避免 set -e 提前退出。
    PIDS=$(pgrep -f "${APP_NAME}/Contents/MacOS/${APP_NAME}" || true; pgrep -f "WebContent" || true)
    echo "[run_leaks] matched PIDs: $(echo "$PIDS" | wc -l | tr -d ' ')"
    for PID in $PIDS; do
        log "leaks PID=${PID}..."
        # ⚠️ 修复：原 'leaks.*:' 恒命中报告头 'leaks Report Version:' → 改为锚定汇总行
        # 'leaks: N leaks for X bytes'，仅 N≥1 命中（N=0 不匹配，报告头不匹配）。
        # Fix: anchor to summary line 'leaks: N leaks for X bytes' — matches only N≥1.
        if leaks "${PID}" 2>&1 | tee "/tmp/leaks-${PID}.log" | grep -qE '^leaks: [1-9]'; then
            fail "PID ${PID} 检测到泄漏（详见 /tmp/leaks-${PID}.log）"
            LEAK_FOUND=1
        else
            ok "PID ${PID} 无泄漏"
        fi
    done

    log "quitting ${APP_NAME}..."
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || killall "${APP_NAME}" 2>/dev/null || true
    # if/else 避免 &&|| 反模式（ok 若返回非零会误触 exit 1）
    # if/else avoids &&|| anti-pattern (ok returning non-zero would wrongly trigger exit 1)
    if [ "${LEAK_FOUND}" -eq 0 ]; then
        ok "leaks 全通过"
    else
        exit 1
    fi
}

# xctrace Allocations 录制：开关窗场景 10 次，导出 .trace
# xctrace Allocations: open/close window 10x, export .trace.
run_xctrace() {
    command -v xctrace >/dev/null 2>&1 || { fail "xctrace 不可用（需 Xcode 12+）"; exit 2; }
    build_app
    local APP="$(app_path)"
    [ -z "${APP}" ] && { fail ".app 未找到"; exit 2; }

    log "xctrace Allocations 录制 → ${TRACE_OUT}..."
    # 录制 30s（期间手动开关窗，或脚本触发） / record 30s (manual open/close or scripted)
    xctrace record \
        --template "Allocations" \
        --launch "${APP}" \
        --time-limit 30s \
        --output "${TRACE_OUT}" \
        --env DYLD_SHARED_REGION=avoid 2>&1 | tee /tmp/xctrace.log || true

    ok "trace 已生成：${TRACE_OUT}（用 Instruments.app 打开分析 MainContentState/WKWebView 实例数）"
    log "手动验收：开关窗 10 次，过滤 MainContentState/WKWebView 实例数应稳定"
}

case "${1:-all}" in
    leaks)   run_leaks ;;
    xctrace) run_xctrace ;;
    all)     run_leaks; run_xctrace ;;
    *) echo "Usage: $0 {leaks|xctrace|all}"; exit 2 ;;
esac
