#!/bin/bash

# minos_test.sh
# min_os（实验性，4.3 转正）：版本解析、安装前警告、info 展示。
#
# 为什么需要它：这个字段的判断逻辑很窄，但错法很难在真机上复现 ——
#   * 位数不同怎么比（10.15 与 10.15.7、14 与 14.0、26.6.2 与 26.6.3）
#   * 字段缺失必须**静默**：索引里绝大多数记录还没有它，误报会让所有人以为坏了
#   * 低于声明只警告、**不拦截**：jq 声明 14.0 却在 12.7.6 上实测跑得动，
#     拦下来会误杀；所以这里钉住「警告照打、安装照走」
#   * -s 要连警告一起静默（它自己的语义就是「什么都不打印」）
#   * info 的 json / yaml / toml 三种输出里，没有声明时这一行都不该出现
#
# 用真实模块跑，不用 mock —— 上一轮随机测试的教训是：假设要能被确定性证伪。
# 全程离线，不发请求。

set -u
# 关掉 -e：CI 会用 `bash -e` 起脚本，继承到的 -e 会让第一个非零退出结束整段。
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

# `import pkginstaller` 在模块级就会调 load_base_dir()：找不到配置文件直接
# sys.exit(1)。CircleCI 刻意保持零配置（见 .circleci/config.yml 开头），所以那里
# 必须造一份。只在缺配置时才伪造 HOME —— 一律伪造会让 python 找不到用户级的
# site-packages（本机 requests 就装在那里），反而把测试弄坏。
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f /opt/macwave_config/config.json \
      && ! -f "$HOME/.config/macwave_config/config.json" ]]; then
    export HOME="$WORK/home"
    mkdir -p "$HOME/.config/macwave_config" "$WORK/base/bin"
    printf '{"base_dir": "%s"}\n' "$WORK/base" > "$HOME/.config/macwave_config/config.json"
fi

PASSED=0
FAILED=0
HARD_FAIL=0

OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import io
import sys
from contextlib import redirect_stdout

