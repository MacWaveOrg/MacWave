#!/bin/bash

# shell_lint.sh
# Shell 里两件「本地看着好、CI 上才炸」的事。
#
# 为什么需要它：同一个错误已经发生过两次 ——
#   1. minos_test 的 SKIP 提示：变量后面直接跟了全角左括号
#      → CI 报 `BACKFILL?: unbound variable`
#   2. 更新脚本的「正在下载」提示：变量后面直接跟了省略号
#      → CI 报 `repo_path?: unbound variable`
# 两次都是**变量后面紧跟一个多字节字符**（全角括号、省略号、全角逗号）。在 UTF-8
# locale 下 bash 能正确断词，本地怎么跑都绿；到了 locale 不是 UTF-8 的环境，那个
# 多字节字符的首字节被读进了变量名，于是「变量不存在」。
#
# 单靠肉眼看不出区别，所以做成检查。修法永远是给变量加花括号：`${VAR}……`。
#
# 第二件事是 `bash -n`：所有脚本的语法检查。它本来就该有，只是以前没人跑。
#
# 全程离线，秒级。

set -u
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

# 组件目录只有一份清单（scripts/components.txt）。这里手写「lib pkg surfboard」的
# 话就是第二份 —— structure_test 会盯着。
# shellcheck source=./components.sh
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0

pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }

echo "========== 1. 变量后面不许紧跟多字节字符 =========="

OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
# $VAR 后面直接跟一个非 ASCII 字符。加花括号的写法（${VAR}…）不会命中，
# 因为变量名后面紧跟的是 `}`。
pattern = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7f])")

offenders = []
for path in sorted(repo.rglob("*.sh")):
    if ".git" in path.parts:
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in pattern.finditer(line):
            offenders.append(
                f"{path.relative_to(repo)}:{lineno}  "
                f"${match.group(1)} 后面紧跟 {match.group(2)!r}"
                f"  ← 改成 ${{{match.group(1)}}}{match.group(2)}")

for item in offenders:
    print(f"  {item}")
print(f"# {len(offenders)}")
PYEOF
)

COUNT=$(echo "$OUTPUT" | grep -c '^  ')
echo "$OUTPUT" | grep '^  '

if [[ "$COUNT" -eq 0 ]]; then
    pass "没有「变量紧跟多字节字符」的写法"
else
    fail "$COUNT 处写法会在非 UTF-8 locale 下变成 unbound variable（见上）"
fi

echo
echo "========== 2. 每个脚本都能通过 bash -n =========="

SYNTAX_BAD=0
while IFS= read -r script; do
    if ! bash -n "$script" 2>/dev/null; then
        SYNTAX_BAD=$((SYNTAX_BAD + 1))
        echo -e "${RED_BOLD}  语法错误：${script#"$REPO_DIR"/}${RESET}"
        bash -n "$script" 2>&1 | head -3 | sed 's/^/    /'
    fi
done < <(
    for _component in $(components); do
        find "$REPO_DIR/$_component" -name '*.sh' -type f 2>/dev/null
    done
    find "$REPO_DIR/scripts" -name '*.sh' -type f 2>/dev/null
)

if [[ "$SYNTAX_BAD" -eq 0 ]]; then
    pass "所有 .sh 都通过 bash -n"
else
    fail "$SYNTAX_BAD 个脚本有语法错误"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All shell lint checks passed${RESET}"
