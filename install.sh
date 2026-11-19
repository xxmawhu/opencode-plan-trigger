#!/usr/bin/env bash
# Installs plan-trigger into the OpenCode user config directory.
# Zero arguments: re-running always installs the current checkout state.
#
# OpenCode plugin install contract v1 (see README):
#   R1 scan dirs hold entries only      plugin/ has no implementation/lib dirs
#   R2 shared library outside scans     <config>/plan-trigger-lib/
#   R3 default export is an object      { id, server, setup }
#   R4 single activation per process    one shared entry for v1 + v2
#   R6 idempotent install + cleanup     atomic write, legacy paths removed
#   R7 zero load warnings               see README verification
#
# Host processes may run as accounts other than the installer, so artifacts must
# stay readable by other accounts. Modes are set explicitly and verified
# fail-closed instead of being inherited from the caller's umask.
#
# Logging is diagnostic only: a ./log/ that exists but is not writable (a
# checkout owned by another account, or a read-only install copy) must never
# abort the install. That case degrades to stderr and keeps installing.
set -euo pipefail
umask 022

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
ENTRY_DIR="$CONFIG_DIR/plugin"
LIB_DIR="$CONFIG_DIR/plan-trigger-lib"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/install.$(date +%Y%m%d).log"
LOG_READY=0
CLEANUP_TARGET=""

# `find` is used instead of fdfind: installers may run on hosts without fdfind,
# and the portable implementation is part of the install contract (R1/R6).
find_installed() {
  find "$@"
}

# Both steps run with stderr already on /dev/null: a failed redirection would
# otherwise print the shell's own "Permission denied" before `set -e` fires.
# The probe appends nothing, so a writable log keeps its existing content.
init_log() {
  if ( exec 2>/dev/null; mkdir -p "$LOG_DIR" && : >>"$LOG_FILE" ); then
    LOG_READY=1
    return 0
  fi
  LOG_READY=0
  printf '[%s] [WARNING] [stage:start] 日志目录不可写，降级 stderr：%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_DIR" >&2
}

# A write can start failing after the probe (disk full, directory replaced).
# Degrade once instead of letting `set -e` turn a log write into an abort.
log() {
  local level="$1" stage="$2" message="$3" line
  line="$(printf '[%s] [%s] [stage:%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$stage" "$message")"
  if [[ "$LOG_READY" -eq 1 ]]; then
    if printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null; then
      return 0
    fi
    LOG_READY=0
    printf '[%s] [WARNING] [stage:%s] 写日志失败，降级 stderr：%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$stage" "$LOG_FILE" >&2
  fi
  if [[ "$level" != INFO ]]; then
    printf '%s\n' "$line" >&2
  fi
  return 0
}

fail() {
  local stage="$1" message="$2"
  log ERROR "$stage" "$message"
  if [[ "$LOG_READY" -eq 1 ]]; then
    printf '❌ %s（详见 log/install.%s.log）\n' "$message" "$(date +%Y%m%d)"
  else
    printf '❌ %s（./log/ 不可写，日志已降级 stderr）\n' "$message"
  fi
  exit 1
}

cleanup() {
  if [[ -n "$CLEANUP_TARGET" && -e "$CLEANUP_TARGET" ]]; then
    rm -rf "$CLEANUP_TARGET"
  fi
}

