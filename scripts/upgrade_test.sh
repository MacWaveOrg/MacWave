#!/bin/bash

# upgrade_test.sh
# `wave upgrade` 的回归测试。全程离线：
#   - 参数解析（--rov / --remove-old-version / 空格写法的 --max-time 不误当包名）
#   - --ver 与 pkg@version 被拒绝
#   - 单旧版本直接移除 / 多旧版本「全部移除」/ 多旧版本「挑选」
#   - 非交互时不动旧版本；不带 --rov 时旧版本全部保留
#
# 网络与安装流水线都用桩替掉：真正的下载由 random_test.sh 与 format_test.sh 覆盖，
# 这里要验的是「决定删哪些版本」这件事本身 —— 它最容易错，也最贵（删错了就丢数据）。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "$REPO_DIR/lib/wave.py" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found under $REPO_DIR${RESET}"
    exit 1
fi

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}🌊 PASS: $1${RESET}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"
    FAILED=$((FAILED + 1))
}

# check <描述> <实际> <期望>
check() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$3', got '$2')"
    fi
}

echo "========== 参数解析（离线） =========="

python3 - "$REPO_DIR" << 'PYEOF'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sys.path[:0] = [str(repo / "pkg"), str(repo / "surfboard"), str(repo / "lib")]

import upgrader
from pkginstaller import first_package_token, package_index

failures = []

# upgrade 专属旗标必须被剥掉，且不参与包名判断
# 四种写法必须完全等价
for command, expected in [
    ("wave upgrade jq", (["jq"], False, False)),
    ("wave upgrade jq --remove-old-version", (["jq"], True, False)),
    ("wave upgrade jq --remove-old-versions", (["jq"], True, False)),
    ("wave upgrade jq --rov", (["jq"], True, False)),
    ("wave upgrade jq -X", (["jq"], True, False)),
    ("wave upgrade -X jq", (["jq"], True, False)),
    # 短旗标簇里也要认：-Xv 等于 -X -v，-vX 同理
    ("wave upgrade jq -Xv", (["jq", "-v"], True, False)),
    ("wave upgrade jq -vX", (["jq", "-v"], True, False)),
    ("wave upgrade --max-time=1min jq --rov", (["--max-time=1min", "jq"], True, False)),
    ("wave upgrade --max-time 1min jq -X", (["--max-time", "1min", "jq"], True, False)),
    # --all：包名与它互斥，所以剥掉之后不该剩下任何包名
    ("wave upgrade --all", ([], False, True)),
    ("wave upgrade -a", ([], False, True)),
    ("wave upgrade -Xa", ([], True, True)),
    ("wave upgrade --all -X", ([], True, True)),
    # 簇里的 -a 也要认，其余字母保留
    ("wave upgrade -av", (["-v"], False, True)),
    ("wave upgrade -aXv", (["-v"], True, True)),
]:
    actual = upgrader.split_input(command)
    if actual != expected:
        failures.append(f"split_input({command!r}) -> {actual}, expected {expected}")

# 四种写法必须指向同一件事：剥掉旗标后剩下的词一模一样
variants = ["--remove-old-version", "--remove-old-versions", "--rov", "-X"]
stripped = {v: upgrader.split_input(f"wave upgrade jq {v}") for v in variants}
if len({tuple(item[0]) for item in stripped.values()}) != 1:
    failures.append(f"四种写法剥出的词不一致: {stripped}")
if not all(item[1] for item in stripped.values()):
    failures.append(f"有写法没能被识别成「移除旧版本」: {stripped}")

# --max-time 的空格写法：值不能被当成包名（install 与 upgrade 共用这一条）
for words, expected in [
    (["jq"], 0),
    (["--limit-rate", "1M", "jq"], 2),
    (["--max-time=1min", "jq"], 1),
    (["--max-time", "1min", "jq"], 2),
    (["--proxy", "http://127.0.0.1:8080", "jq"], 2),
    (["--skip-ssl"], None),
]:
    actual = package_index(words)
    if actual != expected:
        failures.append(f"package_index({words}) -> {actual}, expected {expected}")

for command, expected in [
    ("wave install --max-time 1min jq", "jq"),
    ("wave install jq --max-time 1min", "jq"),
]:
    actual = first_package_token(command)
    if actual != expected:
        failures.append(f"first_package_token({command!r}) -> {actual!r}, expected {expected!r}")

