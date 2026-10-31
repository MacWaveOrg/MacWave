#!/bin/bash

# suggest_test.sh
# `pkg/pkginstaller.closest_name` —— 包名打错时的建议。
#
# 为什么单独一个测试：这段代码只在「索引里没有这个名字」时才会跑到，
# 平时 install 正常工作一次都碰不到。它悄悄退化成「什么建议都不给」时，
# 表现只是少了一行提示，没人会当成 bug 报上来。
#
# 全程离线，不碰网络，也不需要装好的 MacWave。

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

echo "========== closest_name =========="

python3 - "$REPO_DIR" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path[:0] = [str(repo / "lib"), str(repo / "pkg"), str(repo / "surfboard")]

# 只导入纯函数所在的模块；它顶层不读配置，所以离线可用。
import importlib.util

spec = importlib.util.spec_from_file_location("pkginstaller", repo / "pkg" / "pkginstaller.py")
module = importlib.util.module_from_spec(spec)
sys.modules["pkginstaller"] = module
spec.loader.exec_module(module)

# 与索引里真实存在的名字一致（去掉 test_* 那批负向夹具）
NAMES = ["atuin", "bat", "batt", "btop", "choma", "delta", "dust", "eza", "fd", "ffmpeg",
         "fileicon", "fx", "fzf", "htop", "hyperfine", "ipsw", "jq", "ldid", "lsd", "ncdu",
         "ollama", "palera1n", "pandoc", "rg", "sk", "starship", "taskwarrior-tui", "tmux",
         "tree", "trollrestore", "wget", "yq", "zoxide"]

problems = []


def expect(probe, want):
    got = module.closest_name(probe, NAMES)
    if got != want:
        problems.append(f"closest_name({probe!r}) -> {got!r}，应为 {want!r}")


# 短名字只错一个字母：ratio 恰好 0.50，旧的 cutoff=0.6 一个建议都不给
expect("xk", "sk")
# 改名前的旧名，用户手上可能还记着
expect("skim", "sk")
# 长名字错一两个字母
expect("btp", "btop")
expect("rgs", "rg")
expect("jqq", "jq")
expect("fzz", "fzf")
expect("lsf", "lsd")
expect("treee", "tree")
# 距离 2、ratio 0.75：只有 ratio 判据能覆盖，别被这次改动弄丢
expect("htpz", "htop")

# 完全不像的必须给 None —— 乱指一条同样装不上的命令比不给建议更糟
for probe in ("curl", "python", "zz", "ab", "xyz", ""):
    if module.closest_name(probe, NAMES) is not None:
        problems.append(f"closest_name({probe!r}) 给了建议，应当没有")

# 名字清单为空时不能崩
if module.closest_name("jq", []) is not None:
    problems.append("空名字清单应返回 None")

# 编辑距离本身
import itertools


def lev(a, b):
    return module._edit_distance(a, b)


if lev("", "") != 0 or lev("", "abc") != 3 or lev("abc", "") != 3:
    problems.append("空串的编辑距离不对")
if lev("xk", "sk") != 1:
    problems.append("xk -> sk 的编辑距离应为 1")
if lev("curl", "ncdu") != 4:
    problems.append("curl -> ncdu 的编辑距离应为 4")
if lev("same", "same") != 0:
    problems.append("相同字符串的编辑距离应为 0")

if problems:
    for problem in problems:
        print(f"FAIL {problem}")
else:
    print(f"OK {len(NAMES)} 个名字，建议与拒绝对判断都正确")
sys.exit(1 if problems else 0)
PY
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "包名建议：错一个字母能认出，完全不像就不乱指"
else
    fail "包名建议的行为不对，见上面每一项"
fi

echo "========== budget 参数的完整性 =========="

# 改超时的时候踩过：批量把 `timeout=30` 换成 `_to(budget or _fallback())`，
# 但某个函数签名里根本没有 budget —— NameError 被同层的
# `except Exception: return None, None` 吞掉，表现成「索引里没有这条记录」，
# 看着像数据问题，实际上是代码错。用静态检查挡住这一类。
python3 - "$REPO_DIR" <<'PY'
import ast, sys
from pathlib import Path

repo = Path(sys.argv[1])
problems = []

