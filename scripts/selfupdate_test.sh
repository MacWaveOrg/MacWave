#!/bin/bash

# selfupdate_test.sh
# selfupdate 回归：版本数据解析 → 已是最新时的短路 → 跨大版本被拒绝 → 同大版本的端到端自更新
# 最后一步会真的把安装目录更新一遍，所以放在 CI 的最后执行。

set -e

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_BIN="$REPO_DIR/lib/wave.py"
SELFUPDATE_PY="$REPO_DIR/lib/selfupdate.py"
SELFUPDATE_SH="$REPO_DIR/lib/selfupdate.sh"

if [[ ! -f "$WAVE_BIN" ]]; then
    echo -e "${RED_BOLD}🌊 Error: wave.py not found at $WAVE_BIN${RESET}"
    exit 1
fi

# 配置目录：系统级优先，其次用户级
if [[ -f /opt/macwave_config/config.json ]]; then
    CONFIG_DIR="/opt/macwave_config"
elif [[ -f "$HOME/.config/macwave_config/config.json" ]]; then
    CONFIG_DIR="$HOME/.config/macwave_config"
else
    echo -e "${RED_BOLD}🌊 Error: MacWave not installed (config not found).${RESET}"
    exit 1
fi

CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: MacWave not installed (VERSION.json not found).${RESET}"
    exit 1
fi

FAILED=0

# ==========================================
# 1. 版本数据解析与版本比较（离线，不碰网络）
# ==========================================

echo "========== parse version data =========="

if python3 - "$SELFUPDATE_PY" << 'PYEOF'
import importlib.util
import sys
from pathlib import Path

selfupdate_py = Path(sys.argv[1])
sys.path.insert(0, str(selfupdate_py.parent))   # selfupdate.py 会 import configpaths
spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# 单行命令
single = (
    'version: "9.9.9"\n'
    'release_date: "2026-01-01"\n'
    'build_number: "X1"\n'
    'branch: "main"\n'
    'update_command: <<< echo hello >>>\n'
)
data = module.parse_version_data(single)
assert data['version'] == '9.9.9', data
assert data['branch'] == 'main', data
assert data['release_date'] == '2026-01-01', data
assert data['update_command'] == 'echo hello', data

# 多行命令（<<< >>> 之间可以换行，且不能被当成字段）
multi = 'version: "1.0"\nupdate_command: <<<\necho one: two\necho three\n>>>\n'
parsed = module.parse_version_data(multi)
assert parsed['version'] == '1.0', parsed
assert parsed['update_command'] == 'echo one: two\necho three', parsed

# 版本比较：补齐到四位，2.3 == 2.3.0，跨位数按数值比
assert module.version_key('2.3') == module.version_key('2.3.0')
assert module.version_key('2.2.0') < module.version_key('2.3')
assert module.version_key('2.10.0') > module.version_key('2.9.0')
assert module.version_key('2.3') >= module.version_key('2.3')

print('🌊 Parsing and version comparison OK')
PYEOF
then
    echo -e "${GREEN}🌊 OK: parse version data${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: parse version data${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 2. 已是最新时必须短路（不会去执行 update_command）
# ==========================================

echo "========== already up to date =========="

python3 - "$VERSION_FILE" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": "9999.0", "components": {"installer": "9999.0", "parser": "9999.0"}},
              handle, indent=2)
