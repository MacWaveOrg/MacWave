#!/bin/bash

# net_policy_test.sh
# 传输层契约 —— 「发请求」这件事只允许经过一套策略。
#
# 为什么需要它：`--skip-ssl`、三档超时这些东西在库里都有，但**漏用在调用点上**时
# 代码读起来完全正常，只有真拿自签证书 / 慢网络去试才暴露。4.1.5 一次修了三处
# 「解析了没生效」，全是这一类；`--skip-ssl` 最初也只覆盖了包体下载。靠人记不住，
# 靠随机测试撞不稳，所以这里用 AST 把「每个请求点都带策略」变成必须满足的条件。
#
# 为什么用 AST 而不是 grep：请求调用普遍跨行写
#
#     response = requests.get(url, timeout=...,
#                             **tls.request_kwargs())
#
# 正则要么漏判要么误判；注释和 `echo "...curl..."` 这类打印文本也会被 grep 当成
# 真调用。AST 只看真正的调用节点，注释、字符串、打印文本天然不算。
#
# 只扫出货的三个目录（lib/pkg/surfboard）：scripts/ 是开发工具，不参与用户机器上
# 的 `--skip-ssl` 语义，把它们绑进来只会制造无关的红。

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

echo "========== 传输层契约 =========="

REPORT="$(mktemp -t macwave-net-policy)"
trap 'rm -f "$REPORT"' EXIT

python3 - "$REPO_DIR" > "$REPORT" <<'PY'
import ast
import pathlib
import sys

repo = pathlib.Path(sys.argv[1]).resolve()

# 组件目录的唯一来源；扫描范围就是「装进用户机器的那些目录」。
SHIPPED_DIRS = [line.split("#", 1)[0].strip()
                for line in (repo / "scripts" / "components.txt")
                .read_text(encoding="utf-8").splitlines()]
SHIPPED_DIRS = [name for name in SHIPPED_DIRS if name]
REQUEST_METHODS = {"get", "post", "put", "patch", "delete", "head", "request"}
SHELL_FILES = [path for directory in SHIPPED_DIRS
               for path in sorted((repo / directory).glob("*.sh"))]
SHELL_FILES.append(repo / "scripts" / "update_commands.template.sh")


def rel(path):
    return str(path.relative_to(repo))


def py_files():
    for directory in SHIPPED_DIRS:
        for path in sorted((repo / directory).rglob("*.py")):
            if "__pycache__" in path.parts:
                continue
            yield path


def parse(path):
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def has_policy(keywords, want):
    """有 `**tls.<want>()` 或 `**<want>` 吗。"""
    for keyword in keywords:
        if keyword.arg is not None:      # 具名参数不算，必须是 ** 展开
            continue
        value = keyword.value
        if isinstance(value, ast.Call):
            func = value.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")
            if name == want:
                return True
        elif isinstance(value, ast.Name) and value.id.endswith(want):
            return True
    return False


def check_requests():
    problems = []
    for path in py_files():
        for node in ast.walk(parse(path)):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if (isinstance(func, ast.Attribute) and func.attr in REQUEST_METHODS
                    and isinstance(func.value, ast.Name) and func.value.id == "requests"):
                if not has_policy(node.keywords, "request_kwargs"):
                    problems.append(f"{rel(path)}:{node.lineno} "
                                    f"requests.{func.attr}(...) 没带 **tls.request_kwargs()")
    return problems


def check_urlopen():
    problems = []
    for path in py_files():
        for node in ast.walk(parse(path)):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            is_urlopen = (isinstance(func, ast.Name) and func.id == "urlopen") or \
                         (isinstance(func, ast.Attribute) and func.attr == "urlopen")
            if is_urlopen and not has_policy(node.keywords, "urlopen_kwargs"):
                problems.append(f"{rel(path)}:{node.lineno} "
                                f"urlopen(...) 没带 **tls.urlopen_kwargs()")
    return problems


def check_curl():
    problems = []
    for path in SHELL_FILES:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            # 注释、以及打印给用户看的命令（占位符 <url>）都不是真调用
            if line.startswith("#") or "curl -" not in line or "<url>" in line:
                continue
            if "--max-time" not in line and "CURL_LIMITS" not in line:
                problems.append(f"{rel(path)}:{number} curl 没带 --max-time 或 ${{CURL_LIMITS}}")
    # Python 里组装的 curl（subprocess）；整条语句检查，因为参数常常跨行
    for path in py_files():
        text = path.read_text(encoding="utf-8")
        for node in ast.walk(parse(path)):
            if not isinstance(node, ast.stmt):
                continue
            segment = ast.get_source_segment(text, node) or ""
            if ("'curl'" in segment or '"curl"' in segment) and "curl_flags()" not in segment:
                problems.append(f"{rel(path)}:{node.lineno} 组装的 curl 没有 tls.curl_flags()")
    return problems


def check_ssl_switch():
    problems = []
    for path in py_files():
        if path == repo / "net" / "tls.py":
            continue
        for node in ast.walk(parse(path)):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name.split(".")[0] in ("ssl", "urllib3"):
                        problems.append(f"{rel(path)}:{node.lineno} 直接 import {alias.name}；"
                                        f"SSL 开关只允许出现在 net/tls.py")
            elif isinstance(node, ast.ImportFrom):
                module = (node.module or "").split(".")[0]
                if module in ("ssl", "urllib3"):
                    problems.append(f"{rel(path)}:{node.lineno} 直接 import {node.module}；"
                                    f"SSL 开关只允许出现在 net/tls.py")
            elif isinstance(node, ast.Call) and any(kw.arg == "verify" for kw in node.keywords):
                problems.append(f"{rel(path)}:{node.lineno} 自己传 verify=；"
                                f"只允许经 tls.request_kwargs()")
    return problems


CHECKS = [
    ("requests", "每个 requests 调用都带 **tls.request_kwargs()", check_requests),
    ("urlopen", "每个 urlopen 调用都带 **tls.urlopen_kwargs()", check_urlopen),
    ("curl", "每个 curl 都有超时，SSL 旗标只来自 tls.curl_flags()", check_curl),
    ("ssl", "SSL 开关只出现在 net/tls.py", check_ssl_switch),
]

for name, title, func in CHECKS:
    problems = func()
    for problem in problems:
        print(f"DETAIL\t{problem}")
    print(f"CHECK\t{name}\t{title}\t{'0' if problems else '1'}")
PY

while IFS=$'\t' read -r kind rest; do
    case "$kind" in
        DETAIL)
            while IFS= read -r line; do
                echo -e "     ${RED_BOLD}$line${RESET}"
            done <<< "$rest"
            ;;
        CHECK)
            name="${rest%%$'\t'*}"
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
echo -e "${GREEN}🌊 All transport-layer contracts hold${RESET}"
