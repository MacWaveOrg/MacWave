#!/bin/bash

# linksafety_test.sh
# 产物里的符号链接：越界的必须拒绝，落在系统库位置的必须放行。
#
# 为什么需要它：归档只过滤成员**名字**里的 `../`，与链接**目标**无关。实测
# Python 3.15 的 tarfile，filter='tar' 会把 `x -> /etc/hosts` 原样解出来，
# 只有 filter='data' 才拒绝（但它连 conda 包需要的合法链接一起拒）；unzip 与
# tar 命令行同样不管目标。也就是说这条防线只能自己建。
#
# 危害两头：链接指向隐私文件 → 随包附带的程序读到不该读的东西；链接指向
# MacWave 之后要写的路径（transfer.sh 的重定位改写、.part → mv、卸载的 rm -rf）
# → 以用户身份在树外写或删。规则与理由见 SECURITY.md 与 TECHNICAL-GUIDE 7.5.1。
#
# 第三段是唯一会跑真实安装流程的部分：把一份带越界链接的产物丢进
# downloads/tmp，让 mw_install_artifact 走一遍（校验 → 解压 → 检查），要求它
# 拒绝、并且**不留下**半成品目录 —— 「报错了但东西已经落地」比不检查更糟。
#
# 全程离线。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}
CHECKER="$REPO_DIR/lib/configpaths.py"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

# 跑一次检查，回显输出，退出码放在 RC 里
run_check() {  # run_check <目录> [描述]
    OUT=$("$PYTHON" "$CHECKER" --check-links "$1" "${2:-test}" 2>&1)
    RC=$?
}

expect_rc() {  # expect_rc 描述 期望退出码
    if [[ "$RC" -eq "$2" ]]; then
        pass "$1"
    else
        fail "$1（期望 rc=$2，实际 $RC）输出：$(printf '%.200s' "$OUT")"
    fi
}

expect_names() {  # expect_names 描述 应出现的名字...（在输出里出现过）
    local label="$1"; shift
    local missing=()
    for name in "$@"; do
        [[ "$OUT" == *"$name"* ]] || missing+=("$name")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "$label"
    else
        fail "$label（输出里没有：${missing[*]}）"
    fi
}

echo "========== 1. 判定函数：六种链接各归其位 =========="

TREE="$WORK/tree"
mkdir -p "$TREE/lib" "$TREE/sub" "$TREE/keep"
touch "$TREE/lib/local.dylib"

ln -s ./local.dylib "$TREE/lib/ok_relative"            # 相对且落在树内
ln -s "$TREE/lib/local.dylib" "$TREE/lib/ok_absolute"  # 绝对但落在树内
ln -s ./does-not-exist "$TREE/lib/ok_dangling"         # 悬空但在树内：无害
ln -s /usr/bin/php "$TREE/lib/ok_system"               # 豁免：/usr/bin
ln -s /usr/lib/libSystem.B.dylib "$TREE/lib/ok_usrlib" # 豁免：/usr/lib
ln -s /System/Library/Frameworks/AppKit.framework/AppKit "$TREE/lib/ok_framework"
ln -s /Library/Apple/usr/lib/libc++.1.dylib "$TREE/lib/ok_apple"

run_check "$TREE" "只含合法链接的树"
expect_rc "合法链接（含树内、悬空、系统位置）全部放行" 0
[[ -z "$OUT" ]] && pass "放行时不打印任何东西" || fail "放行时不该有输出：$(printf '%.120s' "$OUT")"

echo "--- 逐个加入越界链接 ---"

ln -s /etc/hosts "$TREE/lib/bad_absolute"
run_check "$TREE" "test"
expect_rc "绝对路径指向树外 → 拒绝" 1
expect_names "报错点名了越界的那一条" "bad_absolute" "/etc/hosts"

ln -s ../../../../etc/passwd "$TREE/lib/bad_relative"
run_check "$TREE" "test"
expect_rc "相对路径爬出树外 → 拒绝" 1
expect_names "相对爬出也被指出" "bad_relative"

ln -s /Users/someone/.ssh/id_rsa "$TREE/lib/bad_private"
run_check "$TREE" "test"
expect_rc "指向隐私文件 → 拒绝" 1

ln -s ../../etc "$TREE/sub/bad_directory"
run_check "$TREE" "test"
expect_rc "指向树外**目录**的链接同样拒绝" 1
expect_names "目录链接也被指出" "bad_directory"

ln -s ./nothing-here "$TREE/lib/bad_dangling_outside"
# 悬空但落在树内 → 不是越界；换一个词法上就在外面的悬空链接
rm -f "$TREE/lib/bad_dangling_outside"
ln -s /opt/macwave-nope/x "$TREE/lib/bad_dangling_outside"
run_check "$TREE" "test"
expect_rc "悬空但指向树外 → 拒绝（resolve 不要求目标存在）" 1

# 豁免位置里的子目录也要放行，别写成只匹配前缀字符串
mkdir -p "$WORK/fake_usr/bin"
ln -s "$WORK/fake_usr/bin/tool" "$TREE/lib/ok_nested"
run_check "$TREE" "test"
if [[ "$RC" -eq 1 ]] && [[ "$OUT" == *"ok_nested"* ]]; then
    pass "豁免按路径分段匹配：\$WORK/fake_usr 不算 /usr"
