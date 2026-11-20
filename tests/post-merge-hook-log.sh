#!/usr/bin/env bash
# Regression test for scripts/post-merge-hook.sh: a ./log/ that is not writable
# must never decide whether install.sh runs (issue 7d9eb8f1).
# Exit code 0 = all cases pass; 1 = at least one case failed.
set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$PROJECT_DIR/tests/.tmp-post-merge.$$"
FAILED=0

cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" -eq 1 ]]; then
    printf 'PASS: %s\n' "$label"
    return
  fi
  FAILED=1
  printf 'FAIL: %s%s\n' "$label" "${detail:+ -> $detail}"
}

# Fresh copy of the hook and the installer payload under $WORK/<case>/repo.
make_repo() {
  local dir="$1"
  mkdir -p "$dir/repo"
  cp -a "$PROJECT_DIR/install.sh" "$PROJECT_DIR/plugin" "$PROJECT_DIR/plan-trigger-lib" "$dir/repo/"
  mkdir -p "$dir/repo/scripts"
  cp -a "$PROJECT_DIR/scripts/post-merge-hook.sh" "$dir/repo/scripts/"
}

run_hook() {
  local dir="$1" config="$2" out="$3"
  ( cd "$dir/repo" && OPENCODE_CONFIG_DIR="$config" bash scripts/post-merge-hook.sh ) >"$out" 2>&1
}

mkdir -p "$WORK"

# Case 1: writable ./log/ keeps the previous behaviour and writes the stage log.
CASE="$WORK/writable"
make_repo "$CASE"
run_hook "$CASE" "$CASE/config/opencode" "$CASE/out"
rc=$?
LOG="$CASE/repo/log/post-merge-hook.$(date +%Y%m%d).log"
check "日志可写: hook rc=0" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)" "rc=$rc"
check "日志可写: 插件已安装" "$([[ -f "$CASE/config/opencode/plugin/plan-trigger.ts" ]] && echo 1 || echo 0)"
check "日志可写: 记录 stage:install" "$(rg -q '\[stage:install\] start' "$LOG" 2>/dev/null && echo 1 || echo 0)"

# Case 2: read-only ./log/ must still execute install.sh and say so.
CASE="$WORK/readonly-log"
make_repo "$CASE"
mkdir -p "$CASE/repo/log"
chmod 0500 "$CASE/repo/log"
run_hook "$CASE" "$CASE/config/opencode" "$CASE/out"
rc=$?
check "日志只读: hook rc=0" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)" "rc=$rc output=$(tr '\n' '|' <"$CASE/out")"
check "日志只读: install.sh 已执行" "$([[ -f "$CASE/config/opencode/plugin/plan-trigger.ts" ]] && echo 1 || echo 0)"
check "日志只读: 提示日志已降级 stderr" "$(rg -q '日志已降级 stderr' "$CASE/out" && echo 1 || echo 0)" "$(tr '\n' '|' <"$CASE/out")"
check "日志只读: 不再提示不存在的日志文件" "$(! rg -q '详见 log/' "$CASE/out" && echo 1 || echo 0)" "$(tr '\n' '|' <"$CASE/out")"
check "日志只读: 日志目录确无新文件" "$([[ -z "$(fdfind --hidden --no-ignore --type f --max-depth 1 . "$CASE/repo/log" 2>/dev/null)" ]] && echo 1 || echo 0)"
chmod 0755 "$CASE/repo/log"

# Case 3: read-only ./log/ plus a config parent that cannot be written:
# the hook must fail and expose install.sh's real error on stderr.
CASE="$WORK/readonly-log-and-config"
make_repo "$CASE"
mkdir -p "$CASE/repo/log" "$CASE/ro-config"
chmod 0500 "$CASE/repo/log" "$CASE/ro-config"
run_hook "$CASE" "$CASE/ro-config/opencode" "$CASE/out"
rc=$?
check "双重只读: hook rc=1" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)" "rc=$rc output=$(tr '\n' '|' <"$CASE/out")"
check "双重只读: 暴露 install.sh 真实错误" "$(rg -q 'Permission denied|无法写入 opencode 配置目录' "$CASE/out" && echo 1 || echo 0)" "$(tr '\n' '|' <"$CASE/out")"
check "双重只读: 提示日志已降级 stderr" "$(rg -q '日志已降级 stderr' "$CASE/out" && echo 1 || echo 0)" "$(tr '\n' '|' <"$CASE/out")"
chmod 0755 "$CASE/repo/log" "$CASE/ro-config"

# Case 4: an existing but unwritable log file (directory writable) still runs the stage.
CASE="$WORK/readonly-logfile"
make_repo "$CASE"
mkdir -p "$CASE/repo/log"
LOG="$CASE/repo/log/post-merge-hook.$(date +%Y%m%d).log"
printf 'keep\n' >"$LOG"
chmod 0400 "$LOG"
run_hook "$CASE" "$CASE/config/opencode" "$CASE/out"
rc=$?
check "日志文件只读: hook rc=0" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)" "rc=$rc output=$(tr '\n' '|' <"$CASE/out")"
check "日志文件只读: install.sh 已执行" "$([[ -f "$CASE/config/opencode/plugin/plan-trigger.ts" ]] && echo 1 || echo 0)"
chmod 0600 "$LOG"

if [[ "$FAILED" -ne 0 ]]; then
  printf '\n回归失败\n'
  exit 1
fi
printf '\n回归通过（4 场景）\n'
