#!/bin/bash

# link_test.sh
# 不带版本号软链接的回归测试：
#   装完自动链接 → 不带版本号能跑 → link / unlink / linkquery → link -a / unlink -a
#   → 卸载最高版自动降级 → uninstall --unlink 不降级 → install --unlink 不建链接
#   → 卸掉最后一个版本时删掉链接

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"
WAVE_BIN="$REPO_DIR/lib/wave.py"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# 配置目录：系统级优先，其次用户级
if [[ -f /opt/macwave_config/config.json ]]; then
    CONFIG_FILE="/opt/macwave_config/config.json"
elif [[ -f "$HOME/.config/macwave_config/config.json" ]]; then
    CONFIG_FILE="$HOME/.config/macwave_config/config.json"
else
    echo -e "${RED_BOLD}🌊 Error: MacWave not installed (config not found).${RESET}"
    exit 1
fi

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")
BIN_DIR="$BASE_DIR/bin"
LINKS_DIR="$BASE_DIR/links"

PKG="test_bin_no_ext"
VER="1.0"
UNV="$LINKS_DIR/$PKG"

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

# check <描述> <实际> <期望>
check() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

link_state() {
    if [[ -L "$1" ]]; then echo yes; else echo no; fi
}

unversioned_count() {
    ls "$LINKS_DIR" 2>/dev/null | grep -v '@' | wc -l | tr -d ' '
}

# 造一个“已装好”的包：bin/<名>@<版本>/<名> + 带版本号的软链接。全程离线。
install_fake() {
    local version="$1"
    mkdir -p "$BIN_DIR/$PKG@$version"
    printf '#!/bin/sh\necho "Test Successful! (no-extension)"\n' > "$BIN_DIR/$PKG@$version/$PKG"
    chmod +x "$BIN_DIR/$PKG@$version/$PKG"
    ln -sfn "../bin/$PKG@$version/$PKG" "$LINKS_DIR/$PKG@$version"
}

cleanup() {
    rm -rf "$BIN_DIR/$PKG@$VER" "$BIN_DIR/$PKG@2.0"
    rm -f "$LINKS_DIR/$PKG@$VER" "$LINKS_DIR/$PKG@2.0" "$UNV"
}

trap cleanup EXIT
cleanup

echo ""
echo "========== 1. 建不带版本号的链接 =========="
install_fake "$VER"
VERSIONED_LINK="$LINKS_DIR/$PKG@$VER"
python3 "$WAVE_BIN" link "$PKG" </dev/null >/dev/null
check "link 后 $UNV 存在" "$(link_state "$UNV")" "yes"
check "linkquery 报告 $PKG@$VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"
RUN_OUTPUT=$("$UNV")
check "不带版本号也能跑" "$([[ "$RUN_OUTPUT" == *"Test Successful! (no-extension)"* ]] && echo yes || echo no)" "yes"
check "带版本号的链接不受影响" "$(link_state "$VERSIONED_LINK")" "yes"

echo ""
echo "========== 2. unlink 与 link =========="
python3 "$WAVE_BIN" unlink "$PKG" >/dev/null
check "unlink 后链接消失" "$(link_state "$UNV")" "no"
python3 "$WAVE_BIN" link "$PKG" >/dev/null
check "link 后链接恢复" "$(link_state "$UNV")" "yes"
check "重复 link 不改指向" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"

echo ""
echo "========== 3. -a / --all =========="
VERSIONED_BEFORE=$(ls "$LINKS_DIR" | grep -c '@' || true)
python3 "$WAVE_BIN" unlink -a >/dev/null
check "unlink -a 清空无版本号链接" "$(unversioned_count)" "0"
check "unlink -a 不动带版本号的链接" "$(ls "$LINKS_DIR" | grep -c '@' || true)" "$VERSIONED_BEFORE"
python3 "$WAVE_BIN" link -a >/dev/null
check "link -a 后仍指向 $PKG@$VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"
check "link -a 不动带版本号的链接" "$(ls "$LINKS_DIR" | grep -c '@' || true)" "$VERSIONED_BEFORE"