else
    fail "豁免判成了字符串前缀（fake_usr 被当成 /usr）"
fi
rm -f "$TREE/lib/ok_nested"

echo "========== 2. 输出里的路径足以定位问题 =========="

run_check "$TREE" "pkg@1.0"
expect_names "描述原样带进报错" "pkg@1.0"
expect_names "报错说明了后果" "private files"
expect_names "报错列了豁免清单" "/usr/bin"
expect_names "报错给了下一步" "Report it to the index maintainer"

echo "========== 3. 真实安装漏斗：拒绝且不留半成品 =========="

BASE="$WORK/base"
mkdir -p "$BASE"/{bin,links,deps,downloads/tmp}
for dir in lib net pkg surfboard; do
    mkdir -p "$BASE/$dir"
    cp -R "$REPO_DIR/$dir"/*.py "$REPO_DIR/$dir"/*.sh "$BASE/$dir"/ 2>/dev/null
done

mkdir -p "$WORK/craft/lib"
ln -s /Users/someone/.ssh/id_rsa "$WORK/craft/lib/evil"
ln -s ./ok.dylib "$WORK/craft/lib/fine"
touch "$WORK/craft/lib/ok.dylib"
tar --no-xattrs -czf "$BASE/downloads/tmp/evil-1.0.tar.gz" -C "$WORK/craft" . 2>/dev/null
SHA=$(shasum -a 256 "$BASE/downloads/tmp/evil-1.0.tar.gz" | awk '{print $1}')

OUT=$(cd "$BASE" && bash -c "
    source ./surfboard/depsmanager.sh
    mw_install_artifact \"evil
1.0
$SHA
$BASE/deps/evil/evil@1.0
$BASE
evil

evil-1.0.tar.gz\" '' 'tree'
" 2>&1)
RC=$?

if [[ "$RC" -ne 0 ]]; then
    pass "带越界链接的产物被拒绝（rc=$RC）"
else
    fail "带越界链接的产物居然装成功了"
fi
expect_names "拒绝理由出现在输出里" "evil@1.0"
# 安装过程要说一句「在干什么」：检查本身是静默的，不提示的话安装会从「解压成功」
# 直接跳到报错，看着像卡住。
expect_names "安装时有「正在进行安全检查」的提示行" "Running security checks"
if [[ "$OUT" == *"Extraction successful"*"Running security checks"*"Error:"* ]]; then
    pass "提示行排在「解压成功」之后、报错之前"
else
    fail "提示行的位置不对（应当在解压之后、报错之前）"
fi
if [[ -d "$BASE/deps/evil/evil@1.0" ]]; then
    fail "拒绝了却留下了安装目录（半成品）"
else
    pass "拒绝后没有留下安装目录"
fi
if [[ -n "$(ls -A "$BASE/downloads/tmp" | grep -v '^evil-1.0.tar.gz$')" ]]; then
    fail "解压临时目录没清干净：$(ls -A "$BASE/downloads/tmp" | tr '\n' ' ')"
else
    pass "解压临时目录已清理"
fi

echo "--- 合法产物必须照常安装（防误杀） ---"
mkdir -p "$WORK/craft2/lib"
ln -s ./ok.dylib "$WORK/craft2/lib/fine"
touch "$WORK/craft2/lib/ok.dylib"
ln -s /usr/lib/libSystem.B.dylib "$WORK/craft2/lib/system"
tar --no-xattrs -czf "$BASE/downloads/tmp/good-1.0.tar.gz" -C "$WORK/craft2" . 2>/dev/null
SHA2=$(shasum -a 256 "$BASE/downloads/tmp/good-1.0.tar.gz" | awk '{print $1}')

OUT=$(cd "$BASE" && bash -c "
    source ./surfboard/depsmanager.sh
    mw_install_artifact \"good
1.0
$SHA2
$BASE/deps/good/good@1.0
$BASE
good

good-1.0.tar.gz\" '' 'tree'
" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
    pass "合法产物（含系统位置链接）安装成功"
else
    fail "合法产物被误杀（rc=$RC）：$(printf '%.200s' "$OUT")"
fi
if [[ -L "$BASE/deps/good/good@1.0/lib/fine" && -L "$BASE/deps/good/good@1.0/lib/system" ]]; then
    pass "两条合法链接都落盘了"
else
    fail "合法链接没落盘"
fi

echo "========== 4. 检查点没被绕过 =========="
# 函数写在脚本里、但调用点被删掉，是最容易发生的回归：测试全绿而防护没了。
if grep -q 'mw_assert_no_escaping_links "\$tree_dir"' "$REPO_DIR/surfboard/depsmanager.sh" \
   && grep -q 'mw_assert_no_escaping_links "\$extract_dir"' "$REPO_DIR/surfboard/depsmanager.sh"; then
    pass "tree 与 binary 两种形态都调用了检查"
else
    fail "安装流程里少了调用点（tree 或 binary）"
fi

if grep -q 'assert_links_inside' "$REPO_DIR/lib/configpaths.py"; then
    pass "规则实现在 lib/configpaths.py"
else
    fail "找不到 assert_links_inside"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All link-safety tests passed${RESET}"