repo = sys.argv[1]
for sub in ("pkg", "net", "lib", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import pkginstaller as inst
import pkginfohelper as info

passed = 0
failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS: {label}")
    else:
        failed += 1
        print(f"FAIL: {label} -> got {got!r}, want {want!r}")


def record(min_os=None):
    text = 'sha256:"' + "a" * 64 + '"\nurl: "https://example.invalid/x"\n'
    if min_os is not None:
        text += f'min_os: "{min_os}"\n'
    return text


def spoken(fn):
    """跑一次，只返回它打到 stdout 的内容（steplog 走 stderr，不混进来）。"""
    buf = io.StringIO()
    with redirect_stdout(buf):
        value = fn()
    return buf.getvalue(), value


# -------------------- 1. 版本解析 --------------------
print("# parse")
for text, want in [
    ("12.1", (12, 1)),
    ("14", (14,)),
    ("10.15.7", (10, 15, 7)),
    ("7.10", (7, 10)),
    (" 12.1 ", (12, 1)),
    ("", None),
    ("a.b", None),
    ("1.2.3.4", None),
    ("12..1", None),
]:
    check(f"_parse_dotted_version({text!r})", inst._parse_dotted_version(text), want)

# 位数不同时的比较方向
check("10.15 < 10.15.7",
      inst._parse_dotted_version("10.15") < inst._parse_dotted_version("10.15.7"), True)
check("7.10 > 7.9",
      inst._parse_dotted_version("7.10") > inst._parse_dotted_version("7.9"), True)

# -------------------- 2. 该放行的必须放行，且一个字都不打 --------------------
print("# silent pass-through")
for label, text in [
    ("无 min_os 字段", record()),
    ("低于本机", record("10.9")),
    ("非法版本串", record("abc")),
    ("空版本串", record("")),
]:
    said, ret = spoken(lambda t=text: inst.confirm_min_os(t, "jq", "1.8.2"))
    check(f"{label}：直接放行", ret, True)
    check(f"{label}：一个字都不打", said, "")


def ask(reply, text, *args):
    """把 sys.stdin 换成给定答复，跑一次，返回 (打印内容, 返回值)。

    直接调用会在真终端上阻塞等输入 —— 那会让本地跑脚本的人以为卡住了。
    """
    said, ret = "", None
    old = sys.stdin
    sys.stdin = io.StringIO(reply)
    try:
        said, ret = spoken(lambda: inst.confirm_min_os(text, *args))
    finally:
        sys.stdin = old
    return said, ret


# -------------------- 3. 低于声明：警告 + 问一句，y/Y 才继续 --------------------
print("# warn and ask")
running = inst.current_macos_version()
if running is None:
    print("SKIP: 非 macOS，跳过「高于本机」一组")
else:
    # 造一个「比本机高」的合法声明：末段 +1，段数不变。
    # 不要用 running + (0,) —— 两段机器会得到三段正好合法，但 macOS 26.6.2 这类
    # 三段机器会拼出四段 "26.6.2.0"，_parse_dotted_version 不收，于是静默放行、
    # 断言看起来全绿却什么都没验到。CI 就是这个组合。
    bumped = list(running)
    bumped[-1] += 1
    declared = ".".join(str(part) for part in bumped)
    actual = ".".join(str(part) for part in running)
    higher = record(declared)

    said, ret = ask("y\n", higher, "jq", "1.8.2")
    check("打出声明要求", declared in said, True)
    check("打出本机版本", actual in said, True)
    check("说明「可能仍然可用」", "may still work" in said, True)
    check("问句带默认值 [y/N]", "[y/N]" in said, True)
    check("是黄字", "\033[33m" in said and "\033[0m" in said, True)
    check("答复 y：继续", ret, True)

    check("答复 Y：继续", ask("Y\n", higher, "jq", "1.8.2")[1], True)
    check("答复 n：中止", ask("n\n", higher, "jq", "1.8.2")[1], False)
    check("直接回车（默认 N）：中止", ask("\n", higher, "jq", "1.8.2")[1], False)
    check("答复 yes：中止（只认单个 y）", ask("yes\n", higher, "jq", "1.8.2")[1], False)
    check("非交互（读不到答复）：中止", ask("", higher, "jq", "1.8.2")[1], False)

    # -F / --force：越过询问，但警告照打
    said, ret = ask("", higher, "jq", "1.8.2", True)
    check("--force：不询问、直接继续", ret, True)
    check("--force：不问句", "[y/N]" not in said, True)
    check("--force：仍然打警告", declared in said, True)

    # -s：不询问，直接拒绝。原因由调用点的 steplog.fail 负责输出
    # （纯 -s 时 fd 已指向 /dev/null，一个字节都不出去；-sS 才留着错误）。
    inst.quiet.set_silent(True)
    said, ret = ask("y\n", higher, "jq", "1.8.2")
    check("-s：一个字都不打", said, "")
    check("-s：不询问、直接拒绝（答复被忽略）", ret, False)

    # -s + -F：force 优先，仍然强制安装
    said, ret = ask("", higher, "jq", "1.8.2", True)
    check("-s + --force：仍然强制安装", ret, True)
    check("-s + --force：也不打字", said, "")

    # -sS：行为同 -s，只是错误留在输出里（由 steplog 决定，本函数不打）
    inst.quiet.set_silent(True, show_error=True)
    said, ret = ask("", higher, "jq", "1.8.2")
    check("-sS：同样不询问、直接拒绝", ret, False)
    check("-sS：本函数自己不打字", said, "")
    inst.quiet.set_silent(False)

print(f"# summary {passed} {failed}")
PYEOF
)