# Octal mode test: need=5 (read+execute) for dirs, 4 (read) for files.
has_other_bits() {
  local path="$1" need="$2" mode masked
  mode="$(stat -c '%a' "$path")" || return 1
  masked=$(( 8#$mode & 8#$need ))
  [[ "$masked" -eq "$need" ]]
}

die_on_mode() {
  local stage="$1" path="$2"
  fail "$stage" "安装产物对非 owner 账户不可读：${path}（mode=$(stat -c '%a' "$path")，owner=$(stat -c '%U:%G' "$path")，current=$(id -un)）"
}

# Repair a directory this account owns; foreign-owned parents are reported by
# the fail-closed verification instead. `install -d -m` is used instead of
# chmod so the mode is fixed at creation and never inherited from the umask.
ensure_dir_traversable() {
  local path="$1"
  if [[ -O "$path" ]] && ! has_other_bits "$path" 5; then
    install -d -m 0755 "$path"
  fi
}

verify_tree() {
  local stage="$1" root="$2" path
  has_other_bits "$root" 5 || die_on_mode "$stage" "$root"
  while IFS= read -r path; do
    if [[ -L "$path" ]]; then
      continue
    elif [[ -d "$path" ]]; then
      has_other_bits "$path" 5 || die_on_mode "$stage" "$path"
    else
      has_other_bits "$path" 4 || die_on_mode "$stage" "$path"
    fi
  done < <(find_installed "$root" -mindepth 1)
}

verify_permissions() {
  local stage="verify-permissions" path
  for path in "$CONFIG_DIR" "$ENTRY_DIR" "$LIB_DIR"; do
    has_other_bits "$path" 5 || die_on_mode "$stage" "$path"
  done
  verify_tree "$stage" "$LIB_DIR"
  has_other_bits "$ENTRY_DIR/plan-trigger.ts" 4 || die_on_mode "$stage" "$ENTRY_DIR/plan-trigger.ts"
  log INFO "$stage" "installed tree readable by other accounts (dirs 0755, files 0644)"
}

# True when dst already holds exactly the source library tree (same file set and
# bytes, readable by other accounts), so a reinstall can skip the swap and keep
# inodes and mtimes stable. A permission mismatch forces a fresh swap.
dir_matches() {
  local src="$1" dst="$2" file name
  [[ -d "$dst" ]] || return 1
  has_other_bits "$dst" 5 || return 1
  for file in "$src"/*.mjs; do
    name="$(basename "$file")"
    [[ -f "$dst/$name" ]] && cmp -s "$file" "$dst/$name" && has_other_bits "$dst/$name" 4 || return 1
  done
  for file in "$dst"/*.mjs; do
    name="$(basename "$file")"
    [[ -f "$src/$name" ]] || return 1
  done
  return 0
}

# Replace the library directory as a unit so a concurrent reader never sees a
# partially written tree; the verified temp tree is published with one rename.
replace_dir() {
  local src="$1" dst="$2"
  local tmp="${dst}.new.$$" old="${dst}.old.$$" file name
  if dir_matches "$src" "$dst"; then
    return 0
  fi
  if [[ -e "$dst" && ! -d "$dst" ]]; then
    fail "install-lib" "$dst 已存在且不是目录"
  fi
  rm -rf "$tmp" "$old"
  mkdir -p "$tmp"
  CLEANUP_TARGET="$tmp"
  for file in "$src"/*.mjs; do
    name="$(basename "$file")"
    install -m 0644 "$file" "$tmp/$name"
  done
  verify_tree "install-lib" "$tmp"
  if [[ -e "$dst" ]]; then
    mv "$dst" "$old"
  fi
  mv "$tmp" "$dst"
  CLEANUP_TARGET=""
  rm -rf "$old"
}

# Content-identical installs keep the existing mtime; only changed sources are
# replaced (through a sibling temp file, so readers never see a partial file).
install_file() {
  local src="$1" dst="$2"
  local tmp="${dst}.tmp.$$"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst" && has_other_bits "$dst" 4; then
    return 0
  fi
  CLEANUP_TARGET="$tmp"
  install -m 0644 "$src" "$tmp"
  mv "$tmp" "$dst"
  CLEANUP_TARGET=""
}

# Both hosts treat every subdirectory of plugin/ and plugins/ as a plugin
# package, so the old in-scan library and the old v2 entry directory must go.
remove_legacy() {
  local stage="remove-legacy" path
  for path in "$ENTRY_DIR/plan-trigger-lib" "$CONFIG_DIR/plugins/plan-trigger"; do
    if [[ -e "$path" || -L "$path" ]]; then
      rm -rf "$path"
      log INFO "$stage" "removed legacy path $path"
    fi
  done
}

verify_sources() {
  local file
  [[ -f "$PROJECT_DIR/plugin/plan-trigger.ts" ]] || fail "verify-sources" "缺少 plugin/plan-trigger.ts"
  [[ -d "$PROJECT_DIR/plan-trigger-lib" ]] || fail "verify-sources" "缺少 plan-trigger-lib"
  command -v node >/dev/null 2>&1 || return 0
  for file in "$PROJECT_DIR"/plan-trigger-lib/*.mjs; do
    node --check "$file" >/dev/null 2>&1 || fail "verify-sources" "语法检查失败: $(basename "$file")"
  done
  log INFO "verify-sources" "syntax check"
}

verify_contents() {
  local stage="verify-contents" file name count=0
  cmp -s "$PROJECT_DIR/plugin/plan-trigger.ts" "$ENTRY_DIR/plan-trigger.ts" ||
    fail "$stage" "入口文件与仓库不一致：$ENTRY_DIR/plan-trigger.ts"
  while IFS= read -r file; do
    name="$(basename "$file")"
    cmp -s "$file" "$LIB_DIR/$name" || fail "$stage" "共享库文件与仓库不一致：plan-trigger-lib/$name"
    count=$((count + 1))
  done < <(find_installed "$PROJECT_DIR/plan-trigger-lib" -type f -name '*.mjs')
  [[ "$count" -gt 0 ]] || fail "$stage" "仓库内没有可安装的共享库文件"
  while IFS= read -r file; do
    name="$(basename "$file")"
    [[ -f "$PROJECT_DIR/plan-trigger-lib/$name" ]] || fail "$stage" "安装目录存在仓库外文件：plan-trigger-lib/$name"
  done < <(find_installed "$LIB_DIR" -maxdepth 1 -type f -name '*.mjs')
  log INFO "$stage" "已装文件与仓库一致（1 入口 + ${count} 库文件）"
}

main() {
  init_log
  [[ "$#" -eq 0 ]] || fail "args" "install.sh 不接受参数（配置由 OPENCODE_CONFIG_DIR 覆盖）"
  trap cleanup EXIT
  log INFO "start" "project=${PROJECT_DIR} opencode=${CONFIG_DIR}"

  verify_sources
  if ! mkdir -p "$ENTRY_DIR"; then
    fail "start" "无法写入 opencode 配置目录：$CONFIG_DIR"
  fi
  ensure_dir_traversable "$CONFIG_DIR"
  ensure_dir_traversable "$ENTRY_DIR"

  remove_legacy
  install_file "$PROJECT_DIR/plugin/plan-trigger.ts" "$ENTRY_DIR/plan-trigger.ts"
  replace_dir "$PROJECT_DIR/plan-trigger-lib" "$LIB_DIR"

  [[ -f "$ENTRY_DIR/plan-trigger.ts" ]] || fail "install" "插件入口安装失败"
  [[ -f "$LIB_DIR/index.mjs" ]] || fail "install" "共享库安装失败"

  verify_permissions
  verify_contents
  log INFO "done" "install complete"
  if [[ "$LOG_READY" -eq 1 ]]; then
    printf '✅ plan-trigger installed（日志 log/install.%s.log）\n' "$(date +%Y%m%d)"
  else
    printf '✅ plan-trigger installed（./log/ 不可写，日志已降级 stderr）\n'
  fi
}

main "$@"