#!/bin/bash

# commands_test.sh
# 子命令元数据（cli/commands.py）的契约测试。
#
# 为什么要有这个测试：`wave -h` 里挂着一条 1.x 就删掉的命令，一直到 2.3.1 才被
# 用户发现 —— 因为帮助文本是一份手写清单，删命令时没人记得改它，也没有任何东西
# 会因此变红。现在帮助、手册、分发都从 cli/commands.py 生成（僵尸条目因此不可能
# 再出现），剩下会出错的地方只有三处，这个文件逐条盯住：
#
#   1. 表里指向的模块 / 处理函数真的存在（打错一个字母，命令敲下去就是 ImportError）
#   2. 帮助里写的旗标是 MacWave 认得的（`--unlk` 这种笔误不会有人发现）
#   3. 每条命令在 README 的命令表里都有（README 是另一份手写清单 ——
#      它曾经漏了 shellenv 与 manual）
#
# 全程离线：只读源码、只做 AST 解析，不 import 处理函数（它们要安装树与请求库）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

run_check() {   # run_check <标题> <python 片段>：片段打印问题即失败，空则通过
    local title="$1" body="$2" problems
    problems=$(python3 - "$REPO_DIR" <<PY
$body
PY
)
    if [ -z "$problems" ]; then
        pass "$title"
    else
        while IFS= read -r line; do
            [ -n "$line" ] && fail "$line"
        done <<< "$problems"
    fi
}

echo "========== 1. 元数据指向的模块与处理函数都存在 =========="

run_check "每个 module.handler 都能在源码里找到" '
import ast
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
from components import names

component_names = names()

sys.path[:0] = [str(repo / name) for name in component_names]
import commands

# 组件目录就是模块名的落点：pkg/pkginstaller.py、lib/selfupdate.py …
sources = {}
for name in component_names:
    for path in sorted((repo / name).glob("*.py")):
        sources[path.stem] = path

problems = []
for command in commands.all():
    path = sources.get(command.module)
    if path is None:
        problems.append("%s: 模块 %s.py 不在任何组件目录里" % (command.name, command.module))
        continue
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    defined = {node.name for node in tree.body
               if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}
    if command.handler not in defined:
        problems.append("%s: %s 里没有 %s()" % (command.name, command.module, command.handler))
    for field in ("summary", "usage", "desc"):
        if not getattr(command, field).strip():
            problems.append("%s: %s 是空的（wave -h / --help 会印出空白）" % (command.name, field))
    if not command.examples:
        problems.append("%s: 没有示例" % command.name)

# 模块名必须唯一：两个组件目录里同名模块只有一个会被 import 到，
# 而「哪个先命中」取决于 components.txt 的顺序 —— 元数据指过去就成了运气。
seen = {}
for name in component_names:
    for path in sorted((repo / name).glob("*.py")):
        seen.setdefault(path.stem, []).append(name)
for stem, owners in sorted(seen.items()):
    if len(owners) > 1:
        problems.append("模块名 %s.py 出现在多个组件目录：%s" % (stem, ", ".join(owners)))

print("\n".join(problems))
'

echo "========== 2. 帮助里写的旗标 MacWave 都认得 =========="

run_check "每条命令的 --help 旗标都在旗标全集里" '
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
from components import paths as component_paths

sys.path[:0] = [str(path) for path in component_paths(repo)]
import commands
import flags

problems = []
for command in commands.all():
    for spec, _desc in command.flags:
        # "-C, --continue" → ["-C", "--continue"]；"--proxy <string>" → ["--proxy"]
        for spelling in [part.strip() for part in spec.split(",")]:
            name = spelling.split(" ")[0]
            if name not in flags.ALL:
                problems.append("%s: 帮助里的 %s 不是 MacWave 认得的旗标" % (command.name, name))

print("\n".join(problems))
'

echo "========== 3. README 的命令表与元数据一致 =========="

run_check "README.md / README.zh-Hans.md 列出全部命令" '
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
from components import paths as component_paths

sys.path[:0] = [str(path) for path in component_paths(repo)]
import commands

LISTED = [command.name for command in commands.listed()]

def readme_commands(path):
    text = path.read_text(encoding="utf-8")
    # Commands 一节：从 "Commands:" 到下一个空行后的第一个非命令行
    block = re.search(r"^Commands:\n(.*?)\n\n", text, re.S | re.M)
    if not block:
        return None
    found = []
    for line in block.group(1).splitlines():
        match = re.match(r"\s{2}([a-z]+)\s", line)
        if match:
            found.append(match.group(1))
    return found

problems = []
for name in ("README.md", "README.zh-Hans.md"):
    path = repo / name
    if not path.exists():
        problems.append("%s 不存在" % name)
        continue
    found = readme_commands(path)
    if found is None:
        problems.append("%s 里找不到 Commands: 一节" % name)
        continue
    missing = [command for command in LISTED if command not in found]
    stale = [command for command in found if command not in LISTED]
    if missing:
        problems.append("%s 缺命令：%s" % (name, ", ".join(missing)))
    if stale:
        problems.append("%s 里有 `wave -h` 已经没有的命令：%s" % (name, ", ".join(stale)))

print("\n".join(problems))
'

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED_BOLD}🌊 Command metadata contract is broken${RESET}"
    exit 1
fi
echo -e "${GREEN}🌊 All command metadata contracts hold${RESET}"
