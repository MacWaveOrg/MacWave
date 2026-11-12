#!/bin/bash

# docs_test.sh
# 手册（man/ 与 info/）与它们的来源之间不许走散。
#
# 三类断言：
#
#   1. 生成物是最新的：重跑 scripts/build_docs.py --check，任何一个文件落后就红。
#      手写的 man 页不会报错，只会在某次加旗标之后悄悄过时 —— 读者照着敲，
#      得到的是 "unknown option"。
#   2. 中英不脱节：命令集合、每条命令的旗标写法、全局旗标写法、`wave -h` 的每一节
#      都必须两边成套。少一条的表现是「中文手册里那一行没有解释」，
#      多一条则是「英文那边早改了名，这边留着幽灵」。
#   3. 生成出来的是干净文本：不许含 ANSI 转义（`info wave > notes.txt` 要能读），
#      info 文件必须有合法节点头，man 页第一行必须是 .TH。
#
# 全程离线，秒级。

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

echo "========== 1. 生成物是最新的 =========="
if OUT=$("$PYTHON" "$SCRIPT_DIR/build_docs.py" --check 2>&1); then
    pass "man/ 与 info/ 都是当前源码生成的"
else
    fail "生成物落后了：$(printf '%s' "$OUT" | tr '\n' ' ')"
fi

echo "========== 2. 中英不脱节 =========="
PROBLEMS=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
from components import paths as component_paths

sys.path[:0] = [str(path) for path in component_paths(repo)]

import help as help_en
import help_zh

problems = []

if set(help_en.COMMAND_HELP) != set(help_zh.COMMANDS_ZH):
    problems.append("命令集合不一致：缺 %s，多 %s" % (
        sorted(set(help_en.COMMAND_HELP) - set(help_zh.COMMANDS_ZH)),
        sorted(set(help_zh.COMMANDS_ZH) - set(help_en.COMMAND_HELP))))

for name, entry in help_en.COMMAND_HELP.items():
    if name not in help_zh.COMMANDS_ZH:
        continue
    en = {spec for spec, _ in entry["flags"]}
    cn = set(help_zh.COMMANDS_ZH[name]["flags"])
    if en != cn:
        problems.append("%s 的旗标说明不一致：缺 %s，多 %s"
                        % (name, sorted(en - cn), sorted(cn - en)))

en_global = {spec for spec, _ in help_en.GLOBAL_FLAGS}
cn_global = set(help_zh.GLOBAL_FLAGS_ZH)
if en_global != cn_global:
    problems.append("全局旗标不一致：缺 %s，多 %s"
                    % (sorted(en_global - cn_global), sorted(cn_global - en_global)))

for section in help_en.OVERVIEW:
    section_id = section["id"]
    if section_id not in help_zh.OVERVIEW_TITLES:
        problems.append("中文缺这一节的标题：%s" % section_id)
    for _kind, spec, _desc in section["rows"]:
        if spec not in help_zh.OVERVIEW_DESC.get(section_id, {}):
            problems.append("中文缺这一条的说明：%s / %s" % (section_id, spec))

for problem in problems:
    print(problem)
PYEOF
)

if [ -z "$PROBLEMS" ]; then
    pass "命令、旗标、总帮助三处的中英文都对得上"
else
    while IFS= read -r line; do
        [ -n "$line" ] && fail "$line"
    done <<< "$PROBLEMS"
fi

echo "========== 3. 命令表与分发表一致 =========="
# `wave -h` 里列的命令必须真的能跑。这一条是 4.4 期间踩过的：help.py 先加了
# manual，wave.py 的 COMMANDS 还没加 —— 手册里写着的命令敲下去是 unknown command。
MISSING=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
from components import paths as component_paths

sys.path[:0] = [str(path) for path in component_paths(repo)]

import help as help_en

source = (repo / "lib" / "wave.py").read_text(encoding="utf-8")
block = source[source.index("COMMANDS = {"):]
block = block[:block.index("}")]
dispatched = set(re.findall(r'"([a-z]+)":\s*"', block))

listed = set(help_en.COMMAND_HELP)
for name in sorted(listed - dispatched):
    print("%s 在 help.py 里有帮助页，但 wave.py 不会分发它" % name)
for name in sorted(dispatched - listed):
    print("%s 能被分发，但 help.py 里没有它的帮助页" % name)

# COMMANDS 的**值**（模块名）必须在 if/elif 链里有分支。4.4 期间踩过：
# 命令加进了 COMMANDS 字典，链上却没有对应分支 —— 于是那条命令什么也不做、
# 退出码还是 0，连报错都没有。命令表与分发链是两份手写的清单，只能靠比对钉住。
chain = source[source.index("COMMANDS = {"):]
for module in sorted({value for value in re.findall(r'"[a-z]+":\s*"([a-z]+)"', chain)}):
    if f'module_name == "{module}"' not in source:
        print("COMMANDS 里的 %s 没有对应的分发分支（命令会静默成功）" % module)
PYEOF
)
if [ -z "$MISSING" ]; then
    pass "每个有帮助页的命令都能被分发，反之亦然"
else
    while IFS= read -r line; do
        [ -n "$line" ] && fail "$line"
    done <<< "$MISSING"
fi

echo "========== 4. 生成物是干净的文本 =========="
ESCAPES=$(grep -rlP '\x1b\[' "$REPO_DIR/man" "$REPO_DIR/info" 2>/dev/null | wc -l | tr -d ' ')
if [ "$ESCAPES" = "0" ]; then
    pass "man/ 与 info/ 里没有 ANSI 转义码"
else
    fail "有 ${ESCAPES} 个生成文件含 ANSI 转义码（重定向到文件会变成乱码）"
fi

BAD_TH=$(for page in "$REPO_DIR"/man/man1/*.1; do
    head -n 1 "$page" | grep -q '^\.TH ' || echo "$page"
done)
if [ -z "$BAD_TH" ]; then
    pass "每个 man 页都以 .TH 开头"
else
    fail "这些 man 页缺少 .TH：${BAD_TH}"
fi

BAD_INFO=$(for page in "$REPO_DIR"/info/*.info; do
    head -n 2 "$page" | grep -q '^File: ' || echo "$page"
done)
if [ -z "$BAD_INFO" ]; then
    pass "每个 info 文件都有节点头"
else
    fail "这些 info 文件缺少节点头：${BAD_INFO}"
fi

EN_PAGES=$(ls "$REPO_DIR"/man/man1/*.1 2>/dev/null | grep -vc -- '-zh\.1$')
ZH_PAGES=$(ls "$REPO_DIR"/man/man1/*-zh.1 2>/dev/null | wc -l | tr -d ' ')
if [ "$ZH_PAGES" -gt 0 ] && [ "$EN_PAGES" = "$ZH_PAGES" ]; then
    pass "中文 man 页与英文一一对应（各 ${EN_PAGES} 页）"
else
    fail "中文 man 页 ${ZH_PAGES} 页、英文 ${EN_PAGES} 页，应当一一对应"
fi

if [ -f "$REPO_DIR/info/wave-zh.info" ]; then
    pass "info wave-zh 的文件在（info 按文件名找它）"
else
    fail "info/wave-zh.info 缺失：`info wave-zh` 会找不到手册"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 Documentation is consistent${RESET}"