# python 块崩溃时 PASS/FAIL 都不会打出来，统计会变成 0/0 然后「全绿」—— 必须单独抓
[[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: 版本与警告段 python 异常退出${RESET}"; }

echo "$OUTPUT" | grep -v '^PASS: \|^FAIL: \|^NOTE: \|^SKIP: \|^#\|^$'

PASSED=$(echo "$OUTPUT" | grep -c '^PASS: ')
FAILED=$(echo "$OUTPUT" | grep -c '^FAIL: ')
echo "$OUTPUT" | grep '^FAIL: '
echo "$OUTPUT" | grep '^SKIP: \|^NOTE: '

# -------------------- 4. info 的输出 --------------------
OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import json
import sys

repo = sys.argv[1]
for sub in ("pkg", "net", "lib", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import pkginfohelper as info

passed = 0
failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        passed += 1
        print(f"PASS: {label}")
    else:
        failed += 1
        print(f"FAIL: {label} -> got {got!r}, want {want!r}")


remote = {"aut": "A", "des": "D", "hom": "H", "lic": "L"}

with_field = info.info_fields("jq", remote, [], ["1.8.2"], "14.0")
without = info.info_fields("jq", remote, [], ["1.8.2"])

check("info_fields 带 min_os", with_field.get("min_os"), "14.0")
check("info_fields 不带 min_os 时字段不出现", "min_os" in without, False)

as_json = json.loads(info.info_as_json(with_field))
check("json 里有 min_os", as_json.get("min_os"), "14.0")
check("json 无声明时没有 min_os", "min_os" in json.loads(info.info_as_json(without)), False)

check("yaml 里有 min_os", 'min_os: "14.0"' in info.info_as_yaml(with_field), True)
check("yaml 无声明时没有 min_os", "min_os" in info.info_as_yaml(without), False)

check("toml 里有 min_os", 'min_os = "14.0"' in info.info_as_toml(with_field), True)
check("toml 无声明时没有 min_os", "min_os" in info.info_as_toml(without), False)

print(f"# summary {passed} {failed}")
PYEOF
)

[[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: info 输出段 python 异常退出${RESET}"; }

PASSED=$((PASSED + $(echo "$OUTPUT" | grep -c '^PASS: ')))
FAILED=$((FAILED + $(echo "$OUTPUT" | grep -c '^FAIL: ')))
echo "$OUTPUT" | grep '^FAIL: '

# -------------------- 5. 回填脚本的写入规则 --------------------
BACKFILL="$REPO_DIR/../infosource/scripts/backfill_min_os.py"
if [[ -f "$BACKFILL" ]]; then
    # 单独一个目录：上面的 WORK 已经被 HOME 的临时配置占住，不能再覆盖
    BACKFILL_WORK="$WORK/backfill"
    mkdir -p "$BACKFILL_WORK"

    printf 'sha256:"%s"\nurl: "u"\n' "$(printf 'a%.0s' {1..64})" > "$BACKFILL_WORK/_pkg@1.0"
    OUTPUT=$("$PYTHON" - "$BACKFILL" "$BACKFILL_WORK/_pkg@1.0" <<'PYEOF'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("bf", sys.argv[1])
bf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bf)

path = sys.argv[2]
actions = (bf.write_field(path, "12.1", False),   # 首次：追加
           bf.write_field(path, "12.1", False),   # 重跑：不动
           bf.write_field(path, "13.0", False))   # 改值：原位替换
ok = actions == ("added", "unchanged", "updated")
print(("PASS: " if ok else "FAIL: ")
      + f"回填幂等（added/unchanged/updated）-> {actions}")

text = open(path, encoding="utf-8").read()
good = text.endswith("\n") and text.count('min_os: "13.0"') == 1
print(("PASS: " if good else "FAIL: ") + "回填后仍以换行结尾且只有一行 min_os")
PYEOF
)
    [[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: 回填段 python 异常退出${RESET}"; }
    PASSED=$((PASSED + $(echo "$OUTPUT" | grep -c '^PASS: ')))
    FAILED=$((FAILED + $(echo "$OUTPUT" | grep -c '^FAIL: ')))
    echo "$OUTPUT" | grep '^FAIL: '
else
    echo "SKIP: 未找到 ${BACKFILL}（infosource 与 MacWave 不在同一父目录）"
fi

FAILED=$((FAILED + HARD_FAIL))

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All min_os tests passed${RESET}"