PYEOF

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -eq 0 ]] && grep -q 'already up to date' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: reports up to date${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected an up-to-date short circuit (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# ==========================================
# 3. 跨大版本必须被拒绝（3.0 起的新规则）
# ==========================================

echo "========== cross-major selfupdate is refused =========="

python3 - "$VERSION_FILE" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": "0.1", "components": {"installer": "0.1", "parser": "0.1"}},
              handle, indent=2)
PYEOF

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -ne 0 ]] && grep -q 'cannot cross major versions' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: cross-major selfupdate refused${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected a cross-major refusal (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

if [[ "$(python3 -c "import json; print(json.load(open('$VERSION_FILE'))['version'])")" == "0.1" ]]; then
    echo -e "${GREEN}🌊 OK: VERSION.json untouched after the refusal${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: VERSION.json changed despite the refusal${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 4. --max-time：时长时间解析与下载重试（离线，不碰网络）
# ==========================================

echo "========== max-time duration parsing =========="

if python3 - "$SELFUPDATE_PY" "$SELFUPDATE_SH" << 'PYEOF'
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

selfupdate_py, selfupdate_sh = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(selfupdate_py.parent))
sys.path.insert(0, str(selfupdate_py.parent.parent / "pkg"))         # pkginstaller（共用时长规则）
sys.path.insert(0, str(selfupdate_py.parent.parent / "surfboard"))  # pkginstaller 会连带 import 它

spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# Python 侧：合法的原样留下，非法的当场拒绝
assert module.max_time("wave selfupdate --max-time=1min") == ("1min", 60), module.max_time("wave selfupdate --max-time=1min")
assert module.max_time("wave selfupdate --max-time 1min20s") == ("1min20s", 80)
assert module.max_time("wave selfupdate")[0] == ""
for bad in ("abc", "1x", "-5"):
    try:
        module.max_time(f"wave selfupdate --max-time={bad}")
    except SystemExit:
        pass
    else:
        raise AssertionError(f"--max-time={bad} 本应被拒绝")

# shell 侧：规则必须与 Python 一致（否则同一条命令两层会算出不同超时）
script = r'''
source /dev/stdin <<< "$(sed -n "/^mw_seconds()/,/^}/p" "$1")"
shift
for value in "$@"; do
    if out="$(mw_seconds "$value")"; then printf "%s\n" "$out"; else printf "REJECT\n"; fi
done
'''
cases = ["40", "0.5h", "1h", "1hr", "2hrs", "1.5h", "1h20s", "2h30min", "40s", "1min", "1min20s",
         "1m30s", "2h", "250ms", "1.5min", "abc", "1x", "min", "h", "1hh", "0"]
result = subprocess.run(["bash", "-c", script, "_", str(selfupdate_sh)] + cases,
                        capture_output=True, text=True)
assert result.returncode == 0, result.stderr
got = result.stdout.split()
assert len(got) == len(cases), result.stdout
invalid = ("abc", "1x", "min", "h", "1hh", "0")
for value, shell_value in zip(cases, got):
    if value in invalid:
        assert shell_value == "REJECT", f"{value}: shell 本应拒绝，实际 {shell_value}"
        continue
    raw, seconds = module.max_time(f"wave selfupdate --max-time={value}")
    assert raw == value, f"{value}: 原始文本应原样往下传，实际 {raw!r}"
    expected = str(module.curl_seconds(seconds))
    assert shell_value == expected, f"{value}: shell={shell_value} python={expected}"
PYEOF
then
    echo -e "${GREEN}🌊 OK: --max-time parses identically in Python and in shell${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: --max-time duration parsing${RESET}"
    FAILED=$((FAILED + 1))
fi

echo "========== downloads retry and never leave half a file =========="

if bash -s -- "$SELFUPDATE_SH" << 'SHEOF'
set -u

source_file="$1"
helper="$(mktemp)"
trap 'rm -f "$helper"' EXIT

{
    echo 'NEED_SUDO=false'
    echo 'YELLOW=""; RESET=""; RED_BOLD=""'
    sed -n '/^run_cmd() {/,/^}/p' "$source_file"
    sed -n '/^direct() {/,/^}/p' "$source_file"
    sed -n '/^FETCH_ATTEMPTS=/,/^RETRY_DELAY=/p' "$source_file"
    sed -n '/^fetch_to_file() {/,/^}/p' "$source_file"
} > "$helper"
# shellcheck disable=SC1090
source "$helper"

work="$(mktemp -d)"
trap 'rm -f "$helper"; rm -rf "$work"' EXIT

# 成功路径：落地成目标文件，不留下 .macwave-part
if ! fetch_to_file "file://$source_file" "$work/ok.sh" 5; then
    echo "  ❌ 本地文件下载失败"
    exit 1
fi
[[ -s "$work/ok.sh" ]] || { echo "  ❌ 目标文件为空"; exit 1; }
[[ -z "$(find "$work" -name '*.macwave-part' -print -quit)" ]] || { echo "  ❌ 残留 .macwave-part"; exit 1; }

# 失败路径：本地没有这个文件，重试用尽后放弃，且不能破坏原地已有的好文件
echo "GOOD" > "$work/keep.sh"
if fetch_to_file "file://$work/nope/none.sh" "$work/keep.sh" 5 >/dev/null 2>&1; then
    echo "  ❌ 不存在的文件竟然下载成功"
    exit 1
fi
[[ "$(cat "$work/keep.sh")" == "GOOD" ]] || { echo "  ❌ 失败时破坏了原文件"; exit 1; }
[[ -z "$(find "$work" -name '*.macwave-part' -print -quit)" ]] || { echo "  ❌ 失败后残留 .macwave-part"; exit 1; }
SHEOF
then
    echo -e "${GREEN}🌊 OK: downloads retry, stay atomic, and give up cleanly${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: download retry / atomic write${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 5. 自带解释器：两份脚本的布局归一化必须一致，且能真的定位到解释器
# ==========================================

echo "========== portable Python layout =========="

if bash -s -- "$REPO_DIR" << 'SHEOF'
set -u
repo="$1"

# sudo 无法执行 shell 函数。write_launcher 一旦被 run_cmd 带上去，
# 只要安装目录不在 $HOME 下就会变成 "sudo: write_launcher: command not found"，
# 而 CI 里恰好就是那种布局 —— 这条断言比等 CI 跑十分钟便宜得多。
if grep -qE '^[[:space:]]*run_cmd write_launcher' "$repo/lib/install.sh" "$repo/lib/selfupdate.sh"; then
    echo "  ❌ write_launcher 被 run_cmd 调用（sudo 无法执行 shell 函数）"
    exit 1
fi
echo "  ✅ write_launcher 直接调用，没有经过 run_cmd"

# 测试根的 HOME 重写必须是幂等的。lib/configpaths.py 会先把 HOME 搬进测试根，
# 若 shell 脚本再无条件套一层，HOME 会变成 "<根>/private/var/.../Users/<你>"，
# 配置目录永远找不到 —— 这正是「用 MACWAVE_TEST 跑真实 selfupdate」失败的原因。
work_home="$(mktemp -d)"
for source_file in "$repo/lib/install.sh" "$repo/lib/selfupdate.sh"; do
    block="$(sed -n '/^SYS_ROOT=""/,/^fi$/p' "$source_file")"
    # 第一遍：HOME 在外面，应当被搬进测试根
    first="$(MACWAVE_TEST="$work_home" HOME=/Users/example bash -c "$block"$'\nprintf %s "$HOME"' 2>/dev/null | tail -1)"
    case "$first" in
        "$work_home"*) : ;;
        *) echo "  ❌ $(basename "$source_file"): HOME 没有被搬进测试根（$first）"; exit 1 ;;
    esac
    # 第二遍：HOME 已经在测试根里，不能再套一层
    second="$(MACWAVE_TEST="$work_home" HOME="$first" bash -c "$block"$'\nprintf %s "$HOME"' 2>/dev/null | tail -1)"
    if [ "$second" != "$first" ]; then
        echo "  ❌ $(basename "$source_file"): HOME 被重复前缀（$first -> $second）"
        exit 1
    fi
