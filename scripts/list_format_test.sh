#!/bin/bash

# list_format_test.sh
# `wave list` 的两竖列排版与 `--raw`。
#
# 钉住四件事：
#   1. 列优先（先上下、再左右），行数 = ceil(n/2) —— 与 `brew list` / `ls` 一致；
#   2. 每行只有一个 🌊，且第二列的起始位置在各行一致；
#   3. 行尾不留空格（整行复制不该带尾巴）；
#   4. `--raw` 一行一个、不带 🌊、不分列、空列表零输出。
#
# 全程离线：只往 MACWAVE_TEST 的 bin/ 里放空目录，不下载、不碰真实安装。

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

ROOT="$WORK/root"
BASE="$ROOT/opt/macwave"
mkdir -p "$BASE" "$ROOT/opt/macwave_config"
copy_components "$BASE/" >/dev/null
printf '{"version": "4.5.0"}\n' > "$ROOT/opt/macwave_config/VERSION.json"
printf '{"base_dir": "%s"}\n' "$BASE" > "$ROOT/opt/macwave_config/config.json"

export MACWAVE_TEST="$ROOT"

list_wave() { "$PYTHON" "$REPO_DIR/lib/wave.py" list "$@" 2>&1; }

# 装 16 个（偶数），名字长短不一，用来看对齐
PKGS=(
    jq@1.8.2 yq@4.45.1 fzf@0.65.0 git@2.56.1 aria2c@1.37.0 ripgrep@14.1.1
    ffmpeg@7.1.1 pandoc@3.13 neovim@0.11.4 tmux@3.5a wget@1.25.0 curl@8.17.0
    bash@5.2.37 openssl@3.6.0 python@3.13.9 cmatrix@2.0
)

install_fixture() {
    rm -rf "${BASE:?}/bin"
    mkdir -p "$BASE/bin"
    local spec
    for spec in "$@"; do
        mkdir -p "$BASE/bin/$spec"
    done
}

echo "========== 1. 16 个包 → 8 行，每行一个 🌊 =========="
install_fixture "${PKGS[@]}"
OUT=$(list_wave)
LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [ "$LINES" -eq 8 ]; then
    pass "16 个包排成 8 行"
else
    fail "16 个包应该是 8 行，实际 $LINES 行"
fi

BAD=$(printf '%s\n' "$OUT" | awk '{n = gsub(/🌊/, "&"); if (n != 1) print NR": "n" 个"}')
if [ -z "$BAD" ]; then
    pass "每行恰好一个 🌊"
else
    fail "有的行不是恰好一个 🌊：$BAD"
fi

# 列优先 + 对齐 + 行尾无空格，一次交给 python 判
PROBLEMS=$(LIST_OUT="$OUT" "$PYTHON" - "${PKGS[@]}" <<'PYCHECK'
import os, re, sys
lines = [line for line in os.environ["LIST_OUT"].splitlines() if line]
expected = sorted(sys.argv[1:])
problems = []

if any(line != line.rstrip() for line in lines):
    problems.append("有行尾空格")

# 第二列从第一段连续空格之后开始
cells, starts = [], []
for line in lines:
    body = line[len("\U0001f30a "):]
    match = re.search(r" {2,}", body)
    if match:
        cells.extend([body[:match.start()], body[match.end():]])
        starts.append(match.end())
    else:
        cells.append(body)

if starts and len(set(starts)) != 1:
    problems.append(f"第二列起始位置不一致：{sorted(set(starts))}")

if sorted(cells) != expected:
    problems.append("输出里的名字与装的不一致")

# 列优先：左列正好是排序后的前一半
rows = len(lines)
got_left = [line[len("\U0001f30a "):].split("  ")[0] for line in lines]
if got_left != expected[:rows]:
    problems.append(f"不是列优先：左列 {got_left}，应为 {expected[:rows]}")

print("; ".join(problems))
PYCHECK
)
if [ -z "$PROBLEMS" ]; then
    pass "列优先、对齐、无行尾空格、内容完整"
else
    fail "$PROBLEMS"
fi