for message in failures:
    print(f"FAIL {message}")
sys.exit(1 if failures else 0)
PYEOF
if [[ $? -eq 0 ]]; then
    pass "upgrade 的旗标拆分与包名定位"
else
    fail "upgrade 的旗标拆分与包名定位"
fi

echo ""
echo "========== 决策与清理（桩掉网络） =========="

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ROOT="$WORK/root"
BASE="$WORK/macwave"
mkdir -p "$BASE/bin" "$BASE/links"
HOME_IN_ROOT="$ROOT$(printf '%s' "$HOME")"
mkdir -p "$HOME_IN_ROOT/.config/macwave_config"
printf '{"base_dir": "%s"}\n' "$BASE" > "$HOME_IN_ROOT/.config/macwave_config/config.json"
printf '{"version": "3.1.0"}\n' > "$HOME_IN_ROOT/.config/macwave_config/VERSION.json"

cat > "$WORK/harness.py" << PYEOF
import os, sys

os.environ["MACWAVE_TEST"] = "$ROOT"
sys.path[:0] = ["$REPO_DIR/pkg", "$REPO_DIR/surfboard", "$REPO_DIR/lib"]

import upgrader, pkginstaller
from configpaths import load_base_dir

BASE = load_base_dir()


def fake_install(command):
    name, version = [word for word in command.split() if "@" in word][0].split("@")
    target = BASE / "bin" / f"{name}@{version}"
    target.mkdir(parents=True, exist_ok=True)
    (target / name).write_text("#!/bin/sh\n")
    link = BASE / "links" / name
    if link.is_symlink():
        link.unlink()
    link.symlink_to(f"../bin/{name}@{version}/{name}")
    print(f"[stub install] {command}")


# 只桩掉 I/O：版本列表、@common、架构、真正的安装
pkginstaller.fetch_max_version = lambda name, arch, timeout=30: os.environ["STUB_LATEST"]
pkginstaller.fetch_common_fields = lambda name, arch, timeout=30: {"bin_name": [name]}
pkginstaller.detect_arch = lambda: "arm64"
pkginstaller.handle_install = fake_install
upgrader.handle_install = fake_install

# 批量模式靠 latest 的两件事：枚举已装包（读本地 bin/，不用桩）和名字清单（走网络）。
# 后者桩成 None，等价于「索引名字清单取不到」，此时 bin_name 就当包名用。
import latest
latest.fetch_names = lambda arch, timeout: None

try:
    upgrader.handle_upgrade(" ".join(["wave", "upgrade"] + sys.argv[1:]))
except SystemExit as exit_request:
    raise SystemExit(exit_request.code or 0)
PYEOF

# run_case <描述> "<已装版本，空格分隔>" "<upgrade 参数>" "<喂给 stdin 的内容>" "<期望留下的 bin 目录名>"
run_case() {
    local description="$1" installed="$2" arguments="$3" stdin_data="$4" expected="$5"

    rm -rf "${BASE:?}/bin" "${BASE:?}/links"
    mkdir -p "$BASE/bin" "$BASE/links"
    local version
    for version in $installed; do
        mkdir -p "$BASE/bin/jq@$version"
        printf '#!/bin/sh\n' > "$BASE/bin/jq@$version/jq"
    done

    local output
    output="$(printf '%s' "$stdin_data" | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
        python3 "$WORK/harness.py" $arguments 2>&1)" || true

    local actual
    actual="$(cd "$BASE/bin" && ls -1 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
    check "$description" "$actual" "$expected"

    if [[ "$actual" != "$expected" ]]; then
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
}

run_case "未安装时不清理任何东西" "" "jq --rov" "" "jq@1.7.1"
for flag in --remove-old-version --remove-old-versions --rov -X; do
    run_case "只有一个旧版本，用 $flag 移除" "1.6" "jq $flag" "" "jq@1.7.1"
done
run_case "多个旧版本答 Y：全部移除" "1.6 1.5 1.4" "jq --rov" "y
" "jq@1.7.1"
run_case "多个旧版本答 N 后挑第 1、3 个" "1.6 1.5 1.4" "jq --rov" "n
1 3
" "jq@1.5 jq@1.7.1"
run_case "非交互（读不到输入）：一个都不删" "1.6 1.5" "jq --rov" "" "jq@1.5 jq@1.6 jq@1.7.1"
run_case "不带 --rov：旧版本全部保留" "1.6 1.5" "jq" "" "jq@1.5 jq@1.6 jq@1.7.1"
run_case "已是最新：不重复下载" "1.7.1" "jq" "" "jq@1.7.1"
run_case "已是最新 + --rov：只清理旧版本" "1.7.1 1.6" "jq --rov" "" "jq@1.7.1"