done
rm -rf "$work_home"
echo "  ✅ 测试根的 HOME 重写是幂等的"

# install.sh 与 selfupdate.sh 各带一份同名实现（谁都不能依赖对方已下载），
# 一旦漂移就会出现「装的时候行、自更新以后不行」。这里逐字比对。
extract() {
    sed -n '/^portable_python_arch() {/,/^}/p;/^portable_python_binary() {/,/^}/p;/^normalize_portable_python() {/,/^}/p' "$1"
}
if ! diff <(extract "$repo/lib/install.sh") <(extract "$repo/lib/selfupdate.sh") > /dev/null; then
    echo "  ❌ install.sh 与 selfupdate.sh 的便携 Python 逻辑不一致"
    exit 1
fi
echo "  ✅ 两份脚本的探测与归一化逻辑逐字一致"

# 上游 install_only 的布局是 python/install/bin/python3，而启动器只认
# python/current/bin/python3 —— 归一化就是这条断点的桥。
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/target/python/install/bin"
ln -s "$(command -v python3)" "$work/target/python/install/bin/python3"

eval "$(extract "$repo/lib/install.sh")"
target="$work/target"
py="$(portable_python_binary "$target")" || { echo "  ❌ 探测不到解释器"; exit 1; }
case "$py" in
    "$target/python/install/bin/python3") : ;;
    *) echo "  ❌ 探测结果不对: $py"; exit 1 ;;
