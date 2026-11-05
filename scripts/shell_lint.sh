#!/bin/bash

# shell_lint.sh
# Shell 里的三件「本地看着好、CI 上才炸」的事。
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
# 第三件事是**不许再叫 `say`**。macOS 自带 `/usr/bin/say`（朗读命令），而我们
# 的双语输出函数以前正好也叫 `say`：把带 `say "…" "…"` 的一行粘进终端（从文档、
# 从源码、从聊天记录里）不会报「command not found」，而是让整台机器大声把参数念
# 出来。已统一改名 `mw_say` / `mw_say_err`，这里挡住回退。
#
# 一次调试时作者在会议室不小心粘贴到 bash 终端，他的 Mac 开始大声播报命令：
# “波浪执行下列命令将 MacWave 添加到 PATH，eval（还念成了 evil）…………（此处省略若干字）”
# 以后谁也不许把函数命名为 say！
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
echo "========== 3. 不许再用 say / say_err 当函数名 =========="
# 与 macOS 的 /usr/bin/say 同名：粘贴一行就会让机器朗读。见文件头。

SAY_HITS=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
# 只认「命令位置上的 say」—— 也就是粘贴到终端会真的被执行的那种：
#   行首（可带缩进）的 say / say_err，或跟在 ; | && ( { 之后的。
# 这样不会误报注释里提到的名字、`/usr/bin/say` 这个真实路径、
# 以及 "aliases mw_say to say" 这类说明文字。
pattern = re.compile(r"(?:^\s*|[;|&({]\s*)say(?:_err)?\b")

# 本文件自己要被排除：它必须写出被禁的那个名字（标题、注释、正则）。
SKIP = {repo / "scripts" / "shell_lint.sh"}

hits = 0
for path in sorted(repo.rglob("*.sh")):
    if ".git" in path.parts or path in SKIP:
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        for match in pattern.finditer(line):
            name = match.group(0).split()[-1].lstrip(";|&({")
            hits += 1
            print(f"  {path.relative_to(repo)}:{lineno}  {name}  ← 改成 mw_{name}")
print(f"# {hits}")
PYEOF
)

SAY_BAD=$(echo "$SAY_HITS" | grep -c '^  ')
echo "$SAY_HITS" | grep '^  '

if [[ "$SAY_BAD" -eq 0 ]]; then
    pass "没有与 macOS say(1) 撞名的函数"
else
    fail "$SAY_BAD 处仍在用 say / say_err（粘贴到终端会让机器朗读）"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All shell lint checks passed${RESET}"
