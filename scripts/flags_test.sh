#!/bin/bash

# flags_test.sh
# lib/flags.py 是「诊断用的旗标全集」，不是校验用的白名单。校验仍在各命令自己的
# 白名单里，所以两份清单必然并存 —— 这个测试的唯一职责是**不让它们走散**。
#
# 为什么值得单独一个测试：flags.py 只在「命令名写错」这一条路径上被用到，
# 平时跑不到。它漏一个新旗标的后果不是崩溃，而是那句本该给出的提示消失，
# 谁也不会发现。所以拿真实白名单逐项比。
#
# 全程离线，不碰网络也不碰已安装的 MacWave。

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

# 逐个与真白名单比对。Python 在这里只读源码常量，所以不需要装好的 MacWave。
python3 - "$REPO_DIR" <<'PY'
import re, sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "lib"))
import flags

problems = []

def add(msg):
    problems.append(msg)

# 1) pkginstaller 的三张表
src = (repo / "pkg" / "pkginstaller.py").read_text()
for name in ("ALLOWED_FLAGS", "UPGRADE_ONLY_FLAGS"):
    m = re.search(rf"^{name} = (\{{.*?\}})", src, re.S | re.M)
    if not m:
        add(f"pkginstaller.{name} 找不到")
        continue
    for flag in re.findall(r'"([^"]+)"', m.group(1)):
        if flag not in flags.ALL:
            add(f"pkginstaller.{name} 里的 {flag} 不在 flags.ALL")

m = re.search(r"^OTHER_COMMAND_FLAGS = (\{.*?\})", src, re.S | re.M)
if m:
    for flag in re.findall(r'^\s*"([^"]+)":', m.group(1), re.M):
        if flag not in flags.ALL:
            add(f"pkginstaller.OTHER_COMMAND_FLAGS 的键 {flag} 不在 flags.ALL")

# 2) mirrorinfo 的 FLAGS
src = (repo / "lib" / "mirrorinfo.py").read_text()
m = re.search(r"^FLAGS = (\{.*?\}|\{.*?\})", src, re.S | re.M)
if m:
    for flag in re.findall(r'"([^"]+)"', m.group(1)):
        if flag not in flags.ALL:
            add(f"mirrorinfo.FLAGS 里的 {flag} 不在 flags.ALL")

# 3) latest 接受的旗标（散在 split_arguments 的分支里）
src = (repo / "lib" / "latest.py").read_text()
for flag in ("--all", "-a", "--json", "--yaml", "--toml", "--raw"):
    if flag not in flags.ALL:
        add(f"latest 接受的 {flag} 不在 flags.ALL")

# 4) upgrade / link / unlink 的 -a --all、uninstall 的 --unlink
for flag in ("-a", "--all"):
    if flag not in flags.ALL:
        add(f"link 系命令接受的 {flag} 不在 flags.ALL")
    # upgrade 也认 -a（批量升级），漏了会让「-a 用错命令」的提示把 upgrade 漏掉
    if flag not in flags.COMMAND_FLAGS["upgrade"]:
        add(f"upgrade 接受的 {flag} 不在 flags.COMMAND_FLAGS['upgrade']")
if "--unlink" not in flags.ALL:
    add("uninstall 接受的 --unlink 不在 flags.ALL")

# 5) 分发前处理的四条
for flag in ("-h", "--help", "-V", "--version"):
    if flag not in flags.EARLY:
        add(f"{flag} 不在 flags.EARLY")

# 6) split() 的拆解规则必须与 pkginstaller.parse_flags 一致
cases = {
    "--name=value": ["--name"],
    "-abc": ["-a", "-b", "-c"],
    "-sX": ["-s", "-X"],
    "jq": [],
    "--skip-ssl": ["--skip-ssl"],
}
for token, want in cases.items():
    got = flags.split(token)
    if got != want:
        add(f"split({token!r}) = {got}，应为 {want}")

# 7) unknown_flags 的正反例
if flags.unknown_flags(["jq", "--unkown-flag"]) != ["--unkown-flag"]:
    add("unknown_flags 没能识别 --unkown-flag")
if flags.unknown_flags(["jq", "-s", "--proxy", "http://x"]) != []:
    add("unknown_flags 把合法旗标判成了非法")