esac

normalize_portable_python "$target" "$py"
ln -sfn target "$work/current"
if [ ! -x "$work/current/bin/python3" ]; then
    echo "  ❌ 归一化后启动器路径仍不可用"
    exit 1
fi
echo "  ✅ 归一化后 python/current/bin/python3 可用"

# 重复归一化不能把链接变成自我循环（portable_python_binary 会把 bin/python3 也报出来）
py2="$(portable_python_binary "$target")"
normalize_portable_python "$target" "$py2"
if [ "$(readlink "$target/bin/python3")" = "bin/python3" ]; then
    echo "  ❌ 归一化出现自我循环"
    exit 1
fi
echo "  ✅ 重复归一化仍指向真实解释器"
SHEOF
then
    echo -e "${GREEN}🌊 OK: the bundled interpreter is found and the launcher path works${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: portable Python layout${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 6. 同大版本的端到端自更新（真的会改动安装目录，放最后）
# ==========================================

echo "========== end-to-end selfupdate =========="

if ! bash -n "$SELFUPDATE_SH"; then
    echo -e "${RED_BOLD}🌊 FAIL: selfupdate.sh has a syntax error${RESET}"
    FAILED=$((FAILED + 1))
fi

# 线上版本形如 x.0 时，「同大版本且更旧」的版本并不存在（x.0 已是该大版本的最低版本），
# 所以这里直接给 selfupdate.sh 指定一个同大版本、更高的目标版本号，走完真实的更新流程
# （读文件清单 → 下载文件 → 写 VERSION.json）。
PUBLISHED="$(curl -fsSL --max-time 60 "https://raw.githubusercontent.com/MacWaveOrg/configdata/main/versiondata/latest_version" \
    | sed -n 's/^version:[[:space:]]*"\(.*\)"/\1/p' | head -n 1)"

