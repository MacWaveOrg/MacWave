#!/bin/bash

# selfupdate_test.sh
# selfupdate 回归：版本数据解析 → 已是最新时的短路 → 真实的端到端自更新
# 最后一步会真的按 configdata 的 update_command 把安装目录更新一遍，
# 所以放在 CI 的最后执行。

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

CONFIG_DIR="/opt/macwave_config"
CONFIG_FILE="$CONFIG_DIR/config.json"
VERSION_FILE="$CONFIG_DIR/VERSION.json"

if [[ ! -f "$CONFIG_FILE" || ! -f "$VERSION_FILE" ]]; then
    echo -e "${RED_BOLD}🌊 Error: MacWave not installed (config not found).${RESET}"
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

spec = importlib.util.spec_from_file_location('selfupdate_module', sys.argv[1])
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
# 3. 端到端自更新（真的会改动安装目录，放最后）
# ==========================================

echo "========== end-to-end selfupdate =========="

if ! bash -n "$SELFUPDATE_SH"; then
    echo -e "${RED_BOLD}🌊 FAIL: selfupdate.sh has a syntax error${RESET}"
    FAILED=$((FAILED + 1))
fi

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

if [[ "$RC" -ne 0 ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: selfupdate exited with $RC${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# VERSION.json 必须变成远端声明的版本号（这一步同时证明 selfupdate.sh 真的跑过）
if python3 - "$VERSION_FILE" << 'PYEOF'
import json
import re
import subprocess
import sys

url = "https://raw.githubusercontent.com/MacWaveOrg/MacWave/configdata/versiondata/latest_version"
result = subprocess.run(['curl', '-fsSL', '--max-time', '60', url], capture_output=True, text=True)
if result.returncode != 0:
    print(f'🌊 Error: cannot fetch the version data ({result.returncode})')
    sys.exit(1)

match = re.search(r'version:\s*"([^"]+)"', result.stdout)
if not match:
    print('🌊 Error: the version data has no version field')
    sys.exit(1)

expected = match.group(1)
with open(sys.argv[1], 'r') as handle:
    actual = json.load(handle).get('version')

if actual != expected:
    print(f'🌊 Error: VERSION.json is {actual}, expected {expected}')
    sys.exit(1)

print(f'🌊 VERSION.json updated to {actual}')
PYEOF
then
    echo -e "${GREEN}🌊 OK: end-to-end selfupdate${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: VERSION.json was not updated to the published version${RESET}"
    FAILED=$((FAILED + 1))
fi

# ==========================================
# 4. 清单里列出的文件必须都落到了安装目录
#    2.4 就是漏在这一点上：代码里加了 pkg/linker.py，
#    但 selfupdate.sh 自带的文件清单没同步，自更新后 wave link 直接 ImportError。
# ==========================================

echo "========== every listed file landed =========="

BASE_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['base_dir'])")

FILES_INFO_URL="https://raw.githubusercontent.com/MacWaveOrg/MacWave/configdata/versiondata/files_info"
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
# 5. wave.py 里每个命令都要有对应的模块文件
#    这一条独立于清单：即使清单漏写，只要 wave.py 引用了就会报出来
# ==========================================

echo "========== every command resolves to a module =========="

if python3 - "$BASE_DIR" << 'PYEOF'
import os
import re
import sys

base_dir = sys.argv[1]
with open(os.path.join(base_dir, 'lib', 'wave'), encoding='utf-8') as handle:
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