# 造一个同包的更高版本（避免依赖 infosource 里真有 2.0）
make_v2() {
    install_fake 2.0
}

echo ""
echo "========== 4. 卸载最高版时自动降级 =========="
make_v2
python3 "$WAVE_BIN" link "$PKG@2.0" >/dev/null
check "已链到最高版 2.0" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@2.0"
python3 "$WAVE_BIN" uninstall "$PKG@2.0" >/dev/null
check "卸载 2.0 后降到 $VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"

echo ""
echo "========== 5. uninstall --unlink 不会留下坏链接 =========="
make_v2
python3 "$WAVE_BIN" link "$PKG@2.0" >/dev/null

# 5.1 要删的正是链接指向的版本 → 必须报错拒绝，且什么都不删
set +e
python3 "$WAVE_BIN" uninstall "$PKG@2.0" --unlink >/dev/null 2>&1
UNLINK_EXIT=$?
set -e
check "删链接指向的版本时拒绝执行" "$UNLINK_EXIT" "1"
check "被拒绝后版本仍在" "$([[ -d "$BIN_DIR/$PKG@2.0" ]] && echo yes || echo no)" "yes"
check "被拒绝后链接未被破坏" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@2.0"

# 5.2 要删的不是链接指向的版本 → 允许，链接继续指向 2.0
python3 "$WAVE_BIN" uninstall "$PKG@$VER" --unlink >/dev/null
check "--unlink 后仍指向 2.0" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@2.0"

echo ""
echo "========== 6. 安装器接受 --unlink（离线）=========="
FLAG_CHECK=$(cd "$BASE_DIR" && MACWAVE_COMPONENT_NAMES="$(components)" python3 -c "
import os
import sys
sys.path[:0] = os.environ['MACWAVE_COMPONENT_NAMES'].split()
import pkginstaller as p
ok = '--unlink' in p.ALLOWED_FLAGS and '--unlink' in p.parse_flags('wave install test_bin_zip@1.0 --unlink')
print('yes' if ok else 'no')
")
check "6.1 --unlink 是合法安装参数" "$FLAG_CHECK" "yes"

# 「install 后自动建链接 / install --unlink 不建链接」需要真实下载，
# 这两条断言放在同样跑真实安装的 scripts/format_test.sh 里。

# 重建一个“装好”的 2.0，供第 7 步验证
make_v2
python3 "$WAVE_BIN" link "$PKG@2.0" </dev/null >/dev/null

echo ""
echo "========== 7. 卸掉最后一个版本时删掉链接 =========="
python3 "$WAVE_BIN" uninstall "$PKG@2.0" >/dev/null
check "已无版本可指向，链接被删除" "$(link_state "$UNV")" "no"

set +e
python3 "$WAVE_BIN" linkquery "$PKG" >/dev/null 2>&1
QUERY_EXIT=$?
set -e
check "linkquery 未链接时退出码为 1" "$QUERY_EXIT" "1"

echo ""
echo "========== 8. 悬空链接会被发现 =========="
# 不联网：用假目录造一个“已装版本”并链上，再把目录删掉，链接就悬空了
mkdir -p "$BIN_DIR/$PKG@$VER"
ln -sfn "../bin/$PKG@$VER/$PKG" "$LINKS_DIR/$PKG@$VER"
python3 "$WAVE_BIN" link "$PKG" >/dev/null
check "8.1 链接先正常建立" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG@$VER"
rm -rf "$BIN_DIR/$PKG@$VER"
set +e
DANGLE_OUT=$(python3 "$WAVE_BIN" linkquery "$PKG" 2>&1)
DANGLE_EXIT=$?
set -e
check "8.2 悬空链接退出码为 1" "$DANGLE_EXIT" "1"
check "8.3 报出指向的版本已不存在" "$([[ "$DANGLE_OUT" == *"is not installed"* ]] && echo yes || echo no)" "yes"
python3 "$WAVE_BIN" unlink "$PKG" >/dev/null
check "8.4 unlink 可以清掉悬空链接" "$(link_state "$UNV")" "no"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