if [[ -z "$PUBLISHED" ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: cannot read the published version${RESET}"
    FAILED=$((FAILED + 1))
else
    INSTALLED="$PUBLISHED"
    TARGET="$(python3 -c 'import sys; parts = sys.argv[1].split("."); parts[-1] = str(int(parts[-1]) + 1); print(".".join(parts))' "$PUBLISHED")"

    python3 - "$VERSION_FILE" "$INSTALLED" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": sys.argv[2], "components": {"installer": sys.argv[2], "parser": sys.argv[2]}},
              handle, indent=2)
PYEOF

    LOG_FILE="$(mktemp)"
    RC=0
    MACWAVE_UPDATE_VERSION="$TARGET" MACWAVE_UPDATE_BRANCH=main bash "$SELFUPDATE_SH" > "$LOG_FILE" 2>&1 || RC=$?
    cat "$LOG_FILE"

    if [[ "$RC" -ne 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: selfupdate.sh exited with $RC${RESET}"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$LOG_FILE"

    # VERSION.json 必须变成目标版本号（这一步同时证明 selfupdate.sh 真的跑过）
    if [[ "$(python3 -c "import json; print(json.load(open('$VERSION_FILE'))['version'])")" == "$TARGET" ]]; then
        echo -e "${GREEN}🌊 OK: end-to-end selfupdate ($INSTALLED -> $TARGET)${RESET}"
    else
        echo -e "${RED_BOLD}🌊 FAIL: VERSION.json was not updated to $TARGET${RESET}"
        FAILED=$((FAILED + 1))
    fi
fi

# ==========================================
# 7. 清单里列出的文件必须都落到了安装目录
#    2.4 就是漏在这一点上：代码里加了 pkg/linker.py，
#    但 selfupdate.sh 自带的文件清单没同步，自更新后 wave link 直接 ImportError。
# ==========================================

echo "========== every listed file landed =========="

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")

FILES_INFO_URL="https://raw.githubusercontent.com/MacWaveOrg/configdata/main/versiondata/files_info"
FILES_INFO_TMP="$(mktemp)"
PARSER_TMP="$(mktemp)"

if ! curl -fsSL --max-time 60 -o "$FILES_INFO_TMP" "$FILES_INFO_URL"; then
    echo -e "${RED_BOLD}🌊 FAIL: cannot fetch versiondata/files_info${RESET}"
    FAILED=$((FAILED + 1))
else
    # 抽出 selfupdate.sh 里真正的解析器，保证测的是实现本身而不是另一份复制品
    sed -n '/^parse_files_info() {/,/^}$/p' "$SELFUPDATE_SH" > "$PARSER_TMP"

    FILE_COUNT=0
    MISSING=0
    while IFS=$'\t' read -r repo_path local_path executable; do
        if [[ -z "$repo_path" ]]; then
            continue
        fi
        FILE_COUNT=$((FILE_COUNT + 1))
        if [[ ! -e "$BASE_DIR/$local_path" ]]; then
            echo -e "${RED_BOLD}🌊 FAIL: $repo_path was not installed to $local_path${RESET}"
            MISSING=$((MISSING + 1))
        fi
    done < <(bash -c "source '$PARSER_TMP'; parse_files_info '$FILES_INFO_TMP'")

    if [[ "$FILE_COUNT" -eq 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: the file list parsed to nothing${RESET}"
        FAILED=$((FAILED + 1))
    elif [[ "$MISSING" -gt 0 ]]; then
        echo -e "${RED_BOLD}🌊 FAIL: $MISSING of $FILE_COUNT listed file(s) are missing${RESET}"
        FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}🌊 OK: all $FILE_COUNT listed file(s) landed${RESET}"
    fi
fi

rm -f "$FILES_INFO_TMP" "$PARSER_TMP"

# ==========================================
# 8. wave.py 里每个命令都要有对应的模块文件
#    这一条独立于清单：即使清单漏写，只要 wave.py 引用了就会报出来
# ==========================================

echo "========== every command resolves to a module =========="

if python3 - "$BASE_DIR" << 'PYEOF'
import os
import re
import sys

base_dir = sys.argv[1]
with open(os.path.join(base_dir, 'lib', 'wave.py'), encoding='utf-8') as handle:
    source = handle.read()

block = source.split('COMMANDS = {', 1)[1].split('}', 1)[0]
commands = re.findall(r'"(\w+)"\s*:\s*"(\w+)"', block)
if not commands:
    print('🌊 Error: could not read any entry from COMMANDS')
    sys.exit(1)

missing = []
for command, module in commands:
    if not any(os.path.exists(os.path.join(base_dir, folder, module + '.py'))
               for folder in ('lib', 'pkg', 'surfboard')):
        missing.append(f'{command} -> {module}.py')

if missing:
    print('🌊 Error: these commands have no module file: ' + ', '.join(missing))
    sys.exit(1)

print(f'🌊 All {len(commands)} command(s) resolve to a module file')
PYEOF
then
    echo -e "${GREEN}🌊 OK: every command module exists${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: a command module is missing after selfupdate${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 汇总
# ==========================================

echo ""
echo "=========================================="
if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED_BOLD}🌊 selfupdate tests failed: $FAILED${RESET}"
    echo "=========================================="
    exit 1
fi

echo -e "${GREEN}🌊 All selfupdate tests passed.${RESET}"
echo "=========================================="
exit 0
