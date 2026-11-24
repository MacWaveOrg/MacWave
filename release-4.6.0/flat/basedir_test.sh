#!/bin/bash

# basedir_test.sh
# `wave basedir` 的三条不变量：
#
#   1. 默认输出带 🌊，家目录里的路径折成 ~（人看的那份要短）；
#   2. `--raw` 输出**原样**的绝对路径 —— 不折 ~，因为 `~` 只在词首、
#      未加引号时才展开，`cd "$(wave basedir --raw)"` 会把它当字面量；
#   3. 家目录之外（系统级安装）不折，包括 /Users/you2 这种「前缀相似但不是」的。
#
# 另外钉住两条拒绝：未知旗标指向 --help；`-s/--silent` 不许用在 basedir 上
# （这条命令存在的意义就是输出，静默它等于把命令废掉）。
#
# 自带隔离：MACWAVE_TEST 临时根，两个沙箱各用自己的测试根，互不看见。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

# shellcheck source=./components.sh
source "$SCRIPT_DIR/components.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# configpaths 把 MACWAVE_TEST 当 /，并把真实 HOME 搬成 <root><真实HOME>。
# 这里照同一条规则算出测试里的家目录，再把 base_dir 写在它下面。
REAL_HOME="$HOME"
user_root() {
    mkdir -p "$WORK/$1"
    printf '%s' "$WORK/$1$REAL_HOME"
}

run_wave() {
    local root="$1"; shift
    MACWAVE_TEST="$root" "$PYTHON" "$REPO_DIR/lib/wave.py" "$@"
}

echo "========== 1. 家目录里的安装：默认折成 ~ =========="

ROOT1="$WORK/root1"
HOME1="$(user_root root1)"
mkdir -p "$ROOT1/opt" "$HOME1/.config/macwave_config" "$HOME1/.local/macwave"
copy_components "$HOME1/.local/macwave/"
printf '{"base_dir": "%s"}\n' "$HOME1/.local/macwave" \
    > "$HOME1/.config/macwave_config/config.json"

DEFAULT_OUT="$(run_wave "$ROOT1" basedir 2>&1)"
RAW_OUT="$(run_wave "$ROOT1" basedir --raw 2>&1)"

if [[ "$DEFAULT_OUT" == "🌊 ~/.local/macwave" ]]; then
    pass "默认输出把家目录折成了 ~（${DEFAULT_OUT}）"
else
    fail "默认输出不对：$DEFAULT_OUT"
fi

if [[ "$RAW_OUT" == "$HOME1/.local/macwave" ]]; then
    pass "--raw 输出原样的绝对路径"
else
    fail "--raw 输出不对：$RAW_OUT"
fi

if [[ "$RAW_OUT" == *"🌊"* ]]; then
    fail "--raw 的输出里还有 🌊"
else
    pass "--raw 不带 🌊"
fi

if [[ "$RAW_OUT" == *$'\033'* ]]; then
    fail "--raw 的输出里有转义码"
else
    pass "--raw 不带颜色码"
fi

# --raw 的用途就是喂给 shell：它必须能直接 cd 进去，那个 ~ 不能是字面量
if [[ -d "$RAW_OUT" ]] && ( cd "$RAW_OUT" ); then
    pass "--raw 的路径可以直接 cd（不是字面量 ~）"
else
    fail "--raw 的路径 cd 不进去：$RAW_OUT"
fi

echo
echo "========== 2. 前缀相似但不在家目录里：不折 =========="

SIBLING="${HOME1}2/.local/macwave"
mkdir -p "$SIBLING"
copy_components "$SIBLING/"
printf '{"base_dir": "%s"}\n' "$SIBLING" > "$HOME1/.config/macwave_config/config.json"

SIBLING_OUT="$(run_wave "$ROOT1" basedir 2>&1)"
if [[ "$SIBLING_OUT" == "🌊 $SIBLING" ]]; then
    pass "只折「整段」前缀，/…2 这种相似名不折"
else
    fail "前缀相似的路径被误折了：$SIBLING_OUT"
fi

# 后面还要跑分发，base_dir 得指回一棵带组件的树，否则 wave 起不来，
# 「参数被拒绝」会被 import 失败冒充成同一条 exit 1。
printf '{"base_dir": "%s"}\n' "$HOME1/.local/macwave" \
    > "$HOME1/.config/macwave_config/config.json"

echo
echo "========== 3. 系统级安装：家目录外照旧打全路径 =========="

ROOT2="$WORK/root2"
mkdir -p "$ROOT2/opt/macwave_config" "$ROOT2/opt/macwave"
copy_components "$ROOT2/opt/macwave/"
printf '{"base_dir": "%s"}\n' "$ROOT2/opt/macwave" > "$ROOT2/opt/macwave_config/config.json"

SYSTEM_OUT="$(run_wave "$ROOT2" basedir 2>&1)"
SYSTEM_RAW="$(run_wave "$ROOT2" basedir --raw 2>&1)"

if [[ "$SYSTEM_OUT" == "🌊 $ROOT2/opt/macwave" && "$SYSTEM_RAW" == "$ROOT2/opt/macwave" ]]; then
    pass "系统级安装两种形态都打全路径"
else
    fail "系统级输出不对：$SYSTEM_OUT / $SYSTEM_RAW"
fi

echo
echo "========== 4. 该拒绝的两处 =========="

BAD="$(run_wave "$ROOT1" basedir --bogus 2>&1)"; BAD_RC=$?
if [[ $BAD_RC -eq 1 && "$BAD" == *"--help"* ]]; then
    pass "未知旗标报错并指向 --help"
else
    fail "未知旗标的处理不对（exit ${BAD_RC}）：$BAD"
fi

SILENT="$(run_wave "$ROOT1" basedir -s 2>&1)"; SILENT_RC=$?
if [[ $SILENT_RC -eq 1 && "$SILENT" != *"$HOME1"* ]]; then
    pass "-s 被拒绝，且没有把路径打出来"
else
    fail "-s 的处理不对（exit ${SILENT_RC}）：$SILENT"
fi

echo
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [[ $FAILED -eq 0 ]]; then
    echo "🌊 All basedir checks passed"
    exit 0
else
    echo "🌊 basedir checks failed"
    exit 1
fi
