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
  for round in $(seq 1 "$ROUNDS"); do
    run_case "v2" "$round" "$WORK/v2-$round.log" \
      "$V2_BIN" --standalone --print-logs --log-level debug debug agents
  done
  check_scan_dirs
else
  printf 'SKIP: v2 宿主 %s 不可执行\n' "$V2_BIN"
fi

for round in $(seq 1 "$ROUNDS"); do
  if ! "$V1_BIN" debug info 2>/dev/null | rg -q 'plugin/plan-trigger.ts'; then
    fail "v1 debug info 未列出 plan-trigger.ts 入口"
  fi
  run_case "v1" "$round" "$WORK/v1-$round.log" \
    "$V1_BIN" run hi --model nonexistent/nonexistent --print-logs --log-level DEBUG
done

if [[ "$FAILED" -ne 0 ]]; then
  printf '\n契约验收失败\n'
  exit 1
fi
printf '\n契约验收通过（v1/v2 各 %s 轮）\n' "$ROUNDS"