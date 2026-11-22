#!/bin/bash

# link_test.sh
# 不带版本号软链接的回归测试：
#   装完自动链接 → 不带版本号能跑 → link / unlink / linkquery → link -a / unlink -a
#   → 卸载最高版自动降级 → uninstall --no-link 不降级 → install --no-link 不建链接
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

# 造一个“已装好”的整树包：bin/<名>@<版本>/bin/<名> + .is_a_tree 标记。
# 链接目标要比单文件包多一层 bin/，linker 靠标记区分这两种形态。
install_fake_tree() {
    local version="$1"
    mkdir -p "$BIN_DIR/$PKG@$version/bin" "$BIN_DIR/$PKG@$version/share/templates"
    printf '#!/bin/sh\necho "Tree Successful!"\n' > "$BIN_DIR/$PKG@$version/bin/$PKG"
    chmod +x "$BIN_DIR/$PKG@$version/bin/$PKG"
    # 整树包里除了主命令还会有别的命令（dtc 的 fdtget、testdisk 的 photorec…）
    printf '#!/bin/sh\necho "Tree Extra!"\n' > "$BIN_DIR/$PKG@$version/bin/$PKG-extra"
    chmod +x "$BIN_DIR/$PKG@$version/bin/$PKG-extra"
    : > "$BIN_DIR/$PKG@$version/.is_a_tree"
    ln -sfn "../bin/$PKG@$version/bin/$PKG" "$LINKS_DIR/$PKG@$version"
}

cleanup() {
    rm -rf "$BIN_DIR/$PKG@$VER" "$BIN_DIR/$PKG@2.0"
    rm -f "$LINKS_DIR/$PKG@$VER" "$LINKS_DIR/$PKG@2.0" "$UNV" "$LINKS_DIR/$PKG-extra"
}

trap cleanup EXIT
cleanup

echo ""
echo "========== 1. 建不带版本号的链接 =========="
install_fake "$VER"
VERSIONED_LINK="$LINKS_DIR/$PKG@$VER"
python3 "$WAVE_BIN" link "$PKG" </dev/null >/dev/null
check "link 后 $UNV 存在" "$(link_state "$UNV")" "yes"
check "linkquery 报告 $PKG => $VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => $VER"
RUN_OUTPUT=$("$UNV")
check "不带版本号也能跑" "$([[ "$RUN_OUTPUT" == *"Test Successful! (no-extension)"* ]] && echo yes || echo no)" "yes"
check "带版本号的链接不受影响" "$(link_state "$VERSIONED_LINK")" "yes"

echo ""
echo "========== 2. unlink 与 link =========="
python3 "$WAVE_BIN" unlink "$PKG" >/dev/null
check "unlink 后链接消失" "$(link_state "$UNV")" "no"
python3 "$WAVE_BIN" link "$PKG" >/dev/null
check "link 后链接恢复" "$(link_state "$UNV")" "yes"
check "重复 link 不改指向" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => $VER"

echo ""
echo "========== 3. -a / --all =========="
VERSIONED_BEFORE=$(ls "$LINKS_DIR" | grep -c '@' || true)
python3 "$WAVE_BIN" unlink -a >/dev/null
check "unlink -a 清空无版本号链接" "$(unversioned_count)" "0"
check "unlink -a 不动带版本号的链接" "$(ls "$LINKS_DIR" | grep -c '@' || true)" "$VERSIONED_BEFORE"
python3 "$WAVE_BIN" link -a >/dev/null
check "link -a 后仍指向 $PKG => $VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => $VER"
check "link -a 不动带版本号的链接" "$(ls "$LINKS_DIR" | grep -c '@' || true)" "$VERSIONED_BEFORE"

# 造一个同包的更高版本（避免依赖 infosource 里真有 2.0）
make_v2() {
    install_fake 2.0
}

echo ""
echo "========== 4. 卸载最高版时自动降级 =========="
make_v2
python3 "$WAVE_BIN" link "$PKG@2.0" >/dev/null
check "已链到最高版 2.0" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => 2.0"
python3 "$WAVE_BIN" uninstall "$PKG@2.0" >/dev/null
check "卸载 2.0 后降到 $VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => $VER"

echo ""
echo "========== 5. uninstall --no-link 不会留下坏链接 =========="
make_v2
python3 "$WAVE_BIN" link "$PKG@2.0" >/dev/null

# 5.1 要删的正是链接指向的版本 → 必须报错拒绝，且什么都不删
set +e
python3 "$WAVE_BIN" uninstall "$PKG@2.0" --no-link >/dev/null 2>&1
UNLINK_EXIT=$?
set -e
check "删链接指向的版本时拒绝执行" "$UNLINK_EXIT" "1"
check "被拒绝后版本仍在" "$([[ -d "$BIN_DIR/$PKG@2.0" ]] && echo yes || echo no)" "yes"
check "被拒绝后链接未被破坏" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => 2.0"

# 5.2 要删的不是链接指向的版本 → 允许，链接继续指向 2.0
python3 "$WAVE_BIN" uninstall "$PKG@$VER" --no-link >/dev/null
check "--no-link 后仍指向 2.0" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => 2.0"