files = []
for folder in ("pkg", "lib", "surfboard"):
    files.extend(sorted((repo / folder).glob("*.py")))

for path in files:
    try:
        tree = ast.parse(path.read_text(), filename=str(path))
    except SyntaxError:
        continue
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue

        # 只看这个函数**自己**的作用域：嵌套函数各自算各自的，
        # 否则内层用到的名字会被算到外层头上。
        loads, stores = set(), set()
        stack = list(node.body)
        while stack:
            child = stack.pop()
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue                      # 不进入嵌套作用域
            if isinstance(child, ast.Name) and child.id == "budget":
                (stores if isinstance(child.ctx, ast.Store) else loads).add(child.id)
            stack.extend(ast.iter_child_nodes(child))

        # 自己赋过值 = 局部变量，不需要参数；只读才要求它从外面来
        if not loads or stores:
            continue
        params = {a.arg for a in node.args.args} | {a.arg for a in node.args.kwonlyargs}
        if "budget" not in params and node.args.kwarg is None:
            problems.append(f"{path.name}:{node.lineno} {node.name}() 读了 budget 但签名里没有")

if problems:
    for problem in problems:
        print(f"FAIL {problem}")
else:
    print("OK 每个用到 budget 的函数都有这个参数")
sys.exit(1 if problems else 0)
PY
if [[ $? -eq 0 ]]; then
    pass "budget 参数完整（不会退化成 NameError 被 except 吞掉）"
else
    fail "有用到 budget 却没声明参数的函数，见上"
fi

echo "========== 三档超时 =========="

python3 - "$REPO_DIR" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path[:0] = [str(repo / "lib"), str(repo / "pkg"), str(repo / "surfboard")]
import timeouts as T

problems = []

# 时长解析：与 --max-time 共用同一套规则
for text, want in [("40", 40.0), ("40s", 40.0), ("1min", 60.0),
                   ("1min20s", 80.0), ("250ms", 0.25), ("2h", 7200.0)]:
    got = T._parse_duration(text)
    if got != want:
        problems.append(f"_parse_duration({text!r}) = {got}, 应为 {want}")
for bad in ("abc", "", "0", "-5", "1x"):
    if T._parse_duration(bad) is not None:
        problems.append(f"_parse_duration({bad!r}) 应当拒绝")

# 三个旗标各自独立生效
cases = {
    "wave x":                                          (10, 30, 30),
    "wave x --connect-timeout=5":                      (5, 30, 30),
    "wave x --content-time=1min":                      (10, 60, 60),
    "wave x --max-time=10s":                           (10, 30, 10),
    "wave x --connect-timeout=3 --content-time=50":    (3, 50, 50),
}
for cmd, (connect, content, total) in cases.items():
    b = T.from_command_line(cmd)
    if (b.connect, b.content, b.total) != (connect, content, total):
        problems.append(f"{cmd!r} -> {(b.connect, b.content, b.total)}, "
                        f"应为 {(connect, content, total)}")

# 没给 --max-time 时总时长不能被默认值压小于显式给的 content
b = T.from_command_line("wave x --content-time=1min")
if b.total < b.content:
    problems.append(f"--content-time=1min 被总时长 {b.total} 压回去了")

# requests 拿到的元组；read 会被「剩余总时长」压住，所以只要落在合理区间
b = T.from_command_line("wave x --connect-timeout=3 --content-time=50").start()
connect, read = b.request_timeout
if connect != 3.0 or not (49.0 < read <= 50.0):
    problems.append(f"request_timeout = {(connect, read)}, 连接应为 3.0、读应≈50")
b = T.from_command_line("wave x --max-time=10s --content-time=50").start()
if b.request_timeout[1] > 10:
    problems.append("总时长 10s 时 read 仍给了 50s，等于总时长形同虚设")

if problems:
    for problem in problems:
        print(f"FAIL {problem}")
else:
    print("OK 三档超时的解析与互相压制都正确")
sys.exit(1 if problems else 0)
PY
if [[ $? -eq 0 ]]; then
    pass "三档超时：解析、独立生效、总时长兜底"
else
    fail "三档超时的行为不对，见上面每一项"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All suggestion tests passed${RESET}"
