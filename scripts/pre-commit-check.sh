#!/usr/bin/env bash
# Local pre-commit hook: syntax checks without external dependencies.
set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/pre-commit-check.$(date +%Y%m%d).log"

record() { printf '[%s] [%s] [stage:syntax] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG_FILE"; }

check_file() {
  local file="$1"
  case "$file" in
    *.mjs)
      command -v node >/dev/null 2>&1 || return 0
      if node --check "$file" >>"$LOG_FILE" 2>&1; then
        record PASS "$file"
      else
        record FAIL "$file"
        return 1
      fi
      ;;
    *.sh)
      if bash -n "$file" >>"$LOG_FILE" 2>&1; then
        record PASS "$file"
      else
        record FAIL "$file"
        return 1
      fi
      ;;
  esac
}

main() {
  local file status=0
  mkdir -p "$LOG_DIR"
  for file in "$@"; do
    [ -f "$file" ] || continue
    check_file "$file" || status=1
  done
  if [ "$status" -ne 0 ]; then
    echo "❌ syntax check（详见 log/pre-commit-check.$(date +%Y%m%d).log）"
  fi
  return "$status"
}

main "$@"