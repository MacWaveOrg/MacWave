#!/bin/bash

# shellenv_test.sh
# `wave shellenv` 的两条不变量：
#
#   1. **启动器与 Python 的输出必须逐字一致。** 这条路径是刻意写成两份的：
#      `lib/wave` 启动器在 shell 层直接回答（2ms），`lib/shellenv.py` 是给
#      `python3 lib/wave.py shellenv` 走的（160ms，不能放进 ~/.zprofile）。
#      两份实现各自的理由都成立，唯一不能接受的是它们**慢慢走偏** —— 用户从
#      启动器拿到的和从 Python 拿到的必须是同一段 shell 代码。
#   2. eval 之后 `wave` 真的能用，且重复 eval 不会把 PATH 堆叠起来。
#
# 另外断言安装器不再替用户改 shell 配置（4.3 起只打印、不动手）。
#
# 全程离线，不装包、不发请求。

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

TEST_ROOT="$WORK/root"
HOME_DIR="$WORK/home"
BASE="$WORK/base"

export MACWAVE_TEST="$TEST_ROOT"
mkdir -p "$TEST_ROOT/opt/macwave_config" "$HOME_DIR/.config/macwave_config" "$BASE"
copy_components "$BASE/"
printf '{"version": "4.3.0"}\n' > "$BASE/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$TEST_ROOT/opt/macwave_config/config.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_DIR/.config/macwave_config/config.json"

# ==========================================
# 从 install.sh 抽出启动器正文，渲染成一个真的启动器
# ==========================================
# 不 hand-write 一份「像启动器的东西」：那样测的是这份测试自己。
LAUNCHER_SRC="$REPO_DIR/lib/install.sh"
sed -n "/cat > \"\$tmp\" <<'LAUNCHER'/,/^LAUNCHER$/p" "$LAUNCHER_SRC" \
    | sed '1d;$d' > "$WORK/launcher.tpl"

if ! grep -q 'shellenv' "$WORK/launcher.tpl"; then
    echo -e "${RED_BOLD}🌊 Error: 没能从 install.sh 抽出含 shellenv 的启动器${RESET}"
    exit 1
fi

sed 's|#__MACWAVE_PYTHON__|MACWAVE_PYTHON=""|' "$WORK/launcher.tpl" > "$BASE/lib/wave"
chmod 755 "$BASE/lib/wave"

echo "========== 1. 启动器与 Python 逐字一致 =========="

FROM_LAUNCHER="$("$BASE/lib/wave" shellenv 2>&1)"
FROM_PYTHON="$(cd "$REPO_DIR" && MACWAVE_TEST="$TEST_ROOT" \
    MACWAVE_COMPONENT_PATHS="$(component_paths)" \
    BASE_LIB="$BASE/lib" "$PYTHON" - <<'PYEOF'
import os
import sys
sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep)
from shellenv import render
from configpaths import load_base_dir
sys.stdout.write(render(load_base_dir()))
PYEOF
)"

if [[ -z "$FROM_LAUNCHER" ]]; then
    fail "启动器什么都没输出"
elif [[ "$FROM_LAUNCHER" == "$FROM_PYTHON" ]]; then
    pass "两份输出逐字相同"
else
    fail "启动器与 Python 的输出不一致"
    diff <(printf '%s' "$FROM_LAUNCHER") <(printf '%s' "$FROM_PYTHON") | sed 's/^/    /'
fi

echo
echo "========== 2. 输出只有 shell 语句 =========="

if [[ "$FROM_LAUNCHER" == *"🌊"* ]]; then
    fail "输出里混进了 🌊 —— 它会被 eval 执行"
else
    pass "没有 🌊 之类的装饰"
fi

if [[ "$FROM_LAUNCHER" == *"$BASE/bin"* && "$FROM_LAUNCHER" == *"$BASE/links"* && "$FROM_LAUNCHER" == *"$BASE/lib"* ]]; then
    pass "三个目录都在（bin / links / lib）"
