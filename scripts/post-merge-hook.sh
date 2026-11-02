#!/usr/bin/env bash
# post-merge hook: reinstall the plugin after `git pull`.
set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/post-merge-hook.$(date +%Y%m%d).log"

run_stage() {
  local name="$1"
  shift
  printf '[%s] [INFO] [stage:%s] start: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$*" >>"$LOG_FILE"
  if "$@" >>"$LOG_FILE" 2>&1; then
    printf '[%s] [PASS] [stage:%s] done\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" >>"$LOG_FILE"
    return 0
  fi
  printf '[%s] [FAIL] [stage:%s] failed: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$*" >>"$LOG_FILE"
  return 1
}

main() {
  mkdir -p "$LOG_DIR"
  if run_stage install "$PROJECT_DIR/install.sh"; then
    echo "✅ post-merge install"
    return 0
  fi
  echo "❌ post-merge install（详见 log/post-merge-hook.$(date +%Y%m%d).log）"
  return 1
}

main "$@"