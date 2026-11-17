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
source "$SCRIPT_DIR/components.sh"
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
# 0. 本地自更新数据（下面 2、3、6、7 四段都靠它，全程离线）
# ==========================================
#
# 4.0 起的自更新数据只有两样东西，按版本平铺：
#   macwavedata/latest.toml                  哪个版本是最新的
#   macwavedata/<版本>/update_commands.sh    那一版下什么、放哪里
# 这里在临时目录里造一份同大版本、比 4.0.0 高一档的数据，用 file:// 指给客户端。
# 这样测试既离线、又不依赖线上已发布的版本号（线上换版本不会让这里变红）。

SU_WORK="$(mktemp -d)"
trap 'rm -rf "$SU_WORK"' EXIT

SU_VERSION="4.0.1"
SU_BRANCH="4.0"
mkdir -p "$SU_WORK/selfupdate/macwavedata/$SU_VERSION" "$SU_WORK/core"

cat > "$SU_WORK/selfupdate/macwavedata/latest.toml" <<EOF
version = "$SU_VERSION"
release_date = "2026-01-01"
build_number = "TEST"
branch = "$SU_BRANCH"
EOF

# 代码树：<core>/<branch>/<路径>，用软链接指回仓库，省一次复制
ln -s "$REPO_DIR" "$SU_WORK/core/$SU_BRANCH"