else
    fail "缺少目录：$FROM_LAUNCHER"
fi

echo
echo "========== 3. eval 之后 wave 能用，且可重复 eval =========="

# 用一个干净的 sh，把 lib 从 PATH 里拿掉，只靠 eval 加回来
PROBE=$(PATH=/usr/bin:/bin "$BASE/lib/wave" shellenv)
RESOLVED=$(PATH=/usr/bin:/bin sh -c "eval \"\$1\"; command -v wave || true" _ "$PROBE")
if [[ "$RESOLVED" == "$BASE/lib/wave" ]]; then
    pass "eval 之后 command -v wave 指向启动器"
else
    fail "eval 之后找不到 wave（得到：${RESOLVED:-空}）"
fi

ONCE=$(PATH=/usr/bin:/bin sh -c "eval \"\$1\"; printf '%s' \"\$PATH\"" _ "$PROBE")
TWICE=$(PATH=/usr/bin:/bin sh -c "eval \"\$1\"; eval \"\$1\"; printf '%s' \"\$PATH\"" _ "$PROBE")
if [[ "$ONCE" == "$TWICE" ]]; then
    pass "eval 两次路径不叠加"
else
    fail "重复 eval 会叠加 PATH"
    echo "    一次: $ONCE"
    echo "    两次: $TWICE"
fi

# 已经在了就不动：这保证「.zprofile 与 .zshrc 都写了这一行」不会出乱子
ALREADY=$(sh -c "PATH=\"\$1:\$PATH\"; eval \"\$2\"; printf '%s' \"\$PATH\"" _ "$BASE/lib" "$PROBE")
if [[ "$ALREADY" == "$BASE/lib:"* ]]; then
    pass "已存在时保持原样，不重复插入"
else
    fail "已存在时仍然改写了 PATH：$ALREADY"
fi

echo
echo "========== 4. 安装器不再替用户改 shell 配置 =========="

# 4.3 起 install.sh 只打印两条命令，不往任何 rc 文件里写。
if grep -qE '>>[[:space:]]*"\$RC_FILE"|>>[[:space:]]*"\$HOME/\.' "$LAUNCHER_SRC"; then
    fail "install.sh 仍在往用户的 rc 文件里追加内容"
else
    pass "install.sh 没有写用户的 rc 文件"
fi

# 结尾那一行由 SHELLENV_DISPLAY 拼出（家目录写成 ~），所以认变量名与 shellenv
# 调用两处，不再依赖某一种引号写法。
if grep -q 'SHELLENV_DISPLAY=' "$LAUNCHER_SRC" && grep -q 'wave shellenv)' "$LAUNCHER_SRC"; then
    pass "安装结束时打印 eval 那一行"
else
    fail "安装结束没有提示 eval 那一行"
fi

if grep -q '"/.bashrc"' "$LAUNCHER_SRC" && ! grep -q '\.bash_profile' "$LAUNCHER_SRC"; then
    fail "bash 用户仍被指向 ~/.bashrc（macOS 的登录 shell 从不读它）"
else
    pass "bash 用户指向 ~/.bash_profile"
fi

echo
echo "========== 5. 路径含引号/美元符时拒绝输出 =========="

# 宁可报错，也不要输出一段会把用户 PATH 改坏的 shell 代码
UNSAFE=$("$PYTHON" - <<PYEOF 2>&1
import sys
sys.path.insert(0, "$REPO_DIR/lib")
from pathlib import Path
from shellenv import render
try:
    render(Path('/tmp/we"ird'))
    print("NO-ERROR")
except ValueError:
    print("REJECTED")
PYEOF
)
if [[ "$UNSAFE" == "REJECTED" ]]; then
    pass "含双引号的安装路径被拒绝"
else
    fail "含双引号的安装路径没有被拒绝（${UNSAFE}）"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All shellenv checks passed${RESET}"