echo
echo "========== 2. 奇数个（15）→ 最后一行只有左列 =========="
install_fixture "${PKGS[@]:0:15}"
OUT=$(list_wave)
LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [ "$LINES" -eq 8 ]; then
    pass "15 个包也是 8 行"
else
    fail "15 个包应该是 8 行，实际 $LINES 行"
fi
LAST=$(printf '%s\n' "$OUT" | tail -1)
if printf '%s' "$LAST" | grep -qE '🌊 [^ ]+$'; then
    pass "最后一行只有一个名字"
else
    fail "最后一行不是单列：$LAST"
fi

echo
echo "========== 3. 少到只有一两个，也不多出空列 =========="
install_fixture "jq@1.8.2"
OUT=$(list_wave)
if [ "$OUT" = "🌊 jq@1.8.2" ]; then
    pass "单个包就是一行一个名字"
else
    fail "单个包的输出不对：$OUT"
fi

install_fixture "jq@1.8.2" "yq@4.45.1"
OUT=$(list_wave)
LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [ "$LINES" -eq 1 ] && printf '%s' "$OUT" | grep -q 'jq@1.8.2.*yq@4.45.1'; then
    pass "两个包并成一行"
else
    fail "两个包的输出不对：$OUT"
fi

echo
echo "========== 4. 一个包都没装 =========="
install_fixture
OUT=$(list_wave)
case "$OUT" in
    *"No packages installed yet."*) pass "空列表给出固定提示" ;;
    *) fail "空列表的提示变了：$OUT" ;;
esac
case "$OUT" in
    *"🌊"*) pass "提示带 🌊" ;;
    *) fail "提示没有 🌊" ;;
esac

echo
echo "========== 5. --raw：一行一个、不带 🌊、不分列 =========="
install_fixture "${PKGS[@]}"
OUT=$(list_wave --raw)
LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
if [ "$LINES" -eq 16 ]; then
    pass "16 个包 = 16 行"
else
    fail "--raw 应该是 16 行，实际 $LINES 行"
fi
case "$OUT" in
    *"🌊"*) fail "--raw 输出里还有 🌊" ;;
    *) pass "--raw 里没有 🌊" ;;
esac
if printf '%s' "$OUT" | grep -q '  '; then
    fail "--raw 里还有补宽的空格"
else
    pass "--raw 里没有补宽空格"
fi
if [ "$OUT" = "$(printf '%s\n' "${PKGS[@]}" | sort)" ]; then
    pass "--raw 是排好序的名字，一行一个"
else
    fail "--raw 的内容与排序不对"
fi
if [ "$OUT" = "$(list_wave --raw | sed 's/^🌊 //')" ]; then
    pass "--raw 就是去掉 🌊 后的名字流"
else
    fail "--raw 与默认输出的名字不一致"
fi

echo
echo "========== 6. --raw 空列表：一个字节都不输出 =========="
install_fixture
OUT=$(list_wave --raw); RC=$?
if [ -z "$OUT" ]; then
    pass "空列表 --raw 无输出"
else
    fail "空列表 --raw 输出了东西：$OUT"
fi
if [ "$RC" -eq 0 ]; then
    pass "空列表 --raw 退出码 0"
else
    fail "空列表 --raw 退出码是 $RC"
fi

echo
echo "========== 7. --raw 拼错要说话 =========="
install_fixture "jq@1.8.2"
OUT=$(list_wave --raww)
case "$OUT" in
    *"unknown flag '--raww'"*) pass "拼错时明确报出来" ;;
    *) fail "拼错的旗标没有提示：$OUT" ;;
esac
case "$OUT" in
    *"🌊 jq@1.8.2"*) pass "拼错时照常按默认格式输出" ;;
    *) fail "拼错时连列表都没了" ;;
esac

echo
echo "========== 8. list 仍然不接受 -s =========="
OUT=$(list_wave -s); RC=$?
if [ "$RC" -ne 0 ]; then
    pass "wave list -s 被拒绝"
else
    fail "wave list -s 竟然成功了：$OUT"
fi

echo
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo "🌊 Failed: $FAILED"
echo "=========================================="

if [ "$FAILED" -eq 0 ]; then
    echo "🌊 All list format checks passed"
    exit 0
else
    echo "🌊 list format checks failed"
    exit 1
fi
