#!/bin/bash

# flags_test.sh
# cli/flags.py 有两半，各测各的：
#
#   拆解（第 8 节）：flag_name / tokens / short_cluster / remove_short ——
#       silent、upgrader、latest、parse_flags 四处都依赖它们的返回形状。
#   清单：诊断用的旗标全集，不是校验用的白名单。校验仍在各命令自己的白名单里，
#       所以两份清单必然并存 —— 那几节负责**不让它们走散**。
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
source "$SCRIPT_DIR/components.sh"

PASSED=0
FAILED=0
pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED_BOLD}❌ $1${RESET}"; FAILED=$((FAILED + 1)); }

# 逐个与真白名单比对。Python 在这里只读源码常量，所以不需要装好的 MacWave。
python3 - "$REPO_DIR" <<'PY'
import re, sys
from pathlib import Path

repo = Path(sys.argv[1])
components = [line.split("#", 1)[0].strip()
              for line in (repo / "scripts" / "components.txt").read_text().splitlines()]
sys.path[:0] = [str(repo / name) for name in components if name]
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

# 3) latest 与 info 各自接受的输出格式旗标不能混为一谈。
#    混过的后果：`wave install jq --json` 提示成「--json 也适用于 latest」，
#    而 latest 收到 --json 会直接拒绝 —— 把人指到一条同样会失败的命令上。
for flag in ("--all", "-a"):
    if flag not in flags.ALL:
        add(f"latest 接受的 {flag} 不在 flags.ALL")
    if flag not in flags.COMMAND_FLAGS["latest"]:
        add(f"latest 接受的 {flag} 不在 flags.COMMAND_FLAGS['latest']")

for flag in ("--json", "--yaml", "--toml", "--raw"):
    if flag not in flags.ALL:
        add(f"info 接受的 {flag} 不在 flags.ALL")
    if flag not in flags.COMMAND_FLAGS["info"]:
        add(f"info 接受的 {flag} 不在 flags.COMMAND_FLAGS['info']")
    if flag in flags.COMMAND_FLAGS["latest"]:
        add(f"{flag} 被记到了 latest 名下，但 latest 并不接受它")

extra = flags.COMMAND_FLAGS["latest"] - {"--all", "-a"}
if extra:
    add(f"flags.COMMAND_FLAGS['latest'] 多了 latest 不接受的旗标: {sorted(extra)}")

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

# 8) 拆解原语。这一节是给「以后想优化一下」的人看的：这些函数的返回形状被
#    silent.strip / upgrader.split_input / latest.split_arguments / parse_flags
#    四处依赖，改成别的形状不会让任何端到端用例变红，只会让某条命令悄悄认不出旗标。
if flags.flag_name("--max-time=1min") != "--max-time":
    add("flag_name 没把 --max-time=1min 归一化")
if flags.flag_name("jq") != "jq":
    add("flag_name 动了包名")

if flags.tokens(["jq", "-sX", "--max-time=1min"]) != ["-s", "-X", "--max-time"]:
    add("tokens 没拆对混合写法")
if flags.tokens(["jq", "-", "--proxy", "x"]) != []:
    add("tokens 没在单独的 - 处停下（后面那个 --proxy 属于包名的一部分）")

if flags.short_cluster("-sX") != "sX":
    add("short_cluster(-sX) 不对")
if flags.short_cluster("--skip-ssl") is not None:
    add("short_cluster 把长旗标当成了簇")
if flags.short_cluster("jq") is not None:
    add("short_cluster 把包名当成了簇")

# 三种返回值各代表什么，见 flags.remove_short 的说明
if flags.remove_short("-s", "sS") != "":
    add("remove_short 拿空整个簇时应返回空串")
if flags.remove_short("-sX", "sS") != "-X":
    add("remove_short 没留住剩下的字母")
if flags.remove_short("-v", "sS") is not None:
    add("remove_short 没动过时应返回 None")
if flags.remove_short("--silent", "sS") is not None:
    add("remove_short 不该动长旗标")

# 9) 「哪些命令能静默」只该有一份事实。权威在 silent.SILENT_COMMANDS，
#    清单里的 silent 组只负责让 describe("-s") 说得出话 —— 两边走散的表现很安静：
#    加一条只读命令后它照样接受 -s，或者加一条能静默的命令后提示里把它漏掉。
import silent

owners = set(flags.owner_commands("-s"))
if owners != set(silent.SILENT_COMMANDS):
    add(f"-s 的命令清单与 SILENT_COMMANDS 不一致: "
        f"清单={sorted(owners)} 代码={sorted(silent.SILENT_COMMANDS)}")

expected = "-s only applies to wave install, wave link, wave selfupdate, " \
           "wave uninstall, wave unlink, wave upgrade"
if flags.describe("-s") != expected:
    add(f"describe(-s) 变了: {flags.describe('-s')!r}")
if flags.describe("-S") != expected.replace("-s only", "-S only", 1):
    add(f"describe(-S) 没跟着 -s 走: {flags.describe('-S')!r}")

# 进了 GLOBAL 就等于宣称「任何命令都接受」，那正是这条提示要否定的
for flag in ("-s", "--silent", "-S", "--show-error"):
    if flag in flags.GLOBAL:
        add(f"{flag} 又回到 GLOBAL 里了 —— 那等于任何命令都接受它")
    if flag not in flags.ALL:
        add(f"{flag} 不在 flags.ALL（会被当成不存在的旗标）")

# 只读命令一条都不能带 -s
for read_only in ("list", "search", "info", "latest", "mirror", "linkquery"):
    if read_only in owners:
        add(f"{read_only} 不该出现在 -s 的命令清单里（它存在的目的就是打印）")

if problems:
    for p in problems:
        print(f"FAIL {p}")
else:
    print(f"OK 检查通过（flags.ALL 共 {len(flags.ALL)} 个旗标）")

# 没有这一行，上面所有的 FAIL 都只是打印：shell 拿到 rc=0，
# 「flags.py 与白名单一致」这条断言永远不会红 —— 等于没测。
sys.exit(1 if problems else 0)
PY
rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "flags.py 的清单与拆解规则都符合约定"
else
    fail "flags.py 与白名单走散了，见上面每一项"
fi

# 行为检查：命令名写错时，坏旗标必须被报出来；好旗标不能被误报
# wave.py 拒绝在 git 检出里运行，所以先复制一份不带 .git 的运行树
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
copy_components "$RUN_DIR/"
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

# -sS 的输出是给脚本读的，一律不带 🌊；而普通模式必须保留（那是给人看的）
NOSUCH=$(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" \
    python3 lib/wave.py uninstall no_such_pkg -sS 2>&1 || true)
if [[ -n "$NOSUCH" && "$NOSUCH" != *"🌊"* ]]; then
    pass "-sS 输出不含 🌊"
else
    fail "-sS 输出仍带 🌊（实际：${NOSUCH:0:120}）"
fi
if [[ "$NOSUCH" == *"Error:"* ]]; then
    pass "-sS 去掉了 🌊 但保留错误文字"
else
    fail "-sS 把错误文字也弄丢了（实际：${NOSUCH:0:120}）"
fi
PLAIN=$(cd "$RUN_DIR" && MACWAVE_TEST="$RUN_DIR/root" \
    python3 lib/wave.py uninstall no_such_pkg 2>&1 || true)
if [[ "$PLAIN" == *"🌊"* ]]; then
    pass "非静默仍保留 🌊"
else
    fail "非静默的 🌊 被误删（实际：${PLAIN:0:120}）"
fi

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="
[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All flag tests passed${RESET}"