echo ""
echo "========== 批量升级（--all） =========="

# run_all <描述> "<pkg@ver ...>" "<参数>" "<期望留下的 bin 目录>"
run_all() {
    local description="$1" installed="$2" arguments="$3" expected="$4"
    rm -rf "${BASE:?}/bin" "${BASE:?}/links"
    mkdir -p "$BASE/bin" "$BASE/links"
    local item name version
    for item in $installed; do
        name="${item%@*}"; version="${item#*@}"
        mkdir -p "$BASE/bin/$name@$version"
        printf '#!/bin/sh\n' > "$BASE/bin/$name@$version/$name"
    done

    LAST_OUTPUT="$(printf '' | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
        python3 "$WORK/harness.py" $arguments 2>&1)" || true

    local actual
    actual="$(cd "$BASE/bin" && ls -1 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
    check "$description" "$actual" "$expected"
    if [[ "$actual" != "$expected" ]]; then
        printf '%s\n' "$LAST_OUTPUT" | sed 's/^/    /'
    fi
}

run_all "两个包都升到最新（默认留旧版本）" "jq@1.6 curl@1.0" "--all" "curl@1.0 curl@1.7.1 jq@1.6 jq@1.7.1"
run_all "短写法 -a 等价于 --all" "jq@1.6 curl@1.0" "-a" "curl@1.0 curl@1.7.1 jq@1.6 jq@1.7.1"
run_all "默认保留旧版本" "jq@1.6 jq@1.5 curl@1.0" "--all" "curl@1.0 curl@1.7.1 jq@1.5 jq@1.6 jq@1.7.1"
run_all "带 -X 时每个包都清掉旧版本（多个旧版本也不再逐个问）" "jq@1.6 jq@1.5 curl@1.0" "--all -X" "curl@1.7.1 jq@1.7.1"
run_all "簇写 -aX 等价" "jq@1.6 curl@1.0" "-aX" "curl@1.7.1 jq@1.7.1"
run_all "已是最新的包不动" "jq@1.7.1 curl@1.0" "--all" "curl@1.0 curl@1.7.1 jq@1.7.1"

if grep -q '1 upgraded, 1 already at the latest' <<< "$LAST_OUTPUT"; then
    pass "批量结束有汇总"
else
    fail "批量结束应有汇总（实际：$(head -1 <<< "$LAST_OUTPUT")）"
fi

# 包名与 --all 互斥：不能让人以为「--all 加个名字」是「只升这个」
run_all "--all 与包名同时给：拒绝" "jq@1.6" "--all jq" "jq@1.6"
if grep -q 'drop the package name' <<< "$LAST_OUTPUT"; then
    pass "--all 与包名冲突时给出原因"
else
    fail "--all 与包名冲突时应说明二者只能选一个"
fi

# 一个包失败不能拖累其余的：curl 在索引里不存在时，jq 仍要被升级
rm -rf "${BASE:?}/bin" "${BASE:?}/links"; mkdir -p "$BASE/bin" "$BASE/links"
mkdir -p "$BASE/bin/jq@1.6" "$BASE/bin/zzz@1.0"
printf '#!/bin/sh\n' > "$BASE/bin/jq@1.6/jq"
printf '#!/bin/sh\n' > "$BASE/bin/zzz@1.0/zzz"
cat > "$WORK/fail_one.py" <<'PYEOF2'
import os, sys
os.environ["MACWAVE_TEST"] = os.environ["TEST_ROOT"]
sys.path[:0] = [os.environ["PKG"], os.environ["SURF"], os.environ["LIB"]]
import upgrader, pkginstaller, latest


def fake_install(command):
    name, version = [w for w in command.split() if "@" in w][0].split("@")
    target = (pkginstaller.BASE_DIR / "bin" / f"{name}@{version}")
    target.mkdir(parents=True, exist_ok=True)
    (target / name).write_text("#!/bin/sh\n")


def fake_max(name, arch, timeout=30):
    if name == "zzz":
        raise SystemExit(1)
    return "1.7.1"


