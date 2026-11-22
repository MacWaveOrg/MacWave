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
# 第四件事是 `mktemp -t 前缀`。macOS 的 mktemp 会自动补随机后缀，GNU mktemp
# （Linux）要求模板里**至少三个 X**，同一句在那边直接报
# `too few X's in template`。install.sh 的写探针就踩过这个：Linux 上探针永远失败，
# 于是「可写目录」被判成「非权限问题」并中止安装。模板一律写成
# `mktemp "${TMPDIR:-/tmp}/前缀.XXXXXX"`。
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
    if ! /bin/bash -n "$script" 2>/dev/null; then
        SYNTAX_BAD=$((SYNTAX_BAD + 1))
        echo -e "${RED_BOLD}  语法错误：${script#"$REPO_DIR"/}${RESET}"
        /bin/bash -n "$script" 2>&1 | head -3 | sed 's/^/    /'
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

echo "========== 4. 不许用只有 bash 4 才有的语法 =========="
# macOS 自带的是 /bin/bash 3.2，而 Homebrew 装的是 5.x。在 5.x 上写得顺手的
# `${var,,}`（小写化）、`mapfile`、`declare -A`、`&>>` 到了 3.2 上会报
# "bad substitution" 或 "command not found"，然后**脚本退出，一句提示都没有**。
#
# 2026-11-16 实际踩过：selfupdate 的 beta 拦截里用了 `${1,,}`，本地用 `bash`
# （5.x）验过全绿，CI 上 /bin/bash 3.2 一跑就直接退出 —— 顺便把排在前面的
# 跨大版本断言也带红了，因为脚本在那之前就死了。
#
# 所以：新写 shell 一律用 `/bin/bash` 验（`/bin/bash -n`、`/bin/bash 脚本`），
# 并且不要用下面这些写法。
BASH4_BAD=$(grep -rnE '(\$\{[0-9@*#?A-Za-z_][A-Za-z0-9_]*,,|\$\{[0-9@*#?A-Za-z_][A-Za-z0-9_]*\^\^|^[[:space:]]*(mapfile|readarray)\b|[[:space:]]declare[[:space:]]+-A|&>>|\|&)' \
    --include=*.sh "$REPO_DIR"/lib "$REPO_DIR"/pkg "$REPO_DIR"/surfboard "$REPO_DIR"/scripts 2>/dev/null \
    | grep -v '^.*shell_lint\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)

if [[ -z "$BASH4_BAD" ]]; then
    pass "没有 bash 4 专有语法（macOS 自带 3.2）"
else
    echo "$BASH4_BAD" | sed 's/^/  /'
    fail "$(echo "$BASH4_BAD" | grep -c .) 处用了 bash 4 专有语法；macOS 自带 /bin/bash 是 3.2"
fi

echo "========== 5. 一律用 /bin/bash，不要裸 bash =========="
# `bash` 走 PATH，而 PATH 上的 bash 可能是 /opt/homebrew/bin/bash（5.x）。
# 本机写起来没差别，行为却差很多：`${var,,}`、`mapfile`、`declare -A` 在 macOS
# 自带的 3.2 上是语法错误，报出来的样子是「脚本一句提示都没有就退出」。
#
# 2026-11-16 实际踩到：beta 拦截里用了 `${1,,}`，本地用 Homebrew 的 bash 5 验过全绿，
# CI 上 /bin/bash 3.2 一跑就死，还把排在前面的断言一起带红。
#
# 所以：脚本、测试、工作流、文档里的命令，一律写 `/bin/bash`。这条只查**命令位置**
# 的裸 bash（行首、`;` `&&` `||` `|` `(` `!` `$(` 之后），散文里的「bash 3.2」
# 「~/.bashrc」不算。
#
# 还要排除「Supported Packages」清单里的行：那是 `<包名>  by <作者>` 的格式，
# 而 `bash` 恰好是一个真包（2026-11-22 加进来的），行首就叫 bash —— 它是数据，
# 不是命令。判据用清单行的形状（两个以上空格 + by），对将来 `make`、`test`
# 这类同名包也成立。
BARE_BASH=$(cd "$REPO_DIR" && grep -rnE '(^[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*|[;&|(){}!][[:space:]]*|\$\([[:space:]]*)bash([[:space:]]|$)' \
    --include=*.sh --include=*.py --include=*.yml --include=*.md --include=*.mdc . 2>/dev/null \
    | grep -v '^\./\.git/' \
    | grep -v 'shell_lint\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -vE ':[0-9]+:[[:space:]]*[a-z0-9._+-]+[[:space:]]{2,}by[[:space:]]' \
    || true)

if [[ -z "$BARE_BASH" ]]; then
    pass "没有裸 bash 调用（一律 /bin/bash）"
else
    echo "$BARE_BASH" | head -20 | sed 's/^/  /'
    fail "$(echo "$BARE_BASH" | grep -c .) 处调用了裸 bash；请写 /bin/bash（PATH 上的可能是 Homebrew 5.x）"
fi

echo
echo "========== 6. mktemp 的模板要带 X =========="

# GNU mktemp 只认带 X 的模板；`mktemp -t 前缀` 是 BSD 的习惯写法，Linux 上报
# "too few X's in template"。这条只看命令位置，注释与文档不算。
BAD_MKTEMP=$(cd "$REPO_DIR" && grep -rnE 'mktemp[[:space:]]+-t[[:space:]]' --include=*.sh . 2>/dev/null \
    | grep -v '^\./\.git/' \
    | grep -v 'shell_lint\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    || true)

if [[ -z "$BAD_MKTEMP" ]]; then
    pass "没有 mktemp -t（模板都带 X，BSD 与 GNU 都认）"
else
    echo "$BAD_MKTEMP" | head -20 | sed 's/^/  /'
    fail "$(echo "$BAD_MKTEMP" | grep -c .) 处用了 mktemp -t；GNU mktemp 会报 too few X's，请写 mktemp \"\${TMPDIR:-/tmp}/前缀.XXXXXX\""
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All shell lint checks passed${RESET}"
