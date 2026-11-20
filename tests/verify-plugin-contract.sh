#!/usr/bin/env bash
# Verifies OpenCode plugin install contract v1 (R1-R7) against both host
# generations: scan-dir layout, zero load warnings, one activation per process.
#
# Usage: tests/verify-plugin-contract.sh [rounds]
# Environment: V1_BIN (default opencode), V2_BIN (default .var/opencode-v2/opencode)
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ROUNDS="${1:-3}"
V1_BIN="${V1_BIN:-opencode}"
V2_BIN="${V2_BIN:-$PROJECT_DIR/.var/opencode-v2/opencode}"
WORK="$PROJECT_DIR/tests/.tmp-plugin-contract.$$"
HOME_DIR="$WORK/home"
CFG="$HOME_DIR/.config/opencode"
LOG="$HOME_DIR/.local/state/opencode-plan-trigger/plan-trigger.log"
FAILED=0
HOSTS_RUN=0
HOSTS_SKIPPED=""

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  printf '❌ %s\n' "$1"
  FAILED=1
}

loaded_count() {
  if [[ -f "$LOG" ]]; then rg -c 'plan-trigger loaded' "$LOG" || true; else printf '0'; fi
}

check_scan_dirs() {
  local dirs
  dirs="$(fdfind --hidden --no-ignore --type d --max-depth 2 . "$CFG/plugin" "$CFG/plugins" 2>/dev/null || true)"
  [[ -z "$dirs" ]] || fail "扫描目录出现子目录（契约 R1）：$dirs"
}

run_case() {
  local label="$1" round="$2" logfile="$3"
  shift 3
  local before after load_fail activations
  before="$(loaded_count)"
  timeout 120 "$@" >"$logfile" 2>&1 || true
  load_fail="$(rg -c 'failed to load plugin' "$logfile" || true)"
  after="$(loaded_count)"
  activations=$((after - before))
  [[ "$load_fail" -eq 0 ]] || fail "$label 第${round}轮 failed to load plugin=$load_fail"
  [[ "$activations" -eq 1 ]] || fail "$label 第${round}轮 激活数=$activations（应为 1）"
  printf 'PASS: %s 第%s轮 零告警 激活=%s\n' "$label" "$round" "$activations"
}

mkdir -p "$HOME_DIR"
OPENCODE_CONFIG_DIR="$CFG" "$PROJECT_DIR/install.sh" >/dev/null
export HOME="$HOME_DIR"

check_scan_dirs
[[ -f "$CFG/plugin/plan-trigger.ts" ]] || fail "缺少入口 $CFG/plugin/plan-trigger.ts"
[[ -f "$CFG/plan-trigger-lib/index.mjs" ]] || fail "缺少共享库 $CFG/plan-trigger-lib/index.mjs"

if [[ -x "$V2_BIN" ]]; then
  HOSTS_RUN=$((HOSTS_RUN + 1))
  for round in $(seq 1 "$ROUNDS"); do
    run_case "v2" "$round" "$WORK/v2-$round.log" \
      "$V2_BIN" --standalone --print-logs --log-level debug debug agents
  done
  check_scan_dirs
else
  HOSTS_SKIPPED+=" v2"
  printf 'SKIP: v2 宿主 %s 不可执行\n' "$V2_BIN"
fi

# `opencode debug info` is a v1-only subcommand: a v2 host rejects it, so the
# entry assertion may only run when that host answers it. Without this guard a
# v2-only machine reports "entry missing" instead of "no v1 host" (issue 3a014eb2).
# The v2 branch above already guards on executability; this one mirrors it.
V1_READY=0
if [[ -x "$V1_BIN" ]] && "$V1_BIN" debug info >/dev/null 2>&1; then
  V1_READY=1
fi

if [[ "$V1_READY" -eq 1 ]]; then
  HOSTS_RUN=$((HOSTS_RUN + 1))
  if ! "$V1_BIN" debug info 2>/dev/null | rg -q 'plugin/plan-trigger.ts'; then
    fail "v1 debug info 未列出 plan-trigger.ts 入口（宿主支持 debug info，说明入口未加载）"
  fi
  for round in $(seq 1 "$ROUNDS"); do
    run_case "v1" "$round" "$WORK/v1-$round.log" \
      "$V1_BIN" run hi --model nonexistent/nonexistent --print-logs --log-level DEBUG
  done
else
  HOSTS_SKIPPED+=" v1"
  printf 'SKIP: v1 宿主 %s 不可执行或不支持 debug info\n' "$V1_BIN"
fi

if [[ "$HOSTS_RUN" -eq 0 ]]; then
  printf '\n无可用宿主（v1 与 v2 均跳过），契约未验收%s\n' "$HOSTS_SKIPPED"
  exit 1
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf '\n契约验收失败\n'
  exit 1
fi
printf '\n契约验收通过（%s 个宿主各 %s 轮；跳过:%s）\n' "$HOSTS_RUN" "$ROUNDS" "${HOSTS_SKIPPED:- 无}"