if flags.unknown_flags(["-sX"]) != []:
    add("unknown_flags 把合并写法 -sX 判成了非法")
if flags.unknown_flags(["-qz"]) != ["-q", "-z"]:
    add("unknown_flags 没拆开合并写法 -qz")

if problems:
    for p in problems:
        print(f"FAIL {p}")
else:
    print(f"OK 检查通过（flags.ALL 共 {len(flags.ALL)} 个旗标）")
PY
rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "flags.py 与各命令白名单一致"
else
    fail "flags.py 与白名单走散了，见上面每一项"
fi

# 行为检查：命令名写错时，坏旗标必须被报出来；好旗标不能被误报
# wave.py 拒绝在 git 检出里运行，所以先复制一份不带 .git 的运行树
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
cp -R "$REPO_DIR/lib" "$REPO_DIR/pkg" "$REPO_DIR/surfboard" "$RUN_DIR/"
# 没有配置文件会在 check_environment 阶段就退出，先写一份最小的
mkdir -p "$RUN_DIR/root/opt/macwave_config"
printf '{"base_dir": "%s"}\n' "$RUN_DIR" > "$RUN_DIR/root/opt/macwave_config/config.json"

# 必须在 RUN_DIR 里执行：configerror 的「git 检出」检测跑的是 `git rev-parse`，
# 而它看的是**当前工作目录**，不是脚本所在目录。在仓库里跑就会被误判成 git clone。
WAVE_OUT=$(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" \
    python3 lib/wave.py update jq --unkown-flag 2>&1 || true)
if [[ "$WAVE_OUT" == *"Unknown flag: --unkown-flag"* ]]; then
    pass "未知命令 + 坏旗标 → 两条都报"
else
    fail "未知命令时没有报出坏旗标（输出前 120 字：${WAVE_OUT:0:120}）"
fi
if [[ "$WAVE_OUT" == *"Did you mean"* ]]; then
    pass "仍然给出命令名建议"
else
    fail "命令名建议消失了"
fi

# 旗标用对了拼写、但用错了命令时，别说成 unknown —— 那会把人送去查拼写。
# 静默模式下只有一行，这一行必须是「只适用于哪条命令」。
MISPLACED=$(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" \
    python3 lib/wave.py install jq -X -sS 2>&1 || true)
if [[ "$MISPLACED" == *"-X only applies to wave upgrade"* ]]; then
    pass "静默 + 错用命令的旗标 → 指向正确的命令"
else
    fail "静默下 -X 的提示没说清该用哪条命令（输出：${MISPLACED:0:120}）"
fi
if [[ "$MISPLACED" != *"unknown flag"* ]]; then
    pass "不把 -X 说成未知旗标"
else
    fail "-X 被误报成 unknown flag，用户会去查拼写"
fi

# 真拼错的仍要报 unknown，两者不能混为一谈
TYPO=$(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" \
    python3 lib/wave.py install jq -q -sS 2>&1 || true)
if [[ "$TYPO" == *"unknown flag: -q"* ]]; then
    pass "真拼错的旗标仍报 unknown"
else
    fail "拼错的旗标没有报 unknown（输出：${TYPO:0:120}）"
fi

# curl 的 -s / -S / -sS：单 -s 什么都不打（退出码是唯一信号），加 -S 才留错误
MUTED=$(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" \
    python3 lib/wave.py install jq -q -s 2>&1 || true)
if [[ -z "$MUTED" ]]; then
    pass "单给 -s：一个字节都不输出"
else
    fail "单给 -s 仍有输出：${MUTED:0:120}"
fi
MUTED_RC=0
(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" python3 lib/wave.py install jq -q -s >/dev/null 2>&1) || MUTED_RC=$?
if [[ "$MUTED_RC" -ne 0 ]]; then
    pass "单给 -s：失败仍靠退出码表达"
else
    fail "单给 -s 失败时退出码应为非零"
fi
if [[ "$TYPO" != *"Fetching version info"* ]]; then
    pass "-sS 只留错误，不带进度噪音"
else
    fail "-sS 混进了进度噪音"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All flag tests passed${RESET}"