# 用仓库自己的生成器产出这一版的 update_commands.sh。清单取自工作区实际文件，
# 而不是 --ref HEAD：本地 HEAD 可能落后于工作区，那样会漏掉新加的文件。
SU_FILES=()
for dir in $(sed -e 's/#.*//' "$SCRIPT_DIR/components.txt") \
           $(sed -e 's/#.*//' "$SCRIPT_DIR/assets.txt"); do
    for file in "$REPO_DIR/$dir"/*; do
        [[ -f "$file" ]] || continue
        rel="$dir/$(basename "$file")"
        case "$rel" in
            lib/wave|lib/install.sh|lib/uninstall.sh) continue ;;
        esac
        SU_FILES+=("$rel")
    done
done

python3 "$SCRIPT_DIR/build_update_commands.py" \
    --version "$SU_VERSION" \
    --branch "$SU_BRANCH" \
    --files "${SU_FILES[@]}" \
    --out "$SU_WORK/selfupdate/macwavedata/$SU_VERSION/update_commands.sh" > /dev/null

export MACWAVE_SELFUPDATE_DOMAIN="file://$SU_WORK/selfupdate"
export MACWAVE_CORE_DOMAIN="file://$SU_WORK/core"
# 解释器数据不存在时安装器会警告并回退到系统 python3，安装不中断
export MACWAVE_PYTHON_DOMAIN="file://$SU_WORK/python"

# ==========================================
# 1. 版本数据解析与版本比较（离线，不碰网络）
# ==========================================

echo "========== parse version data =========="

if python3 - "$SELFUPDATE_PY" << 'PYEOF'
import importlib.util
import os
import sys
from pathlib import Path

selfupdate_py = Path(sys.argv[1])
# selfupdate.py 会 import configpaths（lib/）与 domains/tls（net/），两处都要在路径上。
sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep) + [str(selfupdate_py.parent)]
spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# 4.0 的版本数据是 TOML（macwavedata/latest.toml）。3.x 的「冒号 + <<< >>> 命令块」
# 随 files_info 一起退休了，所以这里只校验 key = "value" 这一种形态。
single = (
    'version = "9.9.9"\n'
    'release_date = "2026-01-01"\n'
    'build_number = "X1"\n'
    'branch = "main"\n'
)
data = module.version_data(single)
assert data['version'] == '9.9.9', data
assert data['branch'] == 'main', data
assert data['release_date'] == '2026-01-01', data
assert data['build_number'] == 'X1', data

# 线上文件带注释：注释里的「version =」不能被当成字段
commented = (
    '# version = "should-not-win"\n'
    '# 说明文字\n'
    'version = "1.0"\n'
)
parsed = module.version_data(commented)
assert parsed['version'] == '1.0', parsed

# 解析器是**故意宽松**的：认不出的行直接跳过，不报错。
# 这样有人在数据文件里留了说明、或以后加了新字段，旧客户端仍能读到 version，
# 而不是整个自更新停摆。坏处是拼错也不会被告知，所以这里把行为钉住：
lenient = module.version_data('version "1.0"\nversion = "2.0"\nunknown-key = "x"\n')
assert lenient['version'] == '2.0', lenient
assert lenient['unknown-key'] == 'x', lenient

# 版本比较：PEP 440（packaging），见 lib/versioncmp.py
assert module.version_key('2.3') == module.version_key('2.3.0')
assert module.version_key('2.2.0') < module.version_key('2.3')
assert module.version_key('2.10.0') > module.version_key('2.9.0')
assert module.version_key('2.3') >= module.version_key('2.3')

# 预发布必须排在正式版**之前**。这一条是必须钉死的：以前按数字段比较，
# 4.4.0-beta1 被读成 [4,4,0,1]，比 4.4.0 的 [4,4,0,0] 大 —— 装过 beta 的人
# 就永远等不到正式版，而平时没有预发布版本时怎么测都看不出来。
assert module.version_key('4.4.0-beta1') < module.version_key('4.4.0'), 'beta 必须小于正式版'
assert module.version_key('4.4.0b1') < module.version_key('4.4.0')
assert module.version_key('4.4.0rc1') < module.version_key('4.4.0')
assert module.version_key('4.4.0a1') < module.version_key('4.4.0b1')
assert module.version_key('4.4.0.dev1') < module.version_key('4.4.0a1')
assert module.version_key('4.4.0') < module.version_key('4.4.1')
# 装着的正式版比「最新」还新时不应降级
assert module.version_key('4.4.0') > module.version_key('4.4.0-beta1')

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

# 4.0 的守卫措辞已改为「is a new major version, so it cannot be installed with selfupdate」
if [[ "$RC" -ne 0 ]] && grep -q 'cannot be installed with selfupdate' "$LOG_FILE"; then
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
# 3.5 beta 版不许 selfupdate（Python 与 shell 两条入口都要拦）
# ==========================================
#
# beta 与正式版在不同分支上，selfupdate 的增量按 latest.toml 里那条正式版分支算 ——
# 盖到一棵 beta 树上就是两条线混在一起（2026-11-15 那次 wave 启动即崩的成因）。
# 两条入口分别验：wave selfupdate 走 selfupdate.py，直接 bash 走 selfupdate.sh。
#
# 全程离线：python 那条在联网之前就退出；shell 那条用 MACWAVE_UPDATE_VERSION
# 跳过取 latest.toml。两条都不该改动 VERSION.json。

echo "========== beta builds cannot selfupdate =========="

BETA_VERSION="4.4.0-beta2"
cp "$VERSION_FILE" "$SU_WORK/VERSION.json.bak"
python3 - "$VERSION_FILE" "$BETA_VERSION" << 'PYEOF'
import json
import sys

path, beta = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
data["version"] = beta
with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
PYEOF

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -ne 0 ]] && grep -q 'is a beta build' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: wave selfupdate refuses a beta${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected wave selfupdate to refuse a beta (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi

# 必须在联网之前就退出 —— 否则用户先看到 "Fetching the latest version..."，
# 以为在正常推进，然后才被拒绝。
if grep -q 'Fetching the latest version' "$LOG_FILE"; then
    echo -e "${RED_BOLD}🌊 FAIL: the refusal happened after contacting the network${RESET}"
    FAILED=$((FAILED + 1))
else
    echo -e "${GREEN}🌊 OK: refused before any network request${RESET}"
fi

# 拒绝必须把话说全：为什么、去哪装、以及装了什么命令。用户在 beta 上被拦住，
# 唯一出路就是重装，命令不能让他自己去找。
if grep -q 'install.sh' "$LOG_FILE" && grep -q "releases/tag/v$BETA_VERSION" "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: the refusal names the reinstall command and the Release page${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: the refusal does not say how to install${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# shell 那条入口：直接执行 lib/selfupdate.sh（文件头写着这条路，3.x 的
# update_command 也走它）。MACWAVE_UPDATE_VERSION 让它跳过取 latest.toml，
# 于是这一段不碰网络。
LOG_FILE="$(mktemp)"
RC=0
MACWAVE_UPDATE_VERSION=4.0.1 MACWAVE_UPDATE_BRANCH=4.0 \
    /bin/bash "$SELFUPDATE_SH" > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -ne 0 ]] && grep -q 'is a beta build' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: lib/selfupdate.sh refuses a beta too${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: lib/selfupdate.sh did not refuse a beta (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

if [[ "$(python3 -c "import json; print(json.load(open('$VERSION_FILE'))['version'])")" == "$BETA_VERSION" ]]; then
    echo -e "${GREEN}🌊 OK: VERSION.json untouched by both refusals${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: a refusal changed VERSION.json${RESET}"
    FAILED=$((FAILED + 1))
fi

cp "$SU_WORK/VERSION.json.bak" "$VERSION_FILE"

# ==========================================
# 3.6 协议更新：装的是 4.4.0 或更早时必须问一次
# ==========================================
#
# 协议正文改在 2026-11-17（随 4.4.0），官网那节的落款就是这个日期。装得更早的人
# 同意的是旧文本，所以升级前要问一句；不同意就中止，保持他现有的版本 —— 这正是
# 协议第 2 条给的选项（放弃更新 / 继续用已同意的那一版）。
#
# 判定不需要网络，但**这条提示排在「确实要更新」之后**，所以这里把已装版本设成 4.0.0
# （本地自更新数据里是 4.0.1）—— 比它低才走得下去，否则会先撞上「已是最新」的短路。

echo "========== the updated agreement must be accepted =========="

AGREEMENT_RECORD="$CONFIG_DIR/AGREEMENT.json"
cp "$VERSION_FILE" "$SU_WORK/VERSION.json.agr"
if [[ -f "$AGREEMENT_RECORD" ]]; then
    cp "$AGREEMENT_RECORD" "$SU_WORK/AGREEMENT.json.bak"
    HAD_AGREEMENT=1
else
    HAD_AGREEMENT=0
fi

# 判定函数本身：一张表钉死「什么时候该问」。比跑端到端快，也更容易看懂。
if python3 - "$SELFUPDATE_PY" << 'PYEOF'
import importlib.util
import os
import sys
from pathlib import Path

selfupdate_py = Path(sys.argv[1])
sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep) + [str(selfupdate_py.parent)]
spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# 不碰真实配置目录：把「已记录的协议号」直接喂给判断逻辑
recorded = {}
module.recorded_agreement = lambda: recorded.get('id', '')

cases = [
    # (已装版本, 已记录的协议号, 该不该问)
    ('4.3.4',      '',                True),   # 装得比 4.4.0 早：必问
    ('4.4.0',      '',                True),   # 就是带新协议那一版：也要问一次
    ('4.4.0-beta2','',                True),   # beta 走不到这里（前面就拒了），但判定要一致
    ('4.4.1',      '',                False),  # 装的是更新的版本：安装器已经问过
    ('4.5.0',      '',                False),
    ('4.3.4',      module.AGREEMENT_ID, False),  # 已经同意过这一版
    ('4.4.0',      module.AGREEMENT_ID, False),
    ('4.3.4',      '2026-01-01',      True),   # 记的是旧协议：还要问
    (None,         '',                False),  # 没有安装记录：交给安装器
]
for current, recorded_id, expected in cases:
    recorded['id'] = recorded_id
    got = module.agreement_needs_consent(current)
    assert got is expected, f'current={current} recorded={recorded_id!r}: 期望 {expected}，实际 {got}'

# 协议标识必须与官网落款一致，且是个日期形状（改协议时忘改这里会静默失真）
import re
assert re.fullmatch(r'\d{4}-\d{2}-\d{2}', module.AGREEMENT_ID), module.AGREEMENT_ID
assert module.AGREEMENT_URL.startswith('https://macwave.org/'), module.AGREEMENT_URL
print('🌊 Agreement decision table OK')
PYEOF
then
    echo -e "${GREEN}🌊 OK: agreement decision table${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: agreement decision table${RESET}"
    FAILED=$((FAILED + 1))
fi

# 端到端 · 拒绝：装 4.3.4、没有同意记录、stdin 读到 EOF → 中止，且什么都没动
python3 - "$VERSION_FILE" "4.0.0" << 'PYEOF'
import json
import sys
with open(sys.argv[1], 'w') as handle:
    json.dump({"version": sys.argv[2], "components": {"installer": sys.argv[2], "parser": sys.argv[2]}},
              handle, indent=2)
PYEOF
rm -f "$AGREEMENT_RECORD"

LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate < /dev/null > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if [[ "$RC" -ne 0 ]] && grep -q 'agreement has been updated' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: an update asks about the updated agreement${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: expected the agreement question (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
if grep -q 'https://macwave.org/#agreement' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: the question points at the website${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: the question does not say where to read it${RESET}"
    FAILED=$((FAILED + 1))
fi
if grep -q 'was not accepted' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: reading EOF counts as a refusal${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: EOF was not treated as a refusal${RESET}"
    FAILED=$((FAILED + 1))
fi
if [[ ! -f "$AGREEMENT_RECORD" ]]; then
    echo -e "${GREEN}🌊 OK: a refusal records nothing${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: a refusal wrote $AGREEMENT_RECORD${RESET}"
    FAILED=$((FAILED + 1))
fi
if [[ "$(python3 -c "import json; print(json.load(open('$VERSION_FILE'))['version'])")" == "4.0.0" ]]; then
    echo -e "${GREEN}🌊 OK: a refusal leaves the version alone${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: a refusal changed VERSION.json${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# 端到端 · 同意：答 y 就记下来，并且继续往下走（这里让后面的更新失败也无妨 ——
# 同意记录与更新成功与否无关，失败时也不该再问第二遍）
LOG_FILE="$(mktemp)"
RC=0
printf 'y\n' | python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
cat "$LOG_FILE"

if grep -q 'Agreement accepted' "$LOG_FILE"; then
    echo -e "${GREEN}🌊 OK: answering y records the acceptance${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: answering y did not record the acceptance (exit $RC)${RESET}"
    FAILED=$((FAILED + 1))
fi
if [[ -f "$AGREEMENT_RECORD" ]] && grep -q '"agreement"' "$AGREEMENT_RECORD"; then
    echo -e "${GREEN}🌊 OK: $AGREEMENT_RECORD written${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: $AGREEMENT_RECORD missing or empty${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# 端到端 · 静默模式不能替用户同意：-s 下不读 stdin，直接按拒绝退出。
# 上一步真的把版本推到 4.0.1 了，这里先降回 4.0.0 —— 否则又撞上「已是最新」。
python3 - "$VERSION_FILE" "4.0.0" << 'PYEOF'
import json
import sys
with open(sys.argv[1], 'w') as handle:
    json.dump({"version": sys.argv[2], "components": {"installer": sys.argv[2], "parser": sys.argv[2]}},
              handle, indent=2)
PYEOF
rm -f "$AGREEMENT_RECORD"
LOG_FILE="$(mktemp)"
RC=0
python3 "$WAVE_BIN" selfupdate -s < /dev/null > "$LOG_FILE" 2>&1 || RC=$?
if [[ "$RC" -ne 0 ]]; then
    echo -e "${GREEN}🌊 OK: -s refuses instead of hanging or assuming consent${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: -s did not refuse the updated agreement${RESET}"
    FAILED=$((FAILED + 1))
fi
if [[ ! -f "$AGREEMENT_RECORD" ]]; then
    echo -e "${GREEN}🌊 OK: -s records nothing${RESET}"
else
    echo -e "${RED_BOLD}🌊 FAIL: -s wrote $AGREEMENT_RECORD${RESET}"
    FAILED=$((FAILED + 1))
fi
rm -f "$LOG_FILE"

# 恢复现场：本段改过 VERSION.json 与 AGREEMENT.json，后面的端到端要用干净状态
cp "$SU_WORK/VERSION.json.agr" "$VERSION_FILE"
if [[ "$HAD_AGREEMENT" -eq 1 ]]; then
    cp "$SU_WORK/AGREEMENT.json.bak" "$AGREEMENT_RECORD"
else
    rm -f "$AGREEMENT_RECORD"
fi

# ==========================================
# 4. --max-time：时长时间解析与下载重试（离线，不碰网络）
# ==========================================

echo "========== max-time duration parsing =========="

if python3 - "$SELFUPDATE_PY" "$SELFUPDATE_SH" << 'PYEOF'
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

selfupdate_py, selfupdate_sh = Path(sys.argv[1]), Path(sys.argv[2])
# 组件目录由 scripts/components.txt 决定；pkginstaller（共用时长规则）与它
# 连带 import 的模块都在其中，selfupdate.py 自己在 lib/，一并加进来。
sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep) + [str(selfupdate_py.parent)]

spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# Python 侧：合法的原样留下，非法的当场拒绝。
# 4.1.5 起是三档（连接 / 读数据 / 总额），不再只有 --max-time。
raws, budget = module.timeouts_from("wave selfupdate --max-time=1min")
assert raws == {"--max-time": "1min"}, raws
assert budget.total == 60, budget
raws, budget = module.timeouts_from("wave selfupdate --max-time 1min20s")
assert raws == {"--max-time": "1min20s"}, raws
assert budget.total == 80, budget
assert module.timeouts_from("wave selfupdate")[0] == {}
# 三档各给一个，互不串档
raws, budget = module.timeouts_from(
    "wave selfupdate --connect-timeout=2s --content-time=3s --max-time=4s")
assert raws == {"--connect-timeout": "2s", "--content-time": "3s", "--max-time": "4s"}, raws
assert (budget.connect, budget.content, budget.total) == (2, 3, 4), budget
for bad in ("abc", "1x", "-5"):
    for flag in ("--max-time", "--connect-timeout", "--content-time"):
        try:
            module.timeouts_from(f"wave selfupdate {flag}={bad}")
        except SystemExit:
            pass
        else:
            raise AssertionError(f"{flag}={bad} 本应被拒绝")

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
    raws, budget = module.timeouts_from(f"wave selfupdate --max-time={value}")
    raw = raws.get("--max-time", "")
    assert raw == value, f"{value}: 原始文本应原样往下传，实际 {raw!r}"
    expected = str(module.curl_seconds(budget.total))
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

# 测试根的 HOME 重写必须是幂等的。config/configpaths.py 会先把 HOME 搬进测试根，
# 若 shell 脚本再无条件套一层，HOME 会变成 "<根>/private/var/.../Users/<你>"，
# 配置目录永远找不到 —— 这正是「用 MACWAVE_TEST 跑真实 selfupdate」失败的原因。
# 脚本会把测试根解析成物理路径（macOS 上 /var 指向 /private/var），
# 所以期望值也要用物理路径，否则这条断言会被符号链接本身骗过去。
work_home_real="$(mktemp -d)"
work_home="$(cd "$work_home_real" && pwd -P)"
for source_file in "$repo/lib/install.sh" "$repo/lib/selfupdate.sh"; do
    block="$(sed -n '/^SYS_ROOT=""/,/^fi$/p' "$source_file")"
    # 第一遍：HOME 在外面，应当被搬进测试根
    first="$(MACWAVE_TEST="$work_home_real" HOME=/Users/example bash -c "$block"$'\nprintf %s "$HOME"' 2>/dev/null | tail -1)"
    case "$first" in
        "$work_home"|"$work_home"/*) : ;;
        *) echo "  ❌ $(basename "$source_file"): HOME 没有被搬进测试根（${first}）"; exit 1 ;;
    esac
    # 第二遍：HOME 已经在测试根里，不能再套一层
    second="$(MACWAVE_TEST="$work_home_real" HOME="$first" bash -c "$block"$'\nprintf %s "$HOME"' 2>/dev/null | tail -1)"
    if [ "$second" != "$first" ]; then
        echo "  ❌ $(basename "$source_file"): HOME 被重复前缀（$first -> ${second}）"
        exit 1
    fi
done
rm -rf "$work_home_real"
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

if ! /bin/bash -n "$SELFUPDATE_SH"; then
    echo -e "${RED_BOLD}🌊 FAIL: selfupdate.sh has a syntax error${RESET}"
    FAILED=$((FAILED + 1))
fi

# 目标版本取自上面那份本地数据（SU_VERSION，与 4.0.0 同大版本、高一档），
# 于是这里真的会走一遍完整流程：取 <selfupdate>/macwavedata/<版本>/update_commands.sh
# → 按它的 want 清单下载代码 → 全部到位后写 VERSION.json。
INSTALLED="4.0.0"
TARGET="$SU_VERSION"

if [[ -z "$TARGET" ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: no target version in the local selfupdate data${RESET}"
    FAILED=$((FAILED + 1))
else
    python3 - "$VERSION_FILE" "$INSTALLED" << 'PYEOF'
import json
import sys

with open(sys.argv[1], 'w') as handle:
    json.dump({"version": sys.argv[2], "components": {"installer": sys.argv[2], "parser": sys.argv[2]}},
              handle, indent=2)
PYEOF

    # 4.0.0 比「带新协议那一版」（4.4.0）早，按 3.6 的规则要问一次协议，
    # 而这里是无人值守的。预先写下同意记录，让这一段只验更新机制本身 ——
    # 协议那道由 3.6 单独覆盖。
    python3 - "$SELFUPDATE_PY" "$AGREEMENT_RECORD" << 'PYEOF'
import importlib.util
import json
import os
import sys
from pathlib import Path

selfupdate_py = Path(sys.argv[1])
sys.path[:0] = os.environ["MACWAVE_COMPONENT_PATHS"].split(os.pathsep) + [str(selfupdate_py.parent)]
spec = importlib.util.spec_from_file_location('selfupdate_module', selfupdate_py)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with open(sys.argv[2], 'w') as handle:
    json.dump({"agreement": module.AGREEMENT_ID}, handle, indent=2)
PYEOF

    LOG_FILE="$(mktemp)"
    RC=0
    # 走真实命令（selfupdate.py + selfupdate.sh 两层都覆盖）。
    # selfupdate.py 会把 latest.toml 里的 version / branch 通过环境变量传下去；
    # 直接调 selfupdate.sh 就得自己拼这些变量，测的就不是用户实际走的那条路了。
    python3 "$WAVE_BIN" selfupdate > "$LOG_FILE" 2>&1 || RC=$?
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

FILES_INFO_TMP="$SU_WORK/selfupdate/macwavedata/$SU_VERSION/update_commands.sh"

if [[ ! -f "$FILES_INFO_TMP" ]]; then
    echo -e "${RED_BOLD}🌊 FAIL: the generated update_commands.sh is missing${RESET}"
    FAILED=$((FAILED + 1))
else
    # 清单就是脚本里的 `want <路径> <是否 +x>` 调用 —— 测的是这一版真正会下载的东西。
    FILE_COUNT=0
    MISSING=0
    while read -r repo_path; do
        if [[ -z "$repo_path" ]]; then
            continue
        fi
        FILE_COUNT=$((FILE_COUNT + 1))
        if [[ ! -e "$BASE_DIR/$repo_path" ]]; then
            echo -e "${RED_BOLD}🌊 FAIL: $repo_path was not installed${RESET}"
            MISSING=$((MISSING + 1))
        fi
    done < <(sed -n 's/^[[:space:]]*want \([^[:space:]]*\).*/\1/p' "$FILES_INFO_TMP" | sort -u)

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
               for folder in os.environ["MACWAVE_COMPONENT_NAMES"].split()):
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
