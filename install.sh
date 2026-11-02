#!/usr/bin/env bash
# Installs plan-trigger into the OpenCode user config directory.
# Zero arguments: re-running always installs the current checkout state.
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
V1_DIR="$CONFIG_DIR/plugin"
V2_DIR="$CONFIG_DIR/plugins/plan-trigger"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/install.$(date +%Y%m%d).log"
CURRENT_TMP=""

cleanup() {
  if [ -n "$CURRENT_TMP" ]; then
    rm -f "$CURRENT_TMP"
  fi
}

log() { printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG_FILE"; }

fail() {
  log "ERROR" "$1"
  printf '❌ %s（详见 log/install.%s.log）\n' "$1" "$(date +%Y%m%d)"
  exit 1
}

# Copy through a sibling temp file so a concurrent reader never sees a partial file.
install_file_atomic() {
  local source="$1" target="$2"
  CURRENT_TMP="${target}.tmp.$$"
  install -m 0644 "$source" "$CURRENT_TMP" || fail "复制失败: $source"
  mv -f "$CURRENT_TMP" "$target" || fail "安装失败: $target"
  CURRENT_TMP=""
}

install_tree() {
  local target="$1" entry="$2" name="$3" file
  mkdir -p "$target/plan-trigger-lib" 2>/dev/null || fail "无法写入 $target（检查目录权限）"
  rm -f "$target/plan-trigger-lib/"*.mjs
  for file in "$PROJECT_DIR"/src/plan-trigger-lib/*.mjs; do
    install_file_atomic "$file" "$target/plan-trigger-lib/$(basename "$file")"
  done
  install_file_atomic "$PROJECT_DIR/src/$entry" "$target/$name"
  log "INFO" "installed $target/$name"
}

verify_sources() {
  local file
  [ -d "$PROJECT_DIR/src/plan-trigger-lib" ] || fail "源码目录缺失: src/plan-trigger-lib"
  command -v node >/dev/null 2>&1 || return 0
  for file in "$PROJECT_DIR"/src/plan-trigger-lib/*.mjs; do
    node --check "$file" >/dev/null 2>&1 || fail "语法检查失败: $(basename "$file")"
  done
  log "PASS" "syntax check"
}

main() {
  trap cleanup EXIT
  mkdir -p "$LOG_DIR"
  verify_sources
  install_tree "$V1_DIR" "plan-trigger-v1.ts" "plan-trigger.ts"
  install_tree "$V2_DIR" "plan-trigger-v2.ts" "index.ts"
  log "PASS" "install complete"
  printf '✅ plan-trigger installed\n   v1: %s/plan-trigger.ts\n   v2: %s/index.ts\n' "$V1_DIR" "$V2_DIR"
}

main "$@"