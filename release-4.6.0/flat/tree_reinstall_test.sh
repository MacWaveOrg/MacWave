#!/bin/bash

# tree_reinstall_test.sh
# 整树包在「目标目录里已经有东西」时还能不能装上去。
#
# 必现场景：一次安装被中途打断（断网、Ctrl+C），bin/<名>@<版本>/ 里留下半棵树；
# 用户再装一次。以前 mw_install_tree 直接 `mv source/* target/`，碰上已存在的
# 非空目录会报 `Directory not empty`，那个包从此再也装不上，只能人工删目录。
#
# 直接测 surfboard/depsmanager.sh 里的真函数：把函数体抽出来 source 进临时脚本，
# 不跑整个安装器（那需要索引、产物与网络）。抽不到函数体就判红 —— 否则文件一改
# 名，这个测试会「通过」得毫无意义。
#
# 全程离线。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DEPSMANAGER="$REPO_DIR/surfboard/depsmanager.sh"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "========== 0. 抽出 mw_install_tree 与 mw_assert_inside =========="
{
    echo '#!/bin/bash'
    sed -n '/^mw_assert_inside()/,/^}/p' "$DEPSMANAGER"
    sed -n '/^mw_install_tree()/,/^}/p' "$DEPSMANAGER"
} > "$WORK/funcs.sh"

# BASE_DIR 由环境传进去：函数体里的 mw_assert_inside 读的是 ${MW_BASE_DIR}，
# 而 source 出来的函数拿不到本脚本的局部变量。
export MW_BASE_DIR="$WORK/base"

for name in mw_assert_inside mw_install_tree; do
    if grep -q "^$name()" "$WORK/funcs.sh"; then
        pass "抽到了 $name"
    else
        fail "没抽到 $name —— depsmanager.sh 的函数形状变了，这个测试需要跟着改"
    fi
done

BASE="$WORK/base"
mkdir -p "$BASE/bin"

install_tree() {
    local source="$1" target="$2" bin_name="$3"
    ( export MW_BASE_DIR="$BASE"; source "$WORK/funcs.sh"; mw_install_tree "$source" "$target" "$bin_name" )
}

make_source() {
    local dir="$1"
    mkdir -p "$dir/bin" "$dir/share/git-core"
    printf '#!/bin/sh\necho tree\n' > "$dir/bin/tool"
    printf 'template\n' > "$dir/share/git-core/template"
}

echo
echo "========== 1. 目标不存在：照常装上 =========="
SRC="$WORK/src1"; TARGET="$BASE/bin/tool@1.0"
make_source "$SRC"
if install_tree "$SRC" "$TARGET" tool; then
    pass "全新安装成功"
else
    fail "全新安装就失败了"
fi
[ -f "$TARGET/bin/tool" ] && pass "bin/tool 就位" || fail "bin/tool 缺失"
[ -f "$TARGET/share/git-core/template" ] && pass "share/ 就位" || fail "share/ 缺失"

echo
echo "========== 2. 半装残留（同名非空目录）：这才是必现场景 =========="
mkdir -p "$TARGET/share/git-core" "$TARGET/libexec"
printf 'leftover\n' > "$TARGET/share/git-core/leftover"
SRC="$WORK/src2"; make_source "$SRC"
if OUT=$(install_tree "$SRC" "$TARGET" tool 2>&1); then
    pass "目标目录有残留时仍能装上"
else
    fail "重装失败：$(printf '%s' "$OUT" | tail -2)"
fi
[ -f "$TARGET/bin/tool" ] && pass "重装后 bin/tool 就位" || fail "重装后 bin/tool 缺失"
if [ -e "$TARGET/share/git-core/leftover" ]; then
    fail "上次的残留还留在树里"
else
    pass "上次的残留被清掉了"
fi
if [ -d "$TARGET/libexec" ]; then
    fail "上次的 libexec/ 还留在树里"
else
    pass "上次多出来的目录也没了"
fi

echo
echo "========== 3. 越界的目标目录仍然拒绝 =========="
SRC="$WORK/src3"; make_source "$SRC"
OUT=$(install_tree "$SRC" "$WORK/outside" tool 2>&1)
if printf '%s' "$OUT" | grep -q 'Refusing to write outside'; then
    pass "base_dir 之外仍然拒绝"
else
    fail "base_dir 之外的写入没有被拦住：$(printf '%s' "$OUT" | tail -2)"
fi

echo
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [ "$FAILED" -eq 0 ]; then
    echo "🌊 All tree-reinstall checks passed"
    exit 0
else
    echo "🌊 tree-reinstall checks failed"
    exit 1
fi
