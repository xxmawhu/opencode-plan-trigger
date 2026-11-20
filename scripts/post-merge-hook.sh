#!/usr/bin/env bash
# post-merge hook: reinstall the plugin after `git pull`.
#
# Logging is diagnostic only: a ./log/ owned by another account or inside a
# read-only checkout must never decide whether install.sh runs. A failed
# redirect would skip the command body entirely, leaving the plugin stale while
# the hook prints a path to a log that was never created (issue 7d9eb8f1).
# When the log cannot be opened this hook degrades to stderr and installs anyway.
# No `set -e` on purpose: a diagnostic failure must never abort the hook; every
# step checks its own return code instead.
set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/post-merge-hook.$(date +%Y%m%d).log"
LOG_READY=0

# Probe once before doing anything else. Both steps run with stderr already on
# /dev/null: a denied redirection would otherwise print the shell's own
# "Permission denied" before this function gets to report the fallback.
# The probe appends nothing, so a writable log keeps its existing content.
init_log() {
  if ( exec 2>/dev/null; mkdir -p "$LOG_DIR" && : >>"$LOG_FILE" ); then
    LOG_READY=1
    return 0
  fi
  LOG_READY=0
  # [log-review] 预期内场景：只读安装副本、他人属主的 ./log/ 是已知例外，install 照常执行。
  # 降级为 warning 而非 error：日志只是诊断信息，hook 成败与安装产物都不受影响。
  # 触发条件：./log/ 不可写；影响范围：仅日志去向改为 stderr。
  printf '[%s] [WARNING] [stage:start] 日志目录不可写（只读副本或他人属主），输出转 stderr：%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_DIR" >&2
}

# A write can start failing after the probe (directory replaced, disk full).
# Re-probe before each stage so a log write never turns into a skipped install.
log_ready() {
  local stage="$1"
  [[ "$LOG_READY" -eq 1 ]] || return 1
  if { : >>"$LOG_FILE"; } 2>/dev/null; then
    return 0
  fi
  LOG_READY=0
  # [log-review] 预期内场景：探针通过后目录权限或磁盘状态变化，属已知例外，install 继续。
  # 降级为 warning 而非 error：诊断信息无处落盘，不构成安装故障。
  # 触发条件：日志追加不可写；影响范围：仅日志去向改为 stderr。
  printf '[%s] [WARNING] [stage:%s] 日志写入中断（目录或磁盘变化），输出转 stderr：%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$stage" "$LOG_FILE" >&2
  return 1
}

log_line() {
  local level="$1" stage="$2" message="$3" line
  line="$(printf '[%s] [%s] [stage:%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$stage" "$message")"
  if log_ready "$stage"; then
    printf '%s\n' "$line" >>"$LOG_FILE"
    if [[ "$level" != INFO ]]; then
      printf '%s\n' "$line" >&2
    fi
    return 0
  fi
  printf '%s\n' "$line" >&2
  return 0
}

# Runs the stage whether or not the log is writable; command output follows the
# log destination so a real failure reason is never swallowed.
run_stage() {
  local name="$1" rc=0
  shift
  log_line INFO "$name" "start: $*"
  if log_ready "$name"; then
    "$@" >>"$LOG_FILE" 2>&1
    rc=$?
  else
    "$@" >&2
    rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    log_line INFO "$name" "done"
    return 0
  fi
  log_line ERROR "$name" "failed (rc=$rc): $*"
  return 1
}

main() {
  init_log
  if run_stage install "$PROJECT_DIR/install.sh"; then
    echo "✅ post-merge install"
    return 0
  fi
  # Point at the log only when it really exists; otherwise say where output went.
  if [[ "$LOG_READY" -eq 1 ]]; then
    printf '❌ post-merge install（详见 log/%s）\n' "$(basename "$LOG_FILE")"
  else
    printf '❌ post-merge install（./log/ 不可写，日志已降级 stderr）\n'
  fi
  return 1
}

main "$@"
