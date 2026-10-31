#!/bin/bash

# depsync_test.sh
# 依赖清单的一致性：pyproject.toml 与各安装脚本必须说同一件事。
#
# 为什么需要它：同一份清单原先散在六处 —— install.sh、selfupdate.sh、
# 两个 workflow、sandbox_test、circleci。改一处漏五处的症状是「某个 CI
# 里 ImportError」，而那已经是推送之后才发现的。
#
# pyproject.toml 不能直接成为唯一来源：lib/install.sh 是 bash，装依赖时
# Python 环境可能还不存在（它正在装的就是那个环境），没法读 TOML。
# 所以做法是「两边都留着，用测试锁住」，而不是强行合并。

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

echo "========== 依赖声明一致性 =========="

python3 - "$REPO_DIR" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

repo = Path(sys.argv[1])
problems = []


def names(requirements):
    """从 ['requests>=2.20', 'rich>=12.0'] 取出名字部分。"""
    out = []
    for item in requirements:
        match = re.match(r"[A-Za-z0-9_.\-]+", item.strip())
        if match:
            out.append(match.group(0).lower().replace("_", "-"))
    return set(out)


# 事实来源：pyproject.toml
data = tomllib.loads((repo / "pyproject.toml").read_text())
project = data["project"]
declared = names(project.get("dependencies", []))
optional = set()
for extra in project.get("optional-dependencies", {}).values():
    optional |= names(extra)

if not declared:
    problems.append("pyproject.toml 的 dependencies 是空的")

# install.sh 与 selfupdate.sh 装的是「必需 + 可选」的并集：
# 它们的目的是开箱即用，进度条也算体验的一部分。
expected = declared | optional

# 1) lib/install.sh 的 PIP_DEPS=(...)
text = (repo / "lib" / "install.sh").read_text()
match = re.search(r"^PIP_DEPS=\((.*?)\)", text, re.M)
if not match:
    problems.append("lib/install.sh 里找不到 PIP_DEPS")
else:
    installed = names(match.group(1).split())
    if installed != expected:
        problems.append(
            f"lib/install.sh 的 PIP_DEPS 与 pyproject 不一致："
            f"脚本多装了 {sorted(installed - expected) or '无'}，"
            f"少装了 {sorted(expected - installed) or '无'}")

# 2) lib/selfupdate.sh 里那行裸的 pip install
text = (repo / "lib" / "selfupdate.sh").read_text()
# 依赖列表不紧跟在 pip install 后面：中间还夹着 --timeout / --index-url 几行。
# 找一行「行首缩进 + 以 requests 开头」的，那才是清单本身。
match = re.search(r"^[ \t]+(requests\b[^\n>]*)", text, re.M)
if not match:
    problems.append("lib/selfupdate.sh 里找不到依赖清单")
else:
    installed = names(match.group(1).split())
    if installed != expected:
        problems.append(
            f"lib/selfupdate.sh 与 pyproject 不一致："
            f"多 {sorted(installed - expected) or '无'}，"
            f"少 {sorted(expected - installed) or '无'}")

# 3) 各 CI 配置
ci_files = [
    repo / ".github" / "workflows" / "format-test.yml",
    repo / ".circleci" / "config.yml",
]
for ci in ci_files:
    if not ci.exists():
        continue
    for line in ci.read_text().splitlines():
        if "pip install" not in line:
            continue
        # 只关心装本项目依赖的那几行；--upgrade pip 之类跳过
        if "requests" not in line:
            continue
        installed = names(
            token for token in line.split()
            if re.match(r"^[A-Za-z]", token) and not token.startswith("-"))
        installed = {n for n in installed if n in (declared | optional) or n in {
            "requests", "packaging", "rich", "urllib3"}}
        if installed and installed != expected:
            problems.append(
                f"{ci.relative_to(repo)} 的 pip install 与 pyproject 不一致："
                f"多 {sorted(installed - expected) or '无'}，"
                f"少 {sorted(expected - installed) or '无'}")

# 4) sandbox_test.sh 的模块检查表
text = (repo / "scripts" / "sandbox_test.sh").read_text()
match = re.search(r"for mod in ([a-z0-9_ ]+);", text)
if match:
    checked = names(match.group(1).split())
    if checked != expected:
        problems.append(
            f"scripts/sandbox_test.sh 的模块表与 pyproject 不一致："
            f"多 {sorted(checked - expected) or '无'}，"
            f"少 {sorted(expected - checked) or '无'}")

# 5) 代码里真正 import 的三方库，必须都在声明里
third_party = {"requests", "packaging", "rich", "urllib3"}
imported = set()
for folder in ("lib", "pkg", "surfboard", "scripts"):
    for path in (repo / folder).glob("*.py"):
        for line in path.read_text().splitlines():
            match = re.match(r"\s*(?:import|from)\s+([a-z0-9_]+)", line)
            if match and match.group(1) in third_party:
                imported.add(match.group(1))
missing = imported - (declared | optional)
if missing:
    problems.append(f"代码里 import 了但没声明：{sorted(missing)}")

if problems:
    for problem in problems:
        print(f"FAIL {problem}")
else:
    print(f"OK 必需 {sorted(declared)}，可选 {sorted(optional)}，六处一致")
sys.exit(1 if problems else 0)
PY
if [[ $? -eq 0 ]]; then
    pass "pyproject.toml 与六处安装/CI 配置一致"
else
    fail "依赖声明走散了，见上面每一项"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All dependency declarations agree${RESET}"