echo ""
echo "========== 6. 安装器接受 --no-link（离线）=========="
# 用带引号的 heredoc，不要用 `-c "…"`：Python 里的 ("--no-link", "--unlink")
# 会被 shell 当成「A"B"C"」，引号在传给 Python 之前就被吃掉了 —— 实际跑出来是
# (--no-link, --unlink)，Python 报 NameError，断言永远是空的。
# 这类写法会被 shellcheck 的 SC2140 抓住（CI 用 -S warning，直接算失败）。
FLAG_CHECK=$(cd "$BASE_DIR" && MACWAVE_COMPONENT_NAMES="$(components)" python3 - <<'PYCODE'
import os
import sys
sys.path[:0] = os.environ['MACWAVE_COMPONENT_NAMES'].split()
import pkginstaller as p
# 规范写法与新名字都认；旧名 --unlink 只是别名
ok = all(f in p.ALLOWED_FLAGS for f in ("--no-link", "--unlink"))
ok = ok and '--no-link' in p.parse_flags('wave install test_bin_zip@1.0 --no-link')
ok = ok and '--unlink' in p.parse_flags('wave install test_bin_zip@1.0 --unlink')
print('yes' if ok else 'no')
PYCODE
)
check "6.1 --no-link 是合法安装参数（旧名 --unlink 也认）" "$FLAG_CHECK" "yes"

# 「install 后自动建链接 / install --no-link 不建链接」需要真实下载，
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
check "8.1 链接先正常建立" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => $VER"
rm -rf "$BIN_DIR/$PKG@$VER"
set +e
DANGLE_OUT=$(python3 "$WAVE_BIN" linkquery "$PKG" 2>&1)
DANGLE_EXIT=$?
set -e
check "8.2 悬空链接退出码为 1" "$DANGLE_EXIT" "1"
check "8.3 报出指向的版本已不存在" "$([[ "$DANGLE_OUT" == *"is not installed"* ]] && echo yes || echo no)" "yes"
# 悬空的包目录已经删了，此时它不在「已装包名」里 —— 只按包名遍历的 -a 会漏掉它
set +e
ALL_DANGLE=$(python3 "$WAVE_BIN" linkquery -a 2>&1)
ALL_DANGLE_EXIT=$?
set -e
check "8.4 linkquery -a 也能发现悬空链接" \
    "$([[ "$ALL_DANGLE" == *"$PKG"*"is not installed"* ]] && echo yes || echo no)" "yes"
check "8.5 有悬空链接时 -a 退出码为 1" "$ALL_DANGLE_EXIT" "1"
python3 "$WAVE_BIN" unlink "$PKG" >/dev/null
check "8.6 unlink 可以清掉悬空链接" "$(link_state "$UNV")" "no"

echo ""
echo "========== 9. 整树软件包（.is_a_tree） =========="
install_fake_tree "$VER"
python3 "$WAVE_BIN" link "$PKG" >/dev/null
check "9.1 linkquery 报告 $PKG => $VER" "$(python3 "$WAVE_BIN" linkquery "$PKG")" "🌊 $PKG => $VER"
check "9.2 链接指向 bin/ 下那一个可执行文件" \
    "$(readlink "$UNV")" "../bin/$PKG@$VER/bin/$PKG"
RUN_OUTPUT=$("$UNV")
check "9.3 不带版本号也能跑" "$([[ "$RUN_OUTPUT" == *"Tree Successful!"* ]] && echo yes || echo no)" "yes"
check "9.4 安装目录仍是 bin/<名>@<版本>" "$([[ -d "$BIN_DIR/$PKG@$VER" ]] && echo yes || echo no)" "yes"
EXTRA_UNV="$LINKS_DIR/$PKG-extra"
check "9.5 其余命令也建了不带版本号的链接" "$(link_state "$EXTRA_UNV")" "yes"
check "9.6 其余命令的链接指向同一个包的 bin/" \
    "$(readlink "$EXTRA_UNV")" "../bin/$PKG@$VER/bin/$PKG-extra"
check "9.7 其余命令能跑" "$("$EXTRA_UNV")" "Tree Extra!"
# 这一步是回退过的东西：附属命令不是包，拿它的名字去 bin/ 里找 {名}@{版} 永远找不到，
# 于是 -a 在每台装了整树包的机器上都吐一片「is not linked」并以 1 退出。
check "9.8 附属命令按包名回答" \
    "$(python3 "$WAVE_BIN" linkquery "$PKG-extra")" "🌊 $PKG-extra => $PKG@$VER"
set +e
TREE_ALL=$(python3 "$WAVE_BIN" linkquery -a 2>&1)
TREE_ALL_EXIT=$?
set -e
check "9.9 linkquery -a 不误报整树包的附属命令" \
    "$([[ "$TREE_ALL" == *"(not linked)"* ]] && echo yes || echo no)" "no"
# 包多时 -a 会排两列，名字与版本之间补多少空格取决于最长的名字 —— 所以分两段
# 找：某一行同时有这个名字和这个版本，不去数中间的空格。
check "9.10 linkquery -a 里有 ${PKG} => ${VER}" \
    "$(printf '%s\n' "$TREE_ALL" | grep -F "${PKG}" | grep -qF "=> ${VER}" && echo yes || echo no)" "yes"
check "9.11 全部正常时 -a 退出码为 0" "$TREE_ALL_EXIT" "0"
python3 "$WAVE_BIN" unlink "$PKG" >/dev/null
check "9.12 unlink 后主命令链接消失" "$(link_state "$UNV")" "no"
check "9.13 unlink 后其余命令的链接也消失" "$(link_state "$EXTRA_UNV")" "no"
# 卸载同样要摘掉它们。只删「链接名 == 包名」那一条会留下死链：命令变成 command not
# found，`linkquery -a` 还会把它报成孤儿（random_test 就是这么发现的）。
install_fake_tree "$VER"
python3 "$WAVE_BIN" link "$PKG" >/dev/null
check "9.14 重新装上附属命令的链接还在" "$(link_state "$EXTRA_UNV")" "yes"
python3 "$WAVE_BIN" uninstall "$PKG@$VER" >/dev/null 2>&1 || true
check "9.15 卸载后附属命令的链接一起消失" "$(link_state "$EXTRA_UNV")" "no"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
