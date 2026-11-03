#!/bin/bash

# minos_test.sh
# min_os（实验性，4.3 转正）：版本解析、安装前提醒、info 展示。
#
# 为什么需要它：这个字段的判断逻辑很窄，但错法很难在真机上复现 ——
#   * 位数不同怎么比（10.15 与 10.15.7、14 与 14.0）
#   * 字段缺失必须**静默**：索引里绝大多数记录还没有它，误报会让所有人以为坏了
#   * 非交互（CI / stdin 是 /dev/null）必须往安全侧倒，不能挂在那里等输入
#   * info 的 json / yaml / toml 三种输出里，没有声明时这一行都不该出现
#
# 用真实模块跑，不用 mock —— 上一轮随机测试的教训是：假设要能被确定性证伪。
# 全程离线，不发请求。

set -u
# 关掉 -e：本脚本故意执行会返回 False 的路径（用户拒绝安装）。
# CI 会用 `bash -e` 起脚本，继承到的 -e 会让第一个预期拒绝的用例结束整个脚本。
set +e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON=${PYTHON:-python3}

PASSED=0
FAILED=0
HARD_FAIL=0

OUTPUT=$("$PYTHON" - "$REPO_DIR" <<'PYEOF'
import sys

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

# 位数不同时的比较方向：10.15 早于 10.15.7
check("10.15 < 10.15.7",
      inst._parse_dotted_version("10.15") < inst._parse_dotted_version("10.15.7"), True)
check("7.10 > 7.9",
      inst._parse_dotted_version("7.10") > inst._parse_dotted_version("7.9"), True)

# -------------------- 2. 安装前的判断 --------------------
print("# check")
check("无 min_os 字段：放行", inst.check_min_os(record(), "jq", "1.8.2", False), True)
check("低于本机：放行", inst.check_min_os(record("10.9"), "jq", "1.8.2", False), True)
check("非法版本串：放行", inst.check_min_os(record("abc"), "jq", "1.8.2", False), True)
check("空版本串：放行", inst.check_min_os(record(""), "jq", "1.8.2", False), True)

running = inst.current_macos_version()
if running is None:
    print("SKIP: 非 macOS，跳过「高于本机」一组")
else:
    # 造一个「比本机高」的合法声明：末段 +1，段数不变。
    # 不要用 running + (0,) —— 本机两段会得到三段，但 macOS 26.6.2 这类三段
    # 的机器会拼出四段 "26.6.2.0"，而 _parse_dotted_version 最多收三段，
    # 于是静默放行、断言全绿。CI 就是这个组合。
    bumped = list(running)
    bumped[-1] += 1
    declared = ".".join(str(part) for part in bumped)
    check("高于本机 + --force：放行",
          inst.check_min_os(record(declared), "jq", "1.8.2", True), True)
    # stdin 已被这里占住，非交互分支在下面由 shell 单独跑
    print(f"NOTE: 本机 {running}，高于它的声明用 {declared}")

print(f"# summary {passed} {failed}")
PYEOF
)

# python 块崩溃时 PASS/FAIL 都不会打出来，统计会变成 0/0 然后"全绿" —— 必须单独抓
[[ $? -eq 0 ]] || { HARD_FAIL=$((HARD_FAIL + 1)); echo -e "${RED_BOLD}🌊 FAIL: 版本解析段 python 异常退出${RESET}"; }

echo "$OUTPUT" | grep -v '^PASS: \|^FAIL: \|^NOTE: \|^SKIP: \|^#\|^$'

PASSED=$(echo "$OUTPUT" | grep -c '^PASS: ')
FAILED=$(echo "$OUTPUT" | grep -c '^FAIL: ')
echo "$OUTPUT" | grep '^FAIL: '
echo "$OUTPUT" | grep '^SKIP: \|^NOTE: '

# -------------------- 3. 非交互与用户答复 --------------------
# 单独跑：这里要控制 stdin，不能和上面的断言共用同一个进程。

cat > "$SCRIPT_DIR/.minos_probe.py" <<'PYEOF'
import sys

repo = sys.argv[1]
for sub in ("pkg", "net", "lib", "surfboard"):
    sys.path.insert(0, f"{repo}/{sub}")

import pkginstaller as inst

running = inst.current_macos_version()
if running is None:
    print("SKIP")
    sys.exit(0)

bumped = list(running)
bumped[-1] += 1
declared = ".".join(str(part) for part in bumped)
record = 'sha256:"' + "a" * 64 + f'"\nmin_os: "{declared}"\n'
print("RESULT", inst.check_min_os(record, "jq", "1.8.2", False))
PYEOF

probe() { "$PYTHON" "$SCRIPT_DIR/.minos_probe.py" "$REPO_DIR"; }

verdict() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "SKIP" ]]; then
        echo "SKIP: $label"
    elif [[ "$got" == "$want" ]]; then
        PASSED=$((PASSED + 1))
        echo -e "${GREEN}🌊 PASS: $label${RESET}"
    else
        FAILED=$((FAILED + 1))
        echo -e "${RED_BOLD}🌊 FAIL: $label -> got $got, want $want${RESET}"
    fi
}

verdict "交互答复 y：继续安装" \
    "RESULT True"  "$(echo y | probe | tail -1)"
verdict "交互答复 Y：继续安装" \
    "RESULT True"  "$(echo Y | probe | tail -1)"
verdict "交互答复 n：中止" \
    "RESULT False" "$(echo n | probe | tail -1)"
verdict "空答复（默认 N）：中止" \
    "RESULT False" "$(echo '' | probe | tail -1)"
verdict "非交互 /dev/null：中止（缺省往安全侧倒）" \
    "RESULT False" "$(probe < /dev/null | tail -1)"

rm -f "$SCRIPT_DIR/.minos_probe.py"

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
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    printf 'sha256:"%s"\nurl: "u"\n' "$(printf 'a%.0s' {1..64})" > "$WORK/_pkg@1.0"
    OUTPUT=$("$PYTHON" - "$BACKFILL" "$WORK/_pkg@1.0" <<'PYEOF'
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
    echo "SKIP: 未找到 $BACKFILL（infosource 与 MacWave 不在同一父目录）"
fi

FAILED=$((FAILED + HARD_FAIL))

echo
echo "=========================================="
echo -e "🌊 Passed: $PASSED"
echo -e "🌊 Failed: $FAILED"
echo "=========================================="

[[ "$FAILED" -eq 0 ]] || exit 1
echo -e "${GREEN}🌊 All min_os tests passed${RESET}"
