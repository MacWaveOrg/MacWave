#!/bin/bash

# markdown_test.sh
# Markdown 的结构性问题 —— 只查会真正伤到读者的两类：
#
#   1. 相对链接指向不存在的文件。文档之间互相引用，被引用的一方改名或搬家时，
#      没有任何机制会告诉你。这一条抓过真事：docs/WHY-UPDATE.md 指向
#      ../history/...，而那份历史文档其实在另一个仓库。
#   2. 代码围栏不配对。少一个 ``` 会让围栏之后的所有内容变成代码块的延续 ——
#      渲染出来是一大段灰底文字，但源码里看着完全正常。
#
# 为什么不引入 markdownlint：实测这个仓库有 331 处无语言标注的围栏（大量终端
# 输出示例，本就不该标语言）和 17 处刻意跳级的标题，两条核心规则都得关掉。
# 关完之后剩下的（行尾空格、末尾换行）pre-commit 已经管了，增量价值接近零。
# 用一条针对性的检查，比引一个装成关掉大半的规则集更有用。

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

echo "========== Markdown 结构 =========="

python3 - "$REPO_DIR" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])

# 早期伪代码、个人草稿、模板目录：不是给读者看的文档
SKIP_PARTS = {".Pseudocode", "notes", ".templates", ".git", "node_modules"}

files = sorted(
    p for p in repo.rglob("*.md")
    if not (set(p.relative_to(repo).parts) & SKIP_PARTS)
)

problems = []

for path in files:
    text = path.read_text()
    rel = path.relative_to(repo)

    # 1) 围栏配对：``` 与 ~~~ 各自计数必须为偶数
    for marker in ("```", "~~~"):
        count = sum(1 for line in text.splitlines() if line.strip().startswith(marker))
        if count % 2:
            problems.append(f"{rel}: '{marker}' 围栏数量为奇数（{count}），少了一个闭合标记")

    # 2) 相对链接必须指向存在的文件
    for match in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", text):
        target = match.group(1).strip()
        # 外部链接、纯锚点、模板占位符都不是文件
        if re.match(r"^(https?:|mailto:|#|\{|<)", target):
            continue
        # 去掉锚点与查询串
        candidate = target.split("#", 1)[0].split("?", 1)[0]
        if not candidate:
            continue
        # 链接里可能带转义或百分号编码；本仓库没有，遇到就跳过而不是误报
        if "%" in candidate:
            continue
        resolved = (path.parent / candidate).resolve()
        if not resolved.exists():
            problems.append(f"{rel}: 链接指向不存在的文件 {target}")

if problems:
    for problem in problems:
        print(f"FAIL {problem}")
else:
    print(f"OK {len(files)} 个文档，围栏配对、相对链接均有效")
sys.exit(1 if problems else 0)
PY
if [[ $? -eq 0 ]]; then
    pass "文档围栏配对，相对链接都能打开"
else
    fail "文档结构有问题，见上面每一项"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All markdown checks passed${RESET}"