pkginstaller.fetch_max_version = fake_max
pkginstaller.fetch_common_fields = lambda n, a, timeout=30: {"bin_name": [n]}
pkginstaller.detect_arch = lambda: "arm64"
pkginstaller.handle_install = fake_install
upgrader.handle_install = fake_install
latest.fetch_names = lambda arch, timeout: None

try:
    upgrader.handle_upgrade("wave upgrade --all")
except SystemExit as request:
    raise SystemExit(request.code or 0)
PYEOF2
TEST_ROOT="$ROOT" PKG="$REPO_DIR/pkg" SURF="$REPO_DIR/surfboard" LIB="$REPO_DIR/lib" \
    python3 "$WORK/fail_one.py" > "$WORK/fail_one.log" 2>&1 && FAIL_ONE_RC=0 || FAIL_ONE_RC=$?
check "一个包失败，其余的照常升级" \
    "$(cd "$BASE/bin" && ls -1 | sort | tr '\n' ' ' | sed 's/ $//')" "jq@1.6 jq@1.7.1 zzz@1.0"
if [[ "$FAIL_ONE_RC" -ne 0 ]]; then
    pass "有包失败时退出码非零"
else
    fail "有包失败时退出码应为非零"
fi
if grep -q 'could not upgrade zzz' "$WORK/fail_one.log"; then
    pass "收尾点名失败的包"
else
    fail "收尾应点名哪个包失败"
    sed 's/^/    /' "$WORK/fail_one.log"
fi

echo ""
echo "========== 拒绝与链接 =========="

# pkg@version 与 --ver 都必须被拒绝，而不是悄悄降级成 install
if printf '' | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
    python3 "$WORK/harness.py" jq@1.5 2>&1 | grep -q 'always targets the latest version'; then
    pass "wave upgrade jq@1.5 被拒绝"
else
    fail "wave upgrade jq@1.5 应当被拒绝"
fi

if printf '' | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
    python3 "$WORK/harness.py" jq --ver 1.5 2>&1 | grep -q 'is not accepted by upgrade'; then
    pass "wave upgrade --ver 被拒绝"
else
    fail "wave upgrade --ver 应当被拒绝"
fi

if printf '' | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
    python3 "$WORK/harness.py" jq --unlink 2>&1 | grep -q 'is not accepted by upgrade'; then
    pass "wave upgrade --unlink 被拒绝"
else
    fail "wave upgrade --unlink 应当被拒绝"
fi

# 索引落后于本机时不能降级
rm -rf "${BASE:?}/bin" "${BASE:?}/links"; mkdir -p "$BASE/bin" "$BASE/links"
mkdir -p "$BASE/bin/jq@1.9"; printf '#!/bin/sh\n' > "$BASE/bin/jq@1.9/jq"
printf '' | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
    python3 "$WORK/harness.py" jq --rov > "$WORK/behind.log" 2>&1 || true
check "索引落后于本机：不降级" "$(cd "$BASE/bin" && ls -1 | tr '\n' ' ' | sed 's/ $//')" "jq@1.9"
if grep -q 'nothing was downloaded' "$WORK/behind.log"; then
    pass "索引落后时提示「什么都没下载」"
else
    fail "索引落后时应说明没有下载任何东西"
    sed 's/^/    /' "$WORK/behind.log"
fi

# 升级后不带版本号的链接必须指向新版本
rm -rf "${BASE:?}/bin" "${BASE:?}/links"; mkdir -p "$BASE/bin" "$BASE/links"
mkdir -p "$BASE/bin/jq@1.6"; printf '#!/bin/sh\n' > "$BASE/bin/jq@1.6/jq"
printf '' | STUB_LATEST=1.7.1 MACWAVE_TEST="$ROOT" \
    python3 "$WORK/harness.py" jq > /dev/null 2>&1 || true
check "链接指向刚升级到的版本" "$(readlink "$BASE/links/jq" 2>/dev/null)" "../bin/jq@1.7.1/jq"

echo ""
echo "=========================================="
echo -e "${GREEN}🌊 Passed: $PASSED / $((PASSED + FAILED))${RESET}"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 Failed: $FAILED / $((PASSED + FAILED))${RESET}"
    exit 1
fi

echo -e "${GREEN}🌊 All upgrade tests passed.${RESET}"
