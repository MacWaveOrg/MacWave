#!/bin/bash

# structure_test.sh
# 项目结构的自检 —— 「运行时组件清单」只有一个来源，各处必须对得上。
#
# 背景：加一个顶层组件目录（例如把传输层从 lib/ 拆成 net/）时要同时改四处：
# 安装树的清单、lib/wave.py 的 sys.path、测试沙箱的拷贝、CI 的工作目录。这些以前
# 各写一份硬编码，漏一处不会报错，只会得到一个缺目录的安装树 —— 用户机器上表现为
# 某条命令 ImportError，本机表现为一条毫不相干的测试突然变红。
#
# 所以这里把两件事钉住：
#   1. scripts/components.txt 里的每个目录，wave.py 与 install.sh 都准备了；
#   2. 脚本与 CI 不许再手写「lib pkg surfboard」这样的三连（那就是第二份清单）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

echo "========== 项目结构 =========="

REPORT="$(mktemp -t macwave-structure)"
trap 'rm -f "$REPORT"' EXIT

python3 - "$REPO_DIR" > "$REPORT" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
components_file = repo / "scripts" / "components.txt"

lines = components_file.read_text(encoding="utf-8").splitlines()
components = [line.split("#", 1)[0].strip() for line in lines]
components = [name for name in components if name]

wave_py = repo / "lib" / "wave.py"
install_sh = repo / "lib" / "install.sh"
workflow = repo / ".github" / "workflows" / "format-test.yml"

checks = []


def report(name, title, problems):
    # 每条问题单独一行：bash 那边是逐行读的，把多行塞进一条 DETAIL 会让
    # 后面几行被当成不认识的记录丢掉（只剩第一条可见）。
    for problem in problems:
        print(f"DETAIL\t{problem}")
    print(f"CHECK\t{name}\t{title}\t{'0' if problems else '1'}")


problems = []
if not components:
    problems.append(f"{components_file} 是空的：没有任何组件目录")
for name in components:
    if not (repo / name).is_dir():
        problems.append(f"{name}：清单里有，仓库里没有这个目录")
report("exists", "清单里的每个组件目录都存在", problems)

problems = []
wave_text = wave_py.read_text(encoding="utf-8")
for name in components:
    if f'BASE_DIR / "{name}"' not in wave_text:
        problems.append(f"lib/wave.py 没有为组件 {name} 建路径（BASE_DIR / \"{name}\"）")
report("wave", "lib/wave.py 为每个组件建了 sys.path 路径", problems)

problems = []
install_text = install_sh.read_text(encoding="utf-8")
for name in components:
    if f"$BASE_DIR/{name}" not in install_text:
        problems.append(f"lib/install.sh 没有为组件 {name} 准备目录（$BASE_DIR/{name}）")
report("install", "lib/install.sh 为每个组件准备了目录", problems)

# selfupdate.sh 也要认识每个组件：它升级前会清掉各目录的 __pycache__，
# 漏一个就会留着旧字节码，后面排查「改了代码没生效」时非常费时间。
problems = []
selfupdate_text = (repo / "lib" / "selfupdate.sh").read_text(encoding="utf-8")
for name in components:
    if f"$BASE_DIR/{name}" not in selfupdate_text:
        problems.append(f"lib/selfupdate.sh 不认识组件 {name}（$BASE_DIR/{name}）")
report("selfupdate", "lib/selfupdate.sh 也认识每个组件", problems)

problems = []
for name, path in (("GitHub Actions", workflow),
                   ("CircleCI", repo / ".circleci" / "config.yml")):
    text = path.read_text(encoding="utf-8")
    if "components.txt" not in text:
        problems.append(f"{name} 的配置仍在手写组件清单；应当读 scripts/components.txt")
report("workflow", "两条流水线的测试沙箱与 lint 目标都读同一份清单", problems)

# 手写「三连」= 第二份清单。允许 lib/wave.py 逐行列（那是运行时的自我描述，
# 由上面那条检查盯着），不许脚本、CI、其它模块再抄一份。
FORBIDDEN = [
    (r'"\$REPO_DIR/lib" "\$REPO_DIR/pkg"', "shell 里的 cp -R 三连"),
    (r'str\(repo / "lib"\), str\(repo / "pkg"\)', "python 里的 sys.path 三连"),
    (r'\["lib", "pkg", "surfboard"\]', "写死的组件列表"),
    (r"\('lib', 'pkg', 'surfboard'\)", "写死的组件列表"),
    (r'"\$LIB_DIR:\$REPO_DIR/pkg"', "PYTHONPATH 三连"),
]
problems = []
targets = sorted(repo.glob("scripts/*.sh")) + sorted(repo.glob("scripts/*.py")) \
    + sorted(repo.glob(".github/workflows/*.yml")) + sorted(repo.glob("lib/*.py")) \
    + sorted(repo.glob("lib/*.sh")) + sorted(repo.glob("pkg/*.py")) \
    + sorted(repo.glob("surfboard/*.py"))
for path in targets:
    if path == components_file or path.resolve() == pathlib.Path(__file__).resolve():
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    for number, line in enumerate(text.splitlines(), 1):
        for pattern, why in FORBIDDEN:
            if re.search(pattern, line):
                problems.append(f"{path.relative_to(repo)}:{number} {why}：{line.strip()[:80]}")
report("single-source", "没有第二份手写的组件清单", problems)
PY

while IFS=$'\t' read -r kind rest; do
    case "$kind" in
        DETAIL)
            while IFS= read -r line; do
                echo -e "     ${RED_BOLD}$line${RESET}"
            done <<< "$rest"
            ;;
        CHECK)
            rest="${rest#*$'\t'}"
            title="${rest%$'\t'*}"
            ok="${rest##*$'\t'}"
            if [[ "$ok" == "1" ]]; then
                pass "$title"
            else
                fail "$title"
            fi
            ;;
    esac
done < "$REPORT"

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 Project structure is consistent${RESET}"
