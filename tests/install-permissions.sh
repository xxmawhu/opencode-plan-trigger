#!/usr/bin/env bash
# Verifies install.sh for the umask-independent permission contract (issue
# f56c98eb), the unwritable-log fallback (issue fafad37f) and the idempotent /
# legacy-cleanup rules of contract v1 (R6).
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$PROJECT_DIR/tests/.tmp-install-permissions.$$"
FAILED=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  printf '❌ %s\n' "$1"
  FAILED=1
}

assert_mode() {
  local path="$1" want="$2" actual
  actual="$(stat -c '%a' "$path")"
  [[ "$actual" = "$want" ]] || fail "$path 权限 $actual != $want"
}

assert_absent() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then fail "遗留路径未清理: $path"; fi
}

install_into() {
  local umask_value="$1" config="$2"
  mkdir -p "$config"
  ( umask "$umask_value"; OPENCODE_CONFIG_DIR="$config" "$PROJECT_DIR/install.sh" >/dev/null )
}

check_tree() {
  local config="$1" lib file
  lib="$config/plan-trigger-lib"
  assert_mode "$config/plugin" 755
  assert_mode "$lib" 755
  assert_mode "$config/plugin/plan-trigger.ts" 644
  while IFS= read -r file; do
    assert_mode "$file" 644
  done < <(fdfind --hidden --no-ignore --type f . "$lib")
  assert_absent "$config/plugin/plan-trigger-lib"
  assert_absent "$config/plugins/plan-trigger"
  [[ -z "$(fdfind --hidden --no-ignore --type d --max-depth 2 . "$config/plugin" 2>/dev/null)" ]] \
    || fail "扫描目录出现子目录（契约 R1）"
  node -e 'import(process.argv[1]).then(() => process.exit(0), (error) => { console.error(error); process.exit(1); })' \
    "file://$lib/index.mjs" || fail "库无法从安装路径 import"
}

for umask_value in 077 022; do
  config="$WORK/umask-$umask_value/.config/opencode"
  install_into "$umask_value" "$config"
  check_tree "$config"
  printf 'PASS: umask %s 安装权限\n' "$umask_value"
done

# Legacy paths from the pre-contract layout must disappear on upgrade. Fixture
# dirs are created mode-explicit so the assertion does not depend on the
# ambient umask of whoever runs the test.
config="$WORK/legacy/.config/opencode"
mkdir -p "$config"
install -d -m 0755 "$config/plugin" "$config/plugin/plan-trigger-lib" "$config/plugins/plan-trigger"
printf 'stale\n' >"$config/plugin/plan-trigger-lib/index.mjs"
printf 'stale\n' >"$config/plugins/plan-trigger/index.ts"
install_into 077 "$config"
check_tree "$config"
printf 'PASS: 遗留路径清理\n'

# Re-running an unchanged install must not rewrite files (mtimes stay put).
config="$WORK/idempotent/.config/opencode"
install_into 022 "$config"
before="$(stat -c '%n:%Y:%s' "$config/plugin/plan-trigger.ts" "$config/plan-trigger-lib/"*.mjs)"
sleep 1
install_into 022 "$config"
after="$(stat -c '%n:%Y:%s' "$config/plugin/plan-trigger.ts" "$config/plan-trigger-lib/"*.mjs)"
[[ "$before" = "$after" ]] || fail "重复安装改写了未变化的文件"
printf 'PASS: 重复安装幂等\n'

# A ./log/ that exists but is not writable (foreign-owned checkout, read-only
# install copy) must degrade to stderr and still install (issue fafad37f).
copy="$WORK/readonly-log/repo"
config="$WORK/readonly-log/.config/opencode"
mkdir -p "$copy" "$config"
cp -a "$PROJECT_DIR/install.sh" "$PROJECT_DIR/plugin" "$PROJECT_DIR/plan-trigger-lib" "$copy/"
mkdir -p "$copy/log"
chmod 500 "$copy/log"
if ( umask 022; OPENCODE_CONFIG_DIR="$config" "$copy/install.sh" >/dev/null 2>&1 ); then
  check_tree "$config"
  printf 'PASS: 只读 ./log/ 降级 stderr 后安装成功\n'
else
  fail "只读 ./log/ 导致安装失败"
fi
chmod 700 "$copy/log"

if [[ "$FAILED" -ne 0 ]]; then
  printf '\n安装权限测试失败\n'
  exit 1
fi
printf '\n安装权限测试全部通过\n